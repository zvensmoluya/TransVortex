import React, { useEffect, useMemo, useState } from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { open } from "@tauri-apps/plugin-dialog";
import {
  CheckCircle2,
  CircleAlert,
  ClipboardList,
  FolderOpen,
  KeyRound,
  Loader2,
  Play,
  RefreshCw,
  Square,
  Video,
} from "lucide-react";
import "./styles.css";

type ProviderConfig = {
  name: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  env_key: string;
  has_key: boolean;
  models: string[];
};

type ConfigPayload = {
  root_dir: string;
  artifacts_dir: string;
  pipeline: Record<string, unknown>;
  routing: { primary: { provider: string; model: string } };
  providers: ProviderConfig[];
};

type TaskRecord = {
  task_id: string;
  status: string;
  input_file: string;
  source_lang: string;
  target_lang: string;
  bilingual: boolean;
  created_at: string;
  updated_at: string;
  output_path?: string | null;
  output_paths?: Record<string, string>;
  task_dir?: string;
  error?: string | null;
};

type WorkerEvent = {
  type: string;
  task_id?: string;
  created_at?: string;
  stage?: string;
  level?: string;
  message?: string;
  progress?: number;
  details?: Record<string, unknown>;
};

type DoctorCheck = {
  name: string;
  status: "PASS" | "WARN" | "FAIL";
  code: string;
  message: string;
  hint_zh?: string;
  details?: Record<string, unknown>;
};

type DoctorPayload = {
  status: "PASS" | "WARN" | "FAIL";
  root_dir: string;
  providers_file?: string;
  artifacts_dir?: string;
  checks: DoctorCheck[];
};

type FormState = {
  input: string;
  outputDir: string;
  sourceLang: string;
  targetLang: string;
  bilingual: boolean;
  provider: string;
  model: string;
  asrMode: string;
  asrDevice: string;
  asrModelSize: string;
  asrComputeType: string;
  asrProvider: string;
  asrModel: string;
  chunkSeconds: number;
  chunkOverlapSeconds: number;
  translationBatchSize: number;
  translationStylePreset: string;
  translationStylePrompt: string;
  translationChunkLines: number;
  translationContextBeforeLines: number;
  translationContextAfterLines: number;
  translationRepairEnabled: boolean;
  outputFormat: "srt" | "ass" | "both";
  concurrency: number;
  apiKey: string;
};

const emptyForm: FormState = {
  input: "",
  outputDir: "",
  sourceLang: "en",
  targetLang: "zh-CN",
  bilingual: true,
  provider: "",
  model: "",
  asrMode: "local",
  asrDevice: "cpu",
  asrModelSize: "small",
  asrComputeType: "int8",
  asrProvider: "",
  asrModel: "whisper-1",
  chunkSeconds: 60,
  chunkOverlapSeconds: 1,
  translationBatchSize: 40,
  translationStylePreset: "subtitle_natural",
  translationStylePrompt: "",
  translationChunkLines: 40,
  translationContextBeforeLines: 20,
  translationContextAfterLines: 10,
  translationRepairEnabled: true,
  outputFormat: "srt",
  concurrency: 8,
  apiKey: "",
};

