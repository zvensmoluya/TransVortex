use serde::Serialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;

#[derive(Default)]
struct WorkerState {
    child: Arc<Mutex<Option<Child>>>,
    task_id: Arc<Mutex<Option<String>>>,
}

impl Clone for WorkerState {
    fn clone(&self) -> Self {
        Self {
            child: Arc::clone(&self.child),
            task_id: Arc::clone(&self.task_id),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StartTaskResponse {
    started: bool,
    task_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct SubtitleStream {
    index: i64,
    codec_name: String,
    language: String,
    title: String,
    default: bool,
    forced: bool,
    supported: bool,
}

fn repo_root(app: &AppHandle) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|err| err.to_string())?;
    for ancestor in exe.ancestors() {
        if ancestor.join("pyproject.toml").exists() && ancestor.join("src").exists() {
            return Ok(ancestor.to_path_buf());
        }
    }

    let cwd = std::env::current_dir().map_err(|err| err.to_string())?;
    if cwd.join("pyproject.toml").exists() {
        return Ok(cwd);
    }
    if cwd.parent().is_some_and(|parent| parent.join("pyproject.toml").exists()) {
        return Ok(cwd.parent().unwrap().to_path_buf());
    }

    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|err| err.to_string())?;
    Ok(resource_dir)
}

fn python_command() -> String {
    std::env::var("TRANSVORTEX_PYTHON").unwrap_or_else(|_| "python".to_string())
}

fn python_worker_command() -> Command {
    let mut command = Command::new(python_command());
    command.env("PYTHONUTF8", "1");
    command.env("PYTHONIOENCODING", "utf-8");
    command
}

fn run_worker_json(root: &Path, args: &[String]) -> Result<Value, String> {
    let output = python_worker_command()
        .arg("-m")
        .arg("transvortex.cli")
        .arg("--root")
        .arg(root)
        .args(args)
        .current_dir(root)
        .output()
        .map_err(|err| err.to_string())?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Err(if stderr.is_empty() { stdout } else { stderr });
    }

    serde_json::from_slice(&output.stdout).map_err(|err| err.to_string())
}

fn value_arg(value: &Value) -> Result<String, String> {
    serde_json::to_string(value).map_err(|err| err.to_string())
}

fn push_arg(args: &mut Vec<String>, flag: &str, value: &Option<String>) {
    if let Some(value) = value {
        if !value.trim().is_empty() {
            args.push(flag.to_string());
            args.push(value.clone());
        }
    }
}

fn push_bool_arg(args: &mut Vec<String>, flag: &str, value: Option<bool>) {
    if let Some(value) = value {
        args.push(flag.to_string());
        args.push(if value { "true" } else { "false" }.to_string());
    }
}

