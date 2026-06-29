use serde::Serialize;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::Duration,
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

struct SidecarState {
    inner: Arc<Mutex<Option<SidecarProcess>>>,
    next_id: Arc<Mutex<u64>>,
}

impl Default for SidecarState {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(None)),
            next_id: Arc::new(Mutex::new(0)),
        }
    }
}

impl Clone for SidecarState {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
            next_id: Arc::clone(&self.next_id),
        }
    }
}

struct SidecarProcess {
    child: Child,
    stdin: ChildStdin,
    responses: mpsc::Receiver<Result<String, String>>,
    root: PathBuf,
}

enum SidecarCallError {
    Remote(String),
    Transport(String),
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

fn sidecar_timeout(method: &str) -> Duration {
    if method == "provider.test" || method == "provider.models" {
        Duration::from_secs(120)
    } else {
        Duration::from_secs(30)
    }
}

fn sidecar_error(code: &str, message: impl Into<String>) -> String {
    json!({"code": code, "message": message.into()}).to_string()
}

fn spawn_sidecar(root: &Path) -> Result<SidecarProcess, String> {
    let mut child = python_worker_command()
        .arg("-m")
        .arg("transvortex.app_service")
        .arg("--root")
        .arg(root)
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| sidecar_error("sidecar_unavailable", err.to_string()))?;

    let stderr = child.stderr.take().ok_or_else(|| sidecar_error("sidecar_unavailable", "Failed to capture sidecar stderr"))?;
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().flatten() {
            if !line.trim().is_empty() {
                eprintln!("[transvortex-sidecar] {line}");
            }
        }
    });

    let stdin = child.stdin.take().ok_or_else(|| sidecar_error("sidecar_unavailable", "Failed to capture sidecar stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| sidecar_error("sidecar_unavailable", "Failed to capture sidecar stdout"))?;
    let (tx, rx) = mpsc::channel::<Result<String, String>>();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(value) => {
                    let _ = tx.send(Ok(value));
                }
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    break;
                }
            }
        }
    });
    Ok(SidecarProcess {
        child,
        stdin,
        responses: rx,
        root: root.to_path_buf(),
    })
}

fn sidecar_call(app: &AppHandle, state: &SidecarState, method: &str, params: Value) -> Result<Value, String> {
    let root = repo_root(app)?;
    sidecar_call_root(state, &root, method, params, sidecar_method_can_retry(method))
}

fn sidecar_method_can_retry(method: &str) -> bool {
    matches!(
        method,
        "desktop.ping"
            | "desktop.snapshot"
            | "config.get"
            | "tasks.list"
            | "tasks.events"
            | "runtime.snapshot"
            | "runtime.reconcile"
            | "runtime.acquireNext"
            | "auth.list"
    )
}

fn sidecar_call_root(
    state: &SidecarState,
    root: &Path,
    method: &str,
    params: Value,
    allow_restart: bool,
) -> Result<Value, String> {
    let id = {
        let mut next = state.next_id.lock().map_err(|err| err.to_string())?;
        *next += 1;
        *next
    };
    let mut guard = state.inner.lock().map_err(|err| err.to_string())?;
    let needs_spawn = match guard.as_mut() {
        Some(process) => process.child.try_wait().map_err(|err| err.to_string())?.is_some() || process.root != root,
        None => true,
    };
    if needs_spawn {
        *guard = Some(spawn_sidecar(root)?);
    }
    let response = match sidecar_call_locked(
        guard.as_mut().ok_or_else(|| sidecar_error("sidecar_unavailable", "Sidecar was not started"))?,
        id,
        method,
        params.clone(),
    ) {
        Ok(value) => return Ok(value),
        Err(err) => err,
    };
    if let SidecarCallError::Remote(message) = response {
        return Err(message);
    }
    let message = match response {
        SidecarCallError::Transport(message) => message,
        SidecarCallError::Remote(_) => unreachable!(),
    };
    if !allow_restart {
        *guard = None;
        return Err(message);
    }
    *guard = None;
    *guard = Some(spawn_sidecar(root)?);
    sidecar_call_locked(
        guard.as_mut().ok_or_else(|| sidecar_error("sidecar_unavailable", "Sidecar was not restarted"))?,
        id + 1,
        method,
        params,
    )
    .map_err(|err| match err {
        SidecarCallError::Remote(message) | SidecarCallError::Transport(message) => message,
    })
}

