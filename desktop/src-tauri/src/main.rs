use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;

#[derive(Default)]
struct WorkerState {
    child: Mutex<Option<Child>>,
    task_id: Arc<Mutex<Option<String>>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartTaskRequest {
    input: String,
    output_dir: Option<String>,
    source_lang: String,
    target_lang: String,
    bilingual: bool,
    provider: Option<String>,
    model: Option<String>,
    asr_mode: Option<String>,
    asr_device: Option<String>,
    asr_model_size: Option<String>,
    asr_compute_type: Option<String>,
    asr_provider: Option<String>,
    asr_model: Option<String>,
    chunk_seconds: Option<u32>,
    chunk_overlap_seconds: Option<u32>,
    translation_batch_size: Option<u32>,
    concurrency: Option<u32>,
    output_format: Option<String>,
    translation_style_preset: Option<String>,
    translation_style_prompt: Option<String>,
    translation_chunk_lines: Option<u32>,
    translation_context_before_lines: Option<u32>,
    translation_context_after_lines: Option<u32>,
    translation_repair_enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResumeTaskRequest {
    task_id: String,
    provider: Option<String>,
    model: Option<String>,
    asr_mode: Option<String>,
    asr_device: Option<String>,
    asr_model_size: Option<String>,
    asr_compute_type: Option<String>,
    asr_provider: Option<String>,
    asr_model: Option<String>,
    chunk_seconds: Option<u32>,
    chunk_overlap_seconds: Option<u32>,
    translation_batch_size: Option<u32>,
    concurrency: Option<u32>,
    output_format: Option<String>,
    translation_style_preset: Option<String>,
    translation_style_prompt: Option<String>,
    translation_chunk_lines: Option<u32>,
    translation_context_before_lines: Option<u32>,
    translation_context_after_lines: Option<u32>,
    translation_repair_enabled: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StartTaskResponse {
    started: bool,
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

fn push_num_arg(args: &mut Vec<String>, flag: &str, value: Option<u32>) {
    if let Some(value) = value {
        args.push(flag.to_string());
        args.push(value.to_string());
    }
}

fn push_bool_arg(args: &mut Vec<String>, flag: &str, value: Option<bool>) {
    if let Some(value) = value {
        args.push(flag.to_string());
        args.push(if value { "true" } else { "false" }.to_string());
    }
}

fn ensure_no_running(state: &State<WorkerState>) -> Result<(), String> {
    let mut current = state.child.lock().map_err(|err| err.to_string())?;
    if current.as_mut().is_some_and(|child| child.try_wait().ok().flatten().is_none()) {
        return Err("A task is already running".into());
    }
    *current = None;
    *state.task_id.lock().map_err(|err| err.to_string())? = None;
    Ok(())
}

fn spawn_streaming_worker(
    app: AppHandle,
    state: State<WorkerState>,
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

    let stdout = child.stdout.take().ok_or("Failed to capture worker stdout")?;
    let stderr = child.stderr.take().ok_or("Failed to capture worker stderr")?;
    let emit_app = app.clone();
    let task_state = state.task_id.clone();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().flatten() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(event) = serde_json::from_str::<Value>(&line) {
                if let Some(task_id) = event.get("task_id").and_then(Value::as_str) {
                    if let Ok(mut current_task_id) = task_state.lock() {
                        *current_task_id = Some(task_id.to_string());
                    }
                }
                let _ = emit_app.emit("worker-event", event);
            }
        }
    });
    let err_app = app.clone();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().flatten() {
            if !line.trim().is_empty() {
                let _ = err_app.emit("worker-event", json!({"type": "stderr", "level": "error", "message": line}));
            }
        }
    });

    *state.child.lock().map_err(|err| err.to_string())? = Some(child);
    Ok(StartTaskResponse { started: true })
}

#[tauri::command]
fn get_config(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(&root, &["config".into(), "show".into(), "--json".into()])
}