fn subtitle_streams_from_probe(payload: Value) -> Vec<SubtitleStream> {
    let text_codecs = ["subrip", "ass", "ssa", "webvtt", "mov_text"];
    payload
        .get("streams")
        .and_then(Value::as_array)
        .map(|streams| {
            streams
                .iter()
                .filter(|stream| stream.get("codec_type").and_then(Value::as_str) == Some("subtitle"))
                .map(|stream| {
                    let codec = stream
                        .get("codec_name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let tags = stream.get("tags").and_then(Value::as_object);
                    let disposition = stream.get("disposition").and_then(Value::as_object);
                    SubtitleStream {
                        index: stream.get("index").and_then(Value::as_i64).unwrap_or(-1),
                        codec_name: codec.clone(),
                        language: tags
                            .and_then(|value| value.get("language"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        title: tags
                            .and_then(|value| value.get("title"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                        default: disposition
                            .and_then(|value| value.get("default"))
                            .and_then(Value::as_i64)
                            .unwrap_or(0)
                            == 1,
                        forced: disposition
                            .and_then(|value| value.get("forced"))
                            .and_then(Value::as_i64)
                            .unwrap_or(0)
                            == 1,
                        supported: text_codecs.contains(&codec.as_str()),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

fn ensure_no_running(state: &WorkerState) -> Result<(), String> {
    let mut current = state.child.lock().map_err(|err| err.to_string())?;
    if current.as_mut().is_some_and(|child| child.try_wait().ok().flatten().is_none()) {
        return Err("A task is already running".into());
    }
    *current = None;
    *state.task_id.lock().map_err(|err| err.to_string())? = None;
    Ok(())
}

fn request_file_path(app: &AppHandle, command: &str) -> Result<PathBuf, String> {
    let cache_dir = app.path().app_cache_dir().map_err(|err| err.to_string())?;
    std::fs::create_dir_all(&cache_dir).map_err(|err| err.to_string())?;
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| err.to_string())?
        .as_millis();
    Ok(cache_dir.join(format!("transvortex-{command}-{millis}.json")))
}

fn write_request_file(app: &AppHandle, command: &str, request: &Value) -> Result<PathBuf, String> {
    let path = request_file_path(app, command)?;
    let bytes = serde_json::to_vec_pretty(request).map_err(|err| err.to_string())?;
    std::fs::write(&path, bytes).map_err(|err| err.to_string())?;
    Ok(path)
}

fn spawn_streaming_worker(
    app: AppHandle,
    state: WorkerState,
    root: PathBuf,
    args: Vec<String>,
) -> Result<StartTaskResponse, String> {
    let mut child = python_worker_command()
        .args(args)
        .current_dir(&root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| err.to_string())?;

    let stdout = child.stdout.take().ok_or_else(|| "Failed to capture worker stdout".to_string())?;
    let stderr = child.stderr.take().ok_or_else(|| "Failed to capture worker stderr".to_string())?;
    let emit_app = app.clone();
    let task_state = state.task_id.clone();
    let (task_tx, task_rx) = mpsc::channel::<String>();
    let chain_app = app.clone();
    let chain_state = state.clone();
    let chain_root = root.clone();
    thread::spawn(move || {
        let mut first_task_id_sent = false;
        for line in BufReader::new(stdout).lines().flatten() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(event) = serde_json::from_str::<Value>(&line) {
                if let Some(task_id) = event.get("task_id").and_then(Value::as_str) {
                    if task_id.is_empty() {
                        let _ = emit_app.emit("worker-event", event);
                        continue;
                    }
                    if let Ok(mut current_task_id) = task_state.lock() {
                        *current_task_id = Some(task_id.to_string());
                    }
                    if !first_task_id_sent {
                        let _ = task_tx.send(task_id.to_string());
                        first_task_id_sent = true;
                    }
                }
                let _ = emit_app.emit("worker-event", event);
            }
        }
        let _ = launch_next_worker(chain_app, chain_state, chain_root);
    });
    let err_app = app.clone();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().flatten() {
            if !line.trim().is_empty() {
                let _ = err_app.emit("worker-event", json!({"type": "stderr", "level": "error", "message": line}));
            }
        }
    });

    let task_id = loop {
        match task_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(task_id) => break Some(task_id),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Some(status) = child.try_wait().map_err(|err| err.to_string())? {
                    return Err(format!("Worker exited before task creation: {status}"));
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Worker stdout closed before task creation".to_string());
            }
        }
    };

    *state.child.lock().map_err(|err| err.to_string())? = Some(child);
    Ok(StartTaskResponse {
        started: true,
        task_id,
    })
}

fn launch_next_worker(app: AppHandle, state: WorkerState, root: PathBuf) -> Result<Option<String>, String> {
    ensure_no_running(&state)?;
    let acquired = run_worker_json(&root, &["runtime".into(), "acquire-next".into(), "--json".into()])?;
    if !acquired
        .get("acquired")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(None);
    }
    let launch = acquired.get("launch").and_then(Value::as_object).ok_or("Missing runtime launch payload")?;
    let task_id = launch
        .get("task_id")
        .and_then(Value::as_str)
        .ok_or("Missing runtime task id")?
        .to_string();
    let mut args = vec!["-m".into(), "transvortex.cli".into(), "--root".into(), root.to_string_lossy().to_string()];
    let launch_args = launch
        .get("args")
        .and_then(Value::as_array)
        .ok_or("Missing runtime launch args")?;
    for item in launch_args {
        args.push(item.as_str().ok_or("Runtime launch arg must be a string")?.to_string());
    }
    let response = match spawn_streaming_worker(app, state, root.clone(), args) {
        Ok(response) => response,
        Err(err) => {
            let _ = run_worker_json(
                &root,
                &[
                    "runtime".into(),
                    "release-active".into(),
                    "--task-id".into(),
                    task_id.clone(),
                    "--state".into(),
                    "interrupted".into(),
                    "--reason".into(),
                    "worker_launch_failed".into(),
                    "--json".into(),
                ],
            );
            return Err(err);
        }
    };
    Ok(response.task_id.or(Some(task_id)))
}

#[tauri::command]
fn get_config(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(&root, &["config".into(), "show".into(), "--json".into()])
}

#[tauri::command]
fn list_tasks(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let _ = run_worker_json(&root, &["runtime".into(), "reconcile".into(), "--json".into()]);
    run_worker_json(&root, &["tasks".into(), "--json".into()])
}

#[tauri::command]
fn doctor(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(&root, &["doctor".into(), "--json".into()])
}

#[tauri::command]
fn read_events(app: AppHandle, task_id: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let output = python_worker_command()
        .arg("-m")
        .arg("transvortex.cli")
        .arg("--root")
        .arg(&root)
        .arg("events")
        .arg("--task-id")
        .arg(task_id)
        .current_dir(&root)
        .output()
        .map_err(|err| err.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let mut events = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(event) = serde_json::from_str::<Value>(line) {
            events.push(event);
        }
    }
    Ok(Value::Array(events))
}

#[tauri::command]
fn probe_provider(
    app: AppHandle,
    provider: Option<String>,
    model: Option<String>,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec!["probe-provider".into(), "--strict".into()];
    push_arg(&mut args, "--provider", &provider);
    push_arg(&mut args, "--model", &model);
    run_worker_json(&root, &args)
}

#[tauri::command]
fn save_provider_config(
    app: AppHandle,
    provider_draft: Value,
    api_key: Option<String>,
    expected_version: Option<Value>,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec![
        "provider".into(),
        "save".into(),
        "--json-payload".into(),
        value_arg(&provider_draft)?,
        "--json".into(),
    ];
    push_arg(&mut args, "--api-key", &api_key);
    if let Some(version) = expected_version {
        args.push("--expected-version".into());
        args.push(value_arg(&version)?);
    }
    run_worker_json(&root, &args)
}

#[tauri::command]
fn delete_provider_config(app: AppHandle, name: String, expected_version: Option<Value>) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec![
        "provider".into(),
        "delete".into(),
        "--name".into(),
        name,
        "--json".into(),
    ];
    if let Some(version) = expected_version {
        args.push("--expected-version".into());
        args.push(value_arg(&version)?);
    }
    run_worker_json(&root, &args)
}

#[tauri::command]
fn save_asr_prompt_profile(app: AppHandle, profile: Value) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let args = vec![
        "prompt".into(),
        "asr".into(),
        "save".into(),
        "--json-payload".into(),
        value_arg(&profile)?,
        "--json".into(),
    ];
    run_worker_json(&root, &args)
}

#[tauri::command]
fn delete_asr_prompt_profile(app: AppHandle, profile_id: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let args = vec![
        "prompt".into(),
        "asr".into(),
        "delete".into(),
        "--id".into(),
        profile_id,
        "--json".into(),
    ];
    run_worker_json(&root, &args)
}

#[tauri::command]
fn fetch_provider_models(
    app: AppHandle,
    provider_draft: Value,
    api_key: Option<String>,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec![
        "provider".into(),
        "models".into(),
        "--json-payload".into(),
        value_arg(&provider_draft)?,
        "--json".into(),
    ];
    push_arg(&mut args, "--api-key", &api_key);
    run_worker_json(&root, &args)
}

#[tauri::command]
fn test_provider_connection(
    app: AppHandle,
    provider_draft: Value,
    model: String,
    api_key: Option<String>,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec![
        "provider".into(),
        "test".into(),
        "--json-payload".into(),
        value_arg(&provider_draft)?,
        "--model".into(),
        model,
        "--json".into(),
    ];
    push_arg(&mut args, "--api-key", &api_key);
    run_worker_json(&root, &args)
}

#[tauri::command]
fn save_provider_routing(app: AppHandle, routing: Value) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "provider".into(),
            "routing".into(),
            "--json-payload".into(),
            value_arg(&routing)?,
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn save_auth_credential(app: AppHandle, credential_id: String, api_key: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "auth".into(),
            "set".into(),
            credential_id,
            "--api-key".into(),
            api_key,
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn list_auth_credentials(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(&root, &["auth".into(), "list".into(), "--json".into()])
}

#[tauri::command]
fn update_task_memory_entry(
    app: AppHandle,
    task_id: String,
    entry_id: String,
    status: String,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "result".into(),
            "memory-entry".into(),
            "--task-id".into(),
            task_id,
            "--entry-id".into(),
            entry_id,
            "--status".into(),
            status,
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn export_memory_preset(app: AppHandle, options: Value) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let task_id = options
        .get("taskId")
        .and_then(Value::as_str)
        .or_else(|| options.get("task_id").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let preset_id = options
        .get("presetId")
        .and_then(Value::as_str)
        .or_else(|| options.get("preset_id").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let name = options
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let description = options
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let default_status = options
        .get("defaultStatus")
        .and_then(Value::as_str)
        .or_else(|| options.get("default_status").and_then(Value::as_str))
        .unwrap_or("confirmed")
        .to_string();
    let overwrite = options
        .get("overwrite")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let mut args = vec![
        "memory".into(),
        "export-preset".into(),
        "--task-id".into(),
        task_id,
        "--preset-id".into(),
        preset_id,
        "--name".into(),
        name,
        "--description".into(),
        description,
        "--default-status".into(),
        default_status,
        "--json".into(),
    ];
    if overwrite {
        args.push("--overwrite".into());
    }
    run_worker_json(&root, &args)
}

#[tauri::command]
fn open_task_result(app: AppHandle, task_id: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "result".into(),
            "open".into(),
            "--task-id".into(),
            task_id,
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn save_task_segments(app: AppHandle, task_id: String, segments: Value) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "result".into(),
            "save".into(),
            "--task-id".into(),
            task_id,
            "--json-payload".into(),
            value_arg(&json!({ "segments": segments }))?,
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn reexport_task(
    app: AppHandle,
    task_id: String,
    output_format: String,
    bilingual: Option<bool>,
    subtitle_bilingual_order: Option<String>,
    subtitle_prefer_single_line: Option<bool>,
) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let mut args = vec![
        "reexport".into(),
        "--task-id".into(),
        task_id,
        "--output-format".into(),
        output_format,
    ];
    push_bool_arg(&mut args, "--bilingual", bilingual);
    push_arg(
        &mut args,
        "--subtitle-bilingual-order",
        &subtitle_bilingual_order,
    );
    push_bool_arg(
        &mut args,
        "--subtitle-prefer-single-line",
        subtitle_prefer_single_line,
    );
    args.push("--json".into());
    run_worker_json(&root, &args)
}

#[tauri::command]
fn start_task(
    app: AppHandle,
    state: State<WorkerState>,
    request: Value,
) -> Result<StartTaskResponse, String> {
    let root = repo_root(&app)?;
    let request_file = write_request_file(&app, "run", &request)?;
    let submitted = match run_worker_json(
        &root,
        &[
            "runtime".into(),
            "submit-run".into(),
            "--request-json".into(),
            request_file.to_string_lossy().to_string(),
            "--json".into(),
        ],
    ) {
        Ok(value) => value,
        Err(err) => {
            let _ = std::fs::remove_file(&request_file);
            return Err(err);
        }
    };
    let _ = std::fs::remove_file(&request_file);
    let task_id = submitted
        .get("task_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let started_task_id = launch_next_worker(app, state.inner().clone(), root)?;
    Ok(StartTaskResponse {
        started: started_task_id.is_some(),
        task_id,
    })
}

#[tauri::command]
fn resume_task(
    app: AppHandle,
    state: State<WorkerState>,
    request: Value,
) -> Result<StartTaskResponse, String> {
    let root = repo_root(&app)?;
    let request_file = write_request_file(&app, "resume", &request)?;
    let submitted = match run_worker_json(
        &root,
        &[
            "runtime".into(),
            "submit-resume".into(),
            "--request-json".into(),
            request_file.to_string_lossy().to_string(),
            "--json".into(),
        ],
    ) {
        Ok(value) => value,
        Err(err) => {
            let _ = std::fs::remove_file(&request_file);
            return Err(err);
        }
    };
    let _ = std::fs::remove_file(&request_file);
    let task_id = submitted
        .get("task_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let started_task_id = launch_next_worker(app, state.inner().clone(), root)?;
    Ok(StartTaskResponse {
        started: started_task_id.is_some(),
        task_id,
    })
}

#[tauri::command]
fn cancel_task(app: AppHandle, state: State<WorkerState>, task_id: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    *state.task_id.lock().map_err(|err| err.to_string())? = Some(task_id.clone());
    run_worker_json(
        &root,
        &[
            "cancel".into(),
            "--task-id".into(),
            task_id,
            "--force-after-grace".into(),
            "15".into(),
            "--json".into(),
        ],
    )
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    app.opener()
        .open_path(path, None::<&str>)
        .map_err(|err| err.to_string())
}

#[tauri::command]
fn probe_subtitle_streams(input: String) -> Result<Vec<SubtitleStream>, String> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_streams",
            "-of",
            "json",
            input.as_str(),
        ])
        .output()
        .map_err(|err| err.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    let payload: Value = serde_json::from_slice(&output.stdout).map_err(|err| err.to_string())?;
    Ok(subtitle_streams_from_probe(payload))
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(WorkerState::default())
        .invoke_handler(tauri::generate_handler![
            get_config,
            list_tasks,
            doctor,
            read_events,
            probe_provider,
            save_provider_config,
            delete_provider_config,
            save_asr_prompt_profile,
            delete_asr_prompt_profile,
            fetch_provider_models,
            test_provider_connection,
            save_provider_routing,
            save_auth_credential,
            list_auth_credentials,
            update_task_memory_entry,
            export_memory_preset,
            open_task_result,
            save_task_segments,
            reexport_task,
            start_task,
            resume_task,
            cancel_task,
            probe_subtitle_streams,
            open_path
        ])
        .run(tauri::generate_context!())
        .expect("error while running TransVortex desktop");
}