fn sidecar_call_locked(process: &mut SidecarProcess, id: u64, method: &str, params: Value) -> Result<Value, SidecarCallError> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    });
    let raw = serde_json::to_string(&request).map_err(|err| SidecarCallError::Transport(err.to_string()))?;
    process
        .stdin
        .write_all(raw.as_bytes())
        .and_then(|_| process.stdin.write_all(b"\n"))
        .and_then(|_| process.stdin.flush())
        .map_err(|err| SidecarCallError::Transport(sidecar_error("sidecar_pipe_error", err.to_string())))?;

    let line = process
        .responses
        .recv_timeout(sidecar_timeout(method))
        .map_err(|_| SidecarCallError::Transport(sidecar_error("sidecar_timeout", format!("{method} timed out"))))?
        .map_err(|err| SidecarCallError::Transport(sidecar_error("sidecar_pipe_error", err.to_string())))?;
    if line.trim().is_empty() {
        return Err(SidecarCallError::Transport(sidecar_error("sidecar_protocol_error", "Sidecar returned empty response")));
    }
    let payload: Value = serde_json::from_str(&line)
        .map_err(|err| SidecarCallError::Transport(sidecar_error("sidecar_protocol_error", err.to_string())))?;
    if let Some(error) = payload.get("error") {
        return Err(SidecarCallError::Remote(error.to_string()));
    }
    payload
        .get("result")
        .cloned()
        .ok_or_else(|| SidecarCallError::Transport(sidecar_error("sidecar_protocol_error", "Missing sidecar result")))
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

fn spawn_streaming_worker(
    app: AppHandle,
    sidecar: SidecarState,
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
    let chain_sidecar = sidecar.clone();
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
        let _ = launch_next_worker(chain_app, chain_sidecar, chain_state, chain_root);
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

fn launch_next_worker(app: AppHandle, sidecar: SidecarState, state: WorkerState, root: PathBuf) -> Result<Option<String>, String> {
    ensure_no_running(&state)?;
    let acquired = sidecar_call_root(&sidecar, &root, "runtime.acquireNext", json!({}), true)?;
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
    let response = match spawn_streaming_worker(app, sidecar.clone(), state, root.clone(), args) {
        Ok(response) => response,
        Err(err) => {
            let _ = sidecar_call_root(
                &sidecar,
                &root,
                "runtime.releaseActive",
                json!({"task_id": task_id, "state": "interrupted", "reason": "worker_launch_failed"}),
                false,
            );
            return Err(err);
        }
    };
    Ok(response.task_id.or(Some(task_id)))
}

#[tauri::command]
fn get_config(app: AppHandle, sidecar: State<SidecarState>) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "config.get", json!({}))
}

#[tauri::command]
fn desktop_snapshot(app: AppHandle, sidecar: State<SidecarState>) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "desktop.snapshot", json!({}))
}

#[tauri::command]
fn list_tasks(app: AppHandle, sidecar: State<SidecarState>) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "tasks.list", json!({}))
}

#[tauri::command]
fn doctor(app: AppHandle, sidecar: State<SidecarState>) -> Result<Value, String> {
    let snapshot = sidecar_call(&app, sidecar.inner(), "desktop.snapshot", json!({}))?;
    snapshot
        .get("environment")
        .cloned()
        .ok_or_else(|| sidecar_error("sidecar_protocol_error", "Missing environment payload"))
}

#[tauri::command]
fn read_events(app: AppHandle, sidecar: State<SidecarState>, task_id: String) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "tasks.events", json!({"task_id": task_id}))
}

#[tauri::command]
fn probe_provider(
    app: AppHandle,
    sidecar: State<SidecarState>,
    provider: Option<String>,
    model: Option<String>,
) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "provider.probe", json!({"provider": provider, "model": model}))
}

#[tauri::command]
fn save_provider_config(
    app: AppHandle,
    sidecar: State<SidecarState>,
    provider_draft: Value,
    api_key: Option<String>,
    expected_version: Option<Value>,
) -> Result<Value, String> {
    sidecar_call(
        &app,
        sidecar.inner(),
        "provider.save",
        json!({"provider_draft": provider_draft, "api_key": api_key, "expected_version": expected_version}),
    )
}

#[tauri::command]
fn delete_provider_config(app: AppHandle, sidecar: State<SidecarState>, name: String, expected_version: Option<Value>) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "provider.delete", json!({"name": name, "expected_version": expected_version}))
}

#[tauri::command]
fn save_asr_prompt_profile(app: AppHandle, sidecar: State<SidecarState>, profile: Value) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "prompt.asr.save", json!({"profile": profile}))
}

#[tauri::command]
fn delete_asr_prompt_profile(app: AppHandle, sidecar: State<SidecarState>, profile_id: String) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "prompt.asr.delete", json!({"id": profile_id}))
}