function textValue(value: unknown, fallback: string) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function numberValue(value: unknown, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function eventOutputPath(event: WorkerEvent) {
  const value = event.details?.output_path;
  return typeof value === "string" ? value : "";
}

function outputPath(task: TaskRecord, key: string) {
  return task.output_paths?.[key] || "";
}

type DroppedFile = File & { path?: string };

function App() {
  const [config, setConfig] = useState<ConfigPayload | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [tasks, setTasks] = useState<TaskRecord[]>([]);
  const [events, setEvents] = useState<WorkerEvent[]>([]);
  const [doctorReport, setDoctorReport] = useState<DoctorPayload | null>(null);
  const [running, setRunning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const selectedProvider = useMemo(
    () => config?.providers.find((provider) => provider.name === form.provider),
    [config, form.provider],
  );

  const progress = useMemo(() => {
    const latest = [...events].reverse().find((event) => typeof event.progress === "number");
    return Math.round((latest?.progress ?? 0) * 100);
  }, [events]);

  const importantChecks = useMemo(() => {
    const names = new Set([
      "python",
      "ffmpeg",
      "ffprobe",
      "faster_whisper",
      "provider_env_key",
      "provider_protocol",
      "artifacts",
    ]);
    return doctorReport?.checks.filter((check) => names.has(check.name)) || [];
  }, [doctorReport]);

  function friendlyError(err: unknown) {
    const text = String(err);
    try {
      const payload = JSON.parse(text) as { checks?: DoctorCheck[]; message?: string };
      const failed = payload.checks?.find((check) => check.status === "FAIL");
      if (failed) return `${failed.hint_zh || failed.message} (${failed.code})`;
      return payload.message || text;
    } catch {
      return text;
    }
  }

  async function refreshConfig() {
    const payload = await invoke<ConfigPayload>("get_config");
    setConfig(payload);
    setForm((current) => {
      const provider = current.provider || payload.routing.primary.provider;
      const providerConfig = payload.providers.find((item) => item.name === provider);
      return {
        ...current,
        provider,
        model: current.model || payload.routing.primary.model || providerConfig?.models[0] || "",
        asrMode: textValue(payload.pipeline.asr_mode, current.asrMode),
        asrDevice: textValue(payload.pipeline.asr_device, current.asrDevice),
        asrModelSize: textValue(payload.pipeline.asr_model_size, current.asrModelSize),
        asrComputeType: textValue(payload.pipeline.asr_compute_type, current.asrComputeType),
        asrProvider: textValue(payload.pipeline.asr_provider, current.asrProvider),
        asrModel: textValue(payload.pipeline.asr_provider_model, current.asrModel),
        chunkSeconds: numberValue(payload.pipeline.chunk_seconds, current.chunkSeconds),
        chunkOverlapSeconds: numberValue(payload.pipeline.chunk_overlap_seconds, current.chunkOverlapSeconds),
        translationBatchSize: numberValue(payload.pipeline.translation_batch_size, current.translationBatchSize),
        translationStylePreset: textValue(
          (payload.pipeline.translation as Record<string, unknown> | undefined)?.style_preset,
          current.translationStylePreset,
        ),
        translationStylePrompt: textValue(
          (payload.pipeline.translation as Record<string, unknown> | undefined)?.style_prompt,
          current.translationStylePrompt,
        ),
        translationChunkLines: numberValue(
          (payload.pipeline.translation as Record<string, unknown> | undefined)?.chunk_lines,
          current.translationChunkLines,
        ),
        translationContextBeforeLines: numberValue(
          (payload.pipeline.translation as Record<string, unknown> | undefined)?.context_before_lines,
          current.translationContextBeforeLines,
        ),
        translationContextAfterLines: numberValue(
          (payload.pipeline.translation as Record<string, unknown> | undefined)?.context_after_lines,
          current.translationContextAfterLines,
        ),
        translationRepairEnabled:
          ((payload.pipeline.translation as { repair?: { enabled?: boolean } } | undefined)?.repair?.enabled ??
            current.translationRepairEnabled),
        outputFormat: textValue(payload.pipeline.output_format, current.outputFormat) as FormState["outputFormat"],
        concurrency: numberValue(payload.pipeline.default_concurrency, current.concurrency),
      };
    });
  }

  async function refreshTasks() {
    const payload = await invoke<TaskRecord[]>("list_tasks");
    setTasks(payload);
  }

  async function refreshDoctor() {
    const payload = await invoke<DoctorPayload>("doctor");
    setDoctorReport(payload);
  }

  async function boot() {
    setError("");
    try {
      await Promise.all([refreshConfig(), refreshTasks(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  useEffect(() => {
    boot();
    const unlistenPromise = listen<WorkerEvent>("worker-event", (event) => {
      setEvents((current) => [...current, event.payload].slice(-300));
      if (["done", "error", "cancelled"].includes(event.payload.type)) {
        setRunning(false);
        refreshTasks();
        refreshConfig();
        refreshDoctor();
      }
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, []);

  useEffect(() => {
    const unlistenPromise = getCurrentWebview().onDragDropEvent((event) => {
      if (event.payload.type === "drop" && event.payload.paths.length > 0) {
        update("input", event.payload.paths[0]);
      }
    });
    return () => {
      unlistenPromise.then((unlisten) => unlisten());
    };
  }, []);

  useEffect(() => {
    if (!selectedProvider) return;
    if (!selectedProvider.models.includes(form.model)) {
      setForm((current) => ({ ...current, model: selectedProvider.models[0] || "" }));
    }
  }, [selectedProvider?.name]);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function chooseVideo() {
    const selected = await open({
      multiple: false,
      filters: [{ name: "Video", extensions: ["mp4", "mkv", "mov", "webm", "avi"] }],
    });
    if (typeof selected === "string") update("input", selected);
  }

  async function chooseOutputDir() {
    const selected = await open({ multiple: false, directory: true });
    if (typeof selected === "string") update("outputDir", selected);
  }

  async function saveKey() {
    if (!selectedProvider || !form.apiKey.trim()) return;
    setBusy(true);
    setError("");
    try {
      await invoke("save_env_secret", { envKey: selectedProvider.env_key, value: form.apiKey.trim() });
      update("apiKey", "");
      setNotice("API key saved to .env");
      await Promise.all([refreshConfig(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function probe() {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("probe_provider", { provider: form.provider, model: form.model });
      setNotice("Provider preflight passed");
      await Promise.all([refreshConfig(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function startTask() {
    if (!form.input) {
      setError("Choose a video first.");
      return;
    }
    setRunning(true);
    setBusy(true);
    setEvents([]);
    setError("");
    setNotice("");
    try {
      await invoke("start_task", {
        request: {
          input: form.input,
          outputDir: form.outputDir || null,
          sourceLang: form.sourceLang,
          targetLang: form.targetLang,
          bilingual: form.bilingual,
          provider: form.provider || null,
          model: form.model || null,
          asrMode: form.asrMode || null,
          asrDevice: form.asrDevice || null,
          asrModelSize: form.asrModelSize || null,
          asrComputeType: form.asrComputeType || null,
          asrProvider: form.asrProvider || null,
          asrModel: form.asrModel || null,
          chunkSeconds: form.chunkSeconds,
          chunkOverlapSeconds: form.chunkOverlapSeconds,
          translationBatchSize: form.translationBatchSize,
          translationStylePreset: form.translationStylePreset,
          translationStylePrompt: form.translationStylePrompt,
          translationChunkLines: form.translationChunkLines,
          translationContextBeforeLines: form.translationContextBeforeLines,
          translationContextAfterLines: form.translationContextAfterLines,
          translationRepairEnabled: form.translationRepairEnabled,
          outputFormat: form.outputFormat,
          concurrency: form.concurrency,
        },
      });
    } catch (err) {
      setRunning(false);
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function cancelTask() {
    setBusy(true);
    try {
      await invoke("cancel_task");
      setNotice("Cancel requested");
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function resumeTask(taskId: string) {
    setRunning(true);
    setBusy(true);
    setEvents([]);
    setError("");
    setNotice("");
    try {
      await invoke("resume_task", {
        request: {
          taskId,
          provider: form.provider || null,
          model: form.model || null,
          asrMode: form.asrMode || null,
          asrDevice: form.asrDevice || null,
          asrModelSize: form.asrModelSize || null,
          asrComputeType: form.asrComputeType || null,
          asrProvider: form.asrProvider || null,
          asrModel: form.asrModel || null,
          chunkSeconds: form.chunkSeconds,
          chunkOverlapSeconds: form.chunkOverlapSeconds,
          translationBatchSize: form.translationBatchSize,
          translationStylePreset: form.translationStylePreset,
          translationStylePrompt: form.translationStylePrompt,
          translationChunkLines: form.translationChunkLines,
          translationContextBeforeLines: form.translationContextBeforeLines,
          translationContextAfterLines: form.translationContextAfterLines,
          translationRepairEnabled: form.translationRepairEnabled,
          outputFormat: form.outputFormat,
          concurrency: form.concurrency,
        },
      });
    } catch (err) {
      setRunning(false);
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function openPath(path?: string | null) {
    if (!path) return;
    try {
      await invoke("open_path", { path });
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  async function loadTaskEvents(taskId: string) {
    try {
      const payload = await invoke<WorkerEvent[]>("read_events", { taskId });
      setEvents(payload);
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  const latestDonePath = [...events].reverse().map(eventOutputPath).find(Boolean);

  return (
    <main className="app">
      <header className="topbar">
        <div>
          <h1>TransVortex</h1>
          <p>{config?.root_dir || "Loading workspace..."}</p>
        </div>
        <button className="iconButton" onClick={boot} title="Refresh">
          <RefreshCw size={18} />
        </button>
      </header>

      {(error || notice) && (
        <div className={error ? "banner error" : "banner success"}>
          {error ? <CircleAlert size={18} /> : <CheckCircle2 size={18} />}
          <span>{error || notice}</span>
        </div>
      )}

      <section className="workspace">
        <div className="mainPanel">
          <section className="settingsPanel">
            <div className="sectionHead">
              <h2>Input</h2>
            </div>
            <section
              className="dropZone"
              onDragOver={(event) => event.preventDefault()}
              onDrop={(event) => {
                event.preventDefault();
                const file = event.dataTransfer.files.item(0) as DroppedFile | null;
                if (file) update("input", file.path || file.name);
              }}
            >
              <Video size={34} />
              <div>
                <strong>{form.input || "Drop a video here"}</strong>
                <span>{form.input ? "Ready for subtitle generation" : "MP4, MKV, MOV, WEBM, AVI"}</span>
              </div>
              <button onClick={chooseVideo}>
                <FolderOpen size={17} /> Choose
              </button>
            </section>
            <div className="grid two">
              <label>
                Source language
                <input value={form.sourceLang} onChange={(event) => update("sourceLang", event.target.value)} />
              </label>
              <label>
                Target language
                <input value={form.targetLang} onChange={(event) => update("targetLang", event.target.value)} />
              </label>
            </div>
          </section>

          <section className="settingsPanel">
            <div className="sectionHead">
              <h2>Provider</h2>
            </div>
            <div className="grid two">
              <label>
                Provider
                <select value={form.provider} onChange={(event) => update("provider", event.target.value)}>
                  {config?.providers.map((provider) => (
                    <option key={provider.name} value={provider.name}>
                      {provider.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Model
                <select value={form.model} onChange={(event) => update("model", event.target.value)}>
                  {selectedProvider?.models.map((model) => (
                    <option key={model} value={model}>
                      {model}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            <section className="secretRow">
              <KeyRound size={18} />
              <div>
                <strong>{selectedProvider?.env_key || "Provider key"}</strong>
                <span>{selectedProvider?.has_key ? "Configured" : "Missing"}</span>
              </div>
              <input
                type="password"
                placeholder="Paste key"
                value={form.apiKey}
                onChange={(event) => update("apiKey", event.target.value)}
              />
              <button disabled={!form.apiKey || busy} onClick={saveKey}>
                Save
              </button>
            </section>
          </section>

          <section className="settingsPanel">
            <div className="sectionHead">
              <h2>ASR</h2>
            </div>
            <div className="grid four">
              <label>
                ASR mode
                <select value={form.asrMode} onChange={(event) => update("asrMode", event.target.value)}>
                  <option value="local">local</option>
                  <option value="openai">openai</option>
                </select>
              </label>
              <label>
                Device
                <select value={form.asrDevice} onChange={(event) => update("asrDevice", event.target.value)}>
                  <option value="cpu">cpu</option>
                  <option value="auto">auto</option>
                  <option value="cuda">cuda</option>
                </select>
              </label>
              <label>
                Model size
                <input value={form.asrModelSize} onChange={(event) => update("asrModelSize", event.target.value)} />
              </label>
              <label>
                Compute
                <input value={form.asrComputeType} onChange={(event) => update("asrComputeType", event.target.value)} />
              </label>
            </div>
          </section>

          <section className="settingsPanel">
            <div className="sectionHead">
              <h2>Translation</h2>
            </div>
            <div className="grid four">
              <label>
                Preset
                <select
                  value={form.translationStylePreset}
                  onChange={(event) => update("translationStylePreset", event.target.value)}
                >
                  <option value="subtitle_natural">subtitle_natural</option>
                  <option value="literal">literal</option>
                  <option value="localized">localized</option>
                  <option value="learning_friendly">learning_friendly</option>
                </select>
              </label>
              <label>
                Chunk lines
                <input
                  type="number"
                  value={form.translationChunkLines}
                  onChange={(event) => {
                    update("translationChunkLines", Number(event.target.value));
                    update("translationBatchSize", Number(event.target.value));
                  }}
                />
              </label>
              <label>
                Context before
                <input
                  type="number"
                  value={form.translationContextBeforeLines}
                  onChange={(event) => update("translationContextBeforeLines", Number(event.target.value))}
                />
              </label>
              <label>
                Context after
                <input
                  type="number"
                  value={form.translationContextAfterLines}
                  onChange={(event) => update("translationContextAfterLines", Number(event.target.value))}
                />
              </label>
            </div>
            <label>
              Style prompt
              <textarea
                value={form.translationStylePrompt}
                onChange={(event) => update("translationStylePrompt", event.target.value)}
              />
            </label>
            <label className="check">
              <input
                type="checkbox"
                checked={form.translationRepairEnabled}
                onChange={(event) => update("translationRepairEnabled", event.target.checked)}
              />
              Repair invalid rows
            </label>
          </section>

          <section className="settingsPanel">
            <div className="sectionHead">
              <h2>Output</h2>
            </div>
            <div className="grid four">
              <label>
                Format
                <select
                  value={form.outputFormat}
                  onChange={(event) => update("outputFormat", event.target.value as FormState["outputFormat"])}
                >
                  <option value="srt">srt</option>
                  <option value="ass">ass</option>
                  <option value="both">both</option>
                </select>
              </label>
              <label>
                Output directory
                <div className="joined">
                  <input value={form.outputDir} onChange={(event) => update("outputDir", event.target.value)} />
                  <button onClick={chooseOutputDir}>
                    <FolderOpen size={16} />
                  </button>
                </div>
              </label>
              <label>
                Chunk sec
                <input
                  type="number"
                  value={form.chunkSeconds}
                  onChange={(event) => update("chunkSeconds", Number(event.target.value))}
                />
              </label>
              <label>
                Concurrency
                <input
                  type="number"
                  value={form.concurrency}
                  onChange={(event) => update("concurrency", Number(event.target.value))}
                />
              </label>
            </div>
          </section>

          <div className="actionRow">
            <label className="check">
              <input
                type="checkbox"
                checked={form.bilingual}
                onChange={(event) => update("bilingual", event.target.checked)}
              />
              Bilingual
            </label>
            <button onClick={probe} disabled={busy}>
              <ClipboardList size={17} /> Preflight
            </button>
            {running ? (
              <button className="danger" onClick={cancelTask} disabled={busy}>
                <Square size={17} /> Cancel
              </button>
            ) : (
              <button className="primary" onClick={startTask} disabled={busy}>
                {busy ? <Loader2 className="spin" size={17} /> : <Play size={17} />} Start
              </button>
            )}
          </div>
        </div>

        <aside className="sidePanel">
          <section className="progressBox">
            <div className="progressHead">
              <span>{running ? "Running" : "Progress"}</span>
              <strong>{progress}%</strong>
            </div>
            <div className="track">
              <div style={{ width: `${progress}%` }} />
            </div>
            {latestDonePath && (
              <button onClick={() => openPath(latestDonePath)}>
                <FolderOpen size={16} /> Open output
              </button>
            )}
          </section>

          {doctorReport && (
            <section className={`healthBox ${doctorReport.status.toLowerCase()}`}>
              <div className="sectionHead">
                <h2>Environment</h2>
                <strong>{doctorReport.status}</strong>
              </div>
              <div className="checkList">
                {importantChecks.map((check) => (
                  <article key={check.name} className={`checkItem ${check.status.toLowerCase()}`}>
                    <span>{check.name}</span>
                    <strong>{check.status}</strong>
                    <p>{check.hint_zh || check.message}</p>
                  </article>
                ))}
              </div>
            </section>
          )}

          <section className="eventList">
            <h2>Events</h2>
            {events.length === 0 && <p className="muted">No events yet.</p>}
            {[...events].reverse().slice(0, 12).map((event, index) => (
              <article key={`${event.created_at}-${index}`} className={`event ${event.level || event.type}`}>
                <span>{event.stage || event.type}</span>
                <p>{event.message || event.type}</p>
              </article>
            ))}
          </section>
        </aside>
      </section>

      <section className="history">
        <div className="sectionHead">
          <h2>History</h2>
          <button onClick={refreshTasks}>
            <RefreshCw size={16} /> Refresh
          </button>
        </div>
        <div className="taskGrid">
          {tasks.map((task) => (
            <article key={task.task_id} className="taskCard">
              <div>
                <strong>{task.task_id}</strong>
                <span>{task.status}</span>
              </div>
              <p>{task.input_file}</p>
              {task.error && <p className="taskError">{task.error}</p>}
              <footer>
                <button onClick={() => loadTaskEvents(task.task_id)}>Events</button>
                <button onClick={() => openPath(task.task_dir)}>Folder</button>
                {outputPath(task, "srt") && <button onClick={() => openPath(outputPath(task, "srt"))}>SRT</button>}
                {outputPath(task, "ass") && <button onClick={() => openPath(outputPath(task, "ass"))}>ASS</button>}
                {!outputPath(task, "srt") && !outputPath(task, "ass") && task.output_path && (
                  <button onClick={() => openPath(task.output_path)}>Output</button>
                )}
                {["FAILED", "CANCELLED", "CANCEL_REQUESTED"].includes(task.status) && (
                  <button disabled={running || busy} onClick={() => resumeTask(task.task_id)}>
                    Resume
                  </button>
                )}
              </footer>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