#[tauri::command]
fn list_tasks(app: AppHandle) -> Result<Value, String> {
    let root = repo_root(&app)?;
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
fn save_env_secret(app: AppHandle, env_key: String, value: String) -> Result<(), String> {
    if env_key.trim().is_empty() {
        return Err("env_key is required".into());
    }
    let root = repo_root(&app)?;
    let dotenv_path = root.join(".env");
    let mut entries: HashMap<String, String> = HashMap::new();
    if dotenv_path.exists() {
        for line in fs::read_to_string(&dotenv_path).map_err(|err| err.to_string())?.lines() {
            if let Some((key, value)) = line.split_once('=') {
                entries.insert(key.trim().to_string(), value.trim().to_string());
            }
        }
    }
    entries.insert(env_key, value);
    let mut keys: Vec<_> = entries.keys().cloned().collect();
    keys.sort();
    let mut body = String::new();
    for key in keys {
        if let Some(value) = entries.get(&key) {
            body.push_str(&key);
            body.push('=');
            body.push_str(value);
            body.push('\n');
        }
    }
    fs::write(dotenv_path, body).map_err(|err| err.to_string())
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
    run_worker_json(&root, &args)
}

#[tauri::command]
fn delete_provider_config(app: AppHandle, name: String) -> Result<Value, String> {
    let root = repo_root(&app)?;
    run_worker_json(
        &root,
        &[
            "provider".into(),
            "delete".into(),
            "--name".into(),
            name,
            "--json".into(),
        ],
    )
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
fn start_task(
    app: AppHandle,
    state: State<WorkerState>,
    request: StartTaskRequest,
) -> Result<StartTaskResponse, String> {
    ensure_no_running(&state)?;
    let root = repo_root(&app)?;
    let input_path = request.input.clone();
    let target_lang = request.target_lang.clone();
    let mut args = vec![
        "-m".into(),
        "transvortex.cli".into(),
        "--root".into(),
        root.to_string_lossy().to_string(),
        "run".into(),
        "--input".into(),
        input_path.clone(),
        "--src".into(),
        request.source_lang.clone(),
        "--tgt".into(),
        target_lang.clone(),
        "--stream-events".into(),
    ];
    if request.bilingual {
        args.push("--bilingual".into());
    }
    if let Some(output_dir) = request.output_dir.filter(|value| !value.trim().is_empty()) {
        let input_stem = Path::new(&input_path)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("output");
        let output_path = Path::new(&output_dir).join(format!("{input_stem}.{target_lang}.srt"));
        args.push("--output".into());
        args.push(output_path.to_string_lossy().to_string());
    }
    push_arg(&mut args, "--provider", &request.provider);
    push_arg(&mut args, "--model", &request.model);
    push_arg(&mut args, "--asr-mode", &request.asr_mode);
    push_arg(&mut args, "--asr-device", &request.asr_device);
    push_arg(&mut args, "--asr-model-size", &request.asr_model_size);
    push_arg(&mut args, "--asr-compute-type", &request.asr_compute_type);
    push_arg(&mut args, "--asr-provider", &request.asr_provider);
    push_arg(&mut args, "--asr-model", &request.asr_model);
    push_num_arg(&mut args, "--chunk-seconds", request.chunk_seconds);
    push_num_arg(&mut args, "--chunk-overlap-seconds", request.chunk_overlap_seconds);
    push_num_arg(&mut args, "--translation-batch-size", request.translation_batch_size);
    push_num_arg(&mut args, "--concurrency", request.concurrency);
    push_arg(&mut args, "--output-format", &request.output_format);
    push_arg(&mut args, "--translation-style-preset", &request.translation_style_preset);
    push_arg(&mut args, "--translation-style-prompt", &request.translation_style_prompt);
    push_num_arg(&mut args, "--translation-chunk-lines", request.translation_chunk_lines);
    push_num_arg(
        &mut args,
        "--translation-context-before-lines",
        request.translation_context_before_lines,
    );
    push_num_arg(
        &mut args,
        "--translation-context-after-lines",
        request.translation_context_after_lines,
    );
    push_bool_arg(
        &mut args,
        "--translation-repair-enabled",
        request.translation_repair_enabled,
    );

    spawn_streaming_worker(app, state, root, args)
}

#[tauri::command]
fn resume_task(
    app: AppHandle,
    state: State<WorkerState>,
    request: ResumeTaskRequest,
) -> Result<StartTaskResponse, String> {
    ensure_no_running(&state)?;
    let root = repo_root(&app)?;
    let mut args = vec![
        "-m".into(),
        "transvortex.cli".into(),
        "--root".into(),
        root.to_string_lossy().to_string(),
        "resume".into(),
        "--task-id".into(),
        request.task_id,
        "--stream-events".into(),
    ];
    push_arg(&mut args, "--provider", &request.provider);
    push_arg(&mut args, "--model", &request.model);
    push_arg(&mut args, "--asr-mode", &request.asr_mode);
    push_arg(&mut args, "--asr-device", &request.asr_device);
    push_arg(&mut args, "--asr-model-size", &request.asr_model_size);
    push_arg(&mut args, "--asr-compute-type", &request.asr_compute_type);
    push_arg(&mut args, "--asr-provider", &request.asr_provider);
    push_arg(&mut args, "--asr-model", &request.asr_model);
    push_num_arg(&mut args, "--chunk-seconds", request.chunk_seconds);
    push_num_arg(&mut args, "--chunk-overlap-seconds", request.chunk_overlap_seconds);
    push_num_arg(&mut args, "--translation-batch-size", request.translation_batch_size);
    push_num_arg(&mut args, "--concurrency", request.concurrency);
    push_arg(&mut args, "--output-format", &request.output_format);
    push_arg(&mut args, "--translation-style-preset", &request.translation_style_preset);
    push_arg(&mut args, "--translation-style-prompt", &request.translation_style_prompt);
    push_num_arg(&mut args, "--translation-chunk-lines", request.translation_chunk_lines);
    push_num_arg(
        &mut args,
        "--translation-context-before-lines",
        request.translation_context_before_lines,
    );
    push_num_arg(
        &mut args,
        "--translation-context-after-lines",
        request.translation_context_after_lines,
    );
    push_bool_arg(
        &mut args,
        "--translation-repair-enabled",
        request.translation_repair_enabled,
    );
    spawn_streaming_worker(app, state, root, args)
}

#[tauri::command]
fn cancel_task(app: AppHandle, state: State<WorkerState>) -> Result<Value, String> {
    let root = repo_root(&app)?;
    let task_id = state
        .task_id
        .lock()
        .map_err(|err| err.to_string())?
        .clone()
        .ok_or("No running task id is known yet")?;
    run_worker_json(&root, &["cancel".into(), "--task-id".into(), task_id, "--json".into()])
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    app.opener()
        .open_path(path, None::<&str>)
        .map_err(|err| err.to_string())
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
            save_env_secret,
            probe_provider,
            save_provider_config,
            delete_provider_config,
            fetch_provider_models,
            test_provider_connection,
            start_task,
            resume_task,
            cancel_task,
            open_path
        ])
        .run(tauri::generate_context!())
        .expect("error while running TransVortex desktop");
}