#[tauri::command]
fn fetch_provider_models(
    app: AppHandle,
    sidecar: State<SidecarState>,
    provider_draft: Value,
    api_key: Option<String>,
) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "provider.models", json!({"provider_draft": provider_draft, "api_key": api_key}))
}

#[tauri::command]
fn test_provider_connection(
    app: AppHandle,
    sidecar: State<SidecarState>,
    provider_draft: Value,
    model: String,
    api_key: Option<String>,
) -> Result<Value, String> {
    sidecar_call(
        &app,
        sidecar.inner(),
        "provider.test",
        json!({"provider_draft": provider_draft, "model": model, "api_key": api_key}),
    )
}

#[tauri::command]
fn save_provider_routing(app: AppHandle, sidecar: State<SidecarState>, routing: Value) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "provider.routing.save", json!({"routing": routing}))
}

#[tauri::command]
fn save_auth_credential(app: AppHandle, sidecar: State<SidecarState>, credential_id: String, api_key: String) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "auth.set", json!({"credential_id": credential_id, "api_key": api_key}))
}

#[tauri::command]
fn list_auth_credentials(app: AppHandle, sidecar: State<SidecarState>) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "auth.list", json!({}))
}

#[tauri::command]
fn update_task_memory_entry(
    app: AppHandle,
    sidecar: State<SidecarState>,
    task_id: String,
    entry_id: String,
    status: String,
) -> Result<Value, String> {
    sidecar_call(
        &app,
        sidecar.inner(),
        "result.memoryEntry.update",
        json!({"task_id": task_id, "entry_id": entry_id, "status": status}),
    )
}

#[tauri::command]
fn export_memory_preset(app: AppHandle, sidecar: State<SidecarState>, options: Value) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "memory.exportPreset", options)
}

#[tauri::command]
fn open_task_result(app: AppHandle, sidecar: State<SidecarState>, task_id: String) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "result.open", json!({"task_id": task_id}))
}

#[tauri::command]
fn save_task_segments(app: AppHandle, sidecar: State<SidecarState>, task_id: String, segments: Value) -> Result<Value, String> {
    sidecar_call(&app, sidecar.inner(), "result.segments.save", json!({"task_id": task_id, "segments": segments}))
}

#[tauri::command]
fn reexport_task(
    app: AppHandle,
    sidecar: State<SidecarState>,
    task_id: String,
    output_format: String,
    bilingual: Option<bool>,
    subtitle_bilingual_order: Option<String>,
    subtitle_prefer_single_line: Option<bool>,
) -> Result<Value, String> {
    sidecar_call(
        &app,
        sidecar.inner(),
        "result.reexport",
        json!({
            "task_id": task_id,
            "output_format": output_format,
            "bilingual": bilingual,
            "subtitle_bilingual_order": subtitle_bilingual_order,
            "subtitle_prefer_single_line": subtitle_prefer_single_line,
        }),
    )
}

#[tauri::command]
fn start_task(
    app: AppHandle,
    sidecar: State<SidecarState>,
    state: State<WorkerState>,
    request: Value,
) -> Result<StartTaskResponse, String> {
    let root = repo_root(&app)?;
    let submitted = sidecar_call_root(sidecar.inner(), &root, "runtime.submitRun", json!({"request": request}), false)?;
    let task_id = submitted
        .get("task_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let started_task_id = launch_next_worker(app, sidecar.inner().clone(), state.inner().clone(), root)?;
    Ok(StartTaskResponse {
        started: started_task_id.is_some(),
        task_id,
    })
}

#[tauri::command]
fn resume_task(
    app: AppHandle,
    sidecar: State<SidecarState>,
    state: State<WorkerState>,
    request: Value,
) -> Result<StartTaskResponse, String> {
    let root = repo_root(&app)?;
    let submitted = sidecar_call_root(sidecar.inner(), &root, "runtime.submitResume", json!({"request": request}), false)?;
    let task_id = submitted
        .get("task_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let started_task_id = launch_next_worker(app, sidecar.inner().clone(), state.inner().clone(), root)?;
    Ok(StartTaskResponse {
        started: started_task_id.is_some(),
        task_id,
    })
}

#[tauri::command]
fn cancel_task(app: AppHandle, sidecar: State<SidecarState>, state: State<WorkerState>, task_id: String) -> Result<Value, String> {
    *state.task_id.lock().map_err(|err| err.to_string())? = Some(task_id.clone());
    sidecar_call(&app, sidecar.inner(), "runtime.cancel", json!({"task_id": task_id, "force_after_grace": 15}))
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
        .manage(SidecarState::default())
        .invoke_handler(tauri::generate_handler![
            get_config,
            desktop_snapshot,
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
