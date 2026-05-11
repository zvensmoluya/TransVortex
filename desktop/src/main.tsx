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
  Database,
  DownloadCloud,
  FolderOpen,
  History,
  KeyRound,
  Languages,
  Loader2,
  MonitorCheck,
  Play,
  Plus,
  RefreshCw,
  Save,
  SearchCheck,
  Settings2,
  SlidersHorizontal,
  Square,
  Trash2,
  Video,
  Wifi,
} from "lucide-react";
import "./styles.css";

const zh = {
  appSubtitle: "本地视频转字幕工作台",
  start: "开始任务",
  translation: "翻译设置",
  provider: "模型与 ASR",
  history: "任务历史",
  environment: "环境诊断",
  result: "结果检查",
  refresh: "刷新",
  choose: "选择",
  cancel: "取消",
  startRun: "开始运行",
  preflight: "预检 provider",
  save: "保存",
  openOutput: "打开输出",
  events: "事件",
  folder: "目录",
  resume: "恢复",
  noEvents: "暂无事件。",
  noTasks: "暂无历史任务。",
  dropVideo: "拖入视频文件",
  videoReady: "视频已选择，可以开始生成字幕",
  videoHint: "支持 MP4、MKV、MOV、WEBM、AVI",
  sourceLang: "源语言",
  targetLang: "目标语言",
  outputDir: "输出目录",
  outputFormat: "输出格式",
  bilingual: "双语字幕",
  providerName: "Provider",
  model: "模型",
  apiKey: "API Key",
  pasteKey: "粘贴 key",
  saveProvider: "保存 provider",
  testConnection: "测试连接",
  fetchModels: "拉取模型",
  useForTask: "用于当前任务",
  newProvider: "新建 provider",
  deleteProvider: "删除",
  customModel: "自定义模型",
  addModel: "添加模型",
  baseUrl: "Base URL",
  compatMode: "兼容协议",
  envKey: "环境变量",
  endpointPath: "接口路径",
  authType: "鉴权方式",
  responsePaths: "响应文本路径",
  modelListPath: "模型列表路径",
  providerSaved: "Provider 配置已保存",
  providerDeleted: "Provider 已删除",
  modelsFetched: "模型列表已更新",
  connectionPassed: "Provider 联网测试通过",
  configured: "已配置",
  missing: "未配置",
  asrMode: "ASR 模式",
  device: "设备",
  modelSize: "模型大小",
  compute: "计算精度",
  advanced: "高级设置",
  chunkSec: "切片秒数",
  overlapSec: "重叠秒数",
  concurrency: "并发",
  preset: "翻译风格",
  stylePrompt: "自定义 prompt",
  chunkLines: "每批行数",
  contextBefore: "前文行数",
  contextAfter: "后文行数",
  repairRows: "自动修复无效行",
  progress: "进度",
  running: "运行中",
  environmentSummary: "环境摘要",
  latestEvents: "最新事件",
  keySaved: "API key 已保存到 .env",
  preflightPassed: "Provider 预检通过",
  cancelRequested: "已请求取消",
  chooseVideoFirst: "请先选择一个输入文件。",
  inputType: "输入类型",
  videoInput: "视频",
  srtInput: "SRT 字幕",
  inspect: "检查",
  timeline: "时间轴",
  reexport: "重新导出",
  saveEdits: "保存修改",
  resultSaved: "结果修改已保存",
  reexported: "字幕已重新导出",
  routing: "Fallback 路由",
};

function t(key: keyof typeof zh) {
  return zh[key];
}

type ProviderConfig = {
  name: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  env_key: string;
  has_key: boolean;
  models: string[];
  auth?: AuthConfig;
  endpoint?: EndpointConfig;
  request_mapping?: Record<string, unknown>;
  response_mapping?: { text_paths?: string[] };
  extra_headers?: Record<string, string>;
  model_list?: ModelListConfig;
  capabilities?: Record<string, unknown>;
  limits?: Record<string, unknown>;
};

type AuthConfig = {
  type: string;
  header_name?: string;
  query_name?: string;
  prefix?: string;
};

type EndpointConfig = {
  path_template: string;
  method: string;
};

type ModelListConfig = {
  path_template: string;
  method: string;
  response_paths: string[];
};

type ProviderTemplate = {
  id: string;
  label: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  endpoint: EndpointConfig;
  auth: AuthConfig;
  request_mapping: Record<string, unknown>;
  response_mapping: { text_paths?: string[] };
  extra_headers?: Record<string, string>;
  model_list: ModelListConfig;
  capabilities?: Record<string, unknown>;
};

type RouteTarget = { provider: string; model: string };

type ConfigPayload = {
  root_dir: string;
  artifacts_dir: string;
  pipeline: Record<string, unknown>;
  routing: { primary: RouteTarget; fallback?: RouteTarget[] };
  provider_templates: ProviderTemplate[];
  providers: ProviderConfig[];
};

type ProviderDraft = {
  name: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  env_key: string;
  models: string[];
  auth: AuthConfig;
  endpoint: EndpointConfig;
  request_mapping: Record<string, unknown>;
  response_mapping: { text_paths: string[] };
  extra_headers: Record<string, string>;
  model_list: ModelListConfig;
  capabilities: Record<string, unknown>;
};

type ProviderDiagnostic = {
  name?: string;
  status: "PASS" | "WARN" | "FAIL";
  code: string;
  message: string;
  hint_zh?: string;
  details?: Record<string, unknown>;
};

type ProviderTestPayload = {
  status: "PASS" | "WARN" | "FAIL";
  checks: ProviderDiagnostic[];
};

type ProviderModelsPayload = ProviderDiagnostic & {
  models: string[];
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

type ResultSegment = {
  id: number;
  start: number;
  end: number;
  text_src: string;
  text_tgt?: string | null;
  provider?: string;
  model?: string;
  compat_mode?: string;
  chunk_id?: string;
  issues?: string[];
};

type TaskResultPayload = {
  task: TaskRecord & { settings?: Record<string, unknown>; task_dir?: string };
  segments: ResultSegment[];
  output_paths?: Record<string, string>;
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

type ActiveView = "start" | "translation" | "provider" | "history" | "result" | "environment";

type FormState = {
  input: string;
  inputType: "video" | "srt";
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
  inputType: "video",
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

type DroppedFile = File & { path?: string };

const languageOptions = [
  { code: "en", label: "英语" },
  { code: "zh-CN", label: "中文简体" },
  { code: "zh-TW", label: "中文繁体" },
  { code: "ja", label: "日语" },
  { code: "ko", label: "韩语" },
  { code: "fr", label: "法语" },
  { code: "es", label: "西班牙语" },
  { code: "de", label: "德语" },
  { code: "ru", label: "俄语" },
];

function textValue(value: unknown, fallback: string) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function numberValue(value: unknown, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function arrayValue(value: unknown) {
  return Array.isArray(value) ? value.map(String).filter(Boolean) : [];
}

function defaultTemplate(config: ConfigPayload | null) {
  return config?.provider_templates.find((item) => item.id === "openai_chat") || config?.provider_templates[0];
}

function envKeyForName(name: string) {
  const slug = name.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").toUpperCase() || "CUSTOM";
  return `TVX_PROVIDER_${slug}_API_KEY`;
}

function providerToDraft(provider: ProviderConfig): ProviderDraft {
  return {
    name: provider.name,
    api_type: provider.api_type,
    compat_mode: provider.compat_mode,
    base_url: provider.base_url,
    env_key: provider.env_key,
    models: provider.models || [],
    auth: provider.auth || { type: "bearer", header_name: "Authorization", query_name: "key", prefix: "Bearer " },
    endpoint: provider.endpoint || { path_template: "/chat/completions", method: "POST" },
    request_mapping: provider.request_mapping || { style: provider.compat_mode },
    response_mapping: { text_paths: provider.response_mapping?.text_paths || [] },
    extra_headers: provider.extra_headers || {},
    model_list: provider.model_list || { path_template: "/models", method: "GET", response_paths: ["data[].id"] },
    capabilities: provider.capabilities || {},
  };
}

function templateToDraft(template: ProviderTemplate, name = "custom_provider"): ProviderDraft {
  return {
    name,
    api_type: template.api_type,
    compat_mode: template.compat_mode,
    base_url: template.base_url,
    env_key: envKeyForName(name),
    models: [],
    auth: { ...template.auth },
    endpoint: { ...template.endpoint },
    request_mapping: { ...template.request_mapping },
    response_mapping: { text_paths: [...(template.response_mapping?.text_paths || [])] },
    extra_headers: { ...(template.extra_headers || {}) },
    model_list: {
      path_template: template.model_list?.path_template || "/models",
      method: template.model_list?.method || "GET",
      response_paths: [...(template.model_list?.response_paths || ["data[].id"])],
    },
    capabilities: { ...(template.capabilities || {}) },
  };
}

function diagnosticText(payload?: ProviderDiagnostic | ProviderTestPayload | null) {
  if (!payload) return "";
  if ("checks" in payload) {
    const failed = payload.checks.find((check) => check.status === "FAIL") || payload.checks[0];
    return failed ? `${failed.hint_zh || failed.message} (${failed.code})` : payload.status;
  }
  return `${payload.hint_zh || payload.message} (${payload.code})`;
}

function outputPath(task: TaskRecord, key: string) {
  return task.output_paths?.[key] || "";
}

function eventOutputPath(event: WorkerEvent) {
  const value = event.details?.output_path;
  return typeof value === "string" ? value : "";
}

function statusTone(status: string) {
  if (status === "PASS" || status === "DONE") return "text-brand";
  if (status === "WARN" || status === "CANCELLED") return "text-warning";
  if (status === "FAIL" || status === "FAILED") return "text-danger";
  return "text-muted";
}

function formatClock(seconds: number) {
  const safe = Math.max(0, seconds || 0);
  const h = Math.floor(safe / 3600);
  const m = Math.floor((safe % 3600) / 60);
  const s = Math.floor(safe % 60);
  const ms = Math.round((safe - Math.floor(safe)) * 1000);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
}

function parseClock(value: string) {
  const parts = value.replace(",", ".").split(":");
  if (parts.length !== 3) return Number(value) || 0;
  const [h, m, rest] = parts;
  const [s, ms = "0"] = rest.split(".");
  return Number(h) * 3600 + Number(m) * 60 + Number(s) + Number((ms + "000").slice(0, 3)) / 1000;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJsonObject(value: string) {
  try {
    const parsed = JSON.parse(value || "{}");
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function cloneRecord(value: Record<string, unknown>) {
  return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

function getPathValue(root: Record<string, unknown>, path: string) {
  let current: unknown = root;
  for (const token of path.split(".")) {
    if (!isRecord(current)) return undefined;
    current = current[token];
  }
  return current;
}

function setPathValue(root: Record<string, unknown>, path: string, value: unknown) {
  const tokens = path.split(".").filter(Boolean);
  if (tokens.length === 0) return;
  let current: Record<string, unknown> = root;
  tokens.slice(0, -1).forEach((token) => {
    if (!isRecord(current[token])) current[token] = {};
    current = current[token] as Record<string, unknown>;
  });
  current[tokens[tokens.length - 1]] = value;
}

function deletePathValue(root: Record<string, unknown>, path: string) {
  const tokens = path.split(".").filter(Boolean);
  if (tokens.length === 0) return;
  let current: unknown = root;
  tokens.slice(0, -1).forEach((token) => {
    current = isRecord(current) ? current[token] : undefined;
  });
  if (isRecord(current)) delete current[tokens[tokens.length - 1]];
}

function formatJsonObject(value: Record<string, unknown>) {
  return JSON.stringify(value, null, 2);
}

function updateRequestMappingJson(raw: string, updater: (mapping: Record<string, unknown>) => void) {
  const parsed = parseJsonObject(raw);
  if (!parsed) return raw;
  const next = cloneRecord(parsed);
  updater(next);
  return formatJsonObject(next);
}

function requestBodyPath(path: string) {
  return `body_overrides.${path}`;
}

function setRequestBodyOverride(raw: string, path: string, value: unknown) {
  return updateRequestMappingJson(raw, (mapping) => {
    if (value === "" || value === undefined || value === null) {
      deletePathValue(mapping, requestBodyPath(path));
      return;
    }
    setPathValue(mapping, requestBodyPath(path), value);
  });
}

const tokenLimitFields = [
  { value: "auto", label: "不指定" },
  { value: "max_tokens", label: "max_tokens" },
  { value: "max_completion_tokens", label: "max_completion_tokens" },
  { value: "generationConfig.maxOutputTokens", label: "Gemini maxOutputTokens" },
];

function tokenLimitFieldForMapping(mapping: Record<string, unknown> | null) {
  if (!mapping) return "auto";
  if (getPathValue(mapping, "max_tokens") !== undefined) return "max_tokens";
  if (getPathValue(mapping, requestBodyPath("max_completion_tokens")) !== undefined) return "max_completion_tokens";
  if (getPathValue(mapping, requestBodyPath("max_tokens")) !== undefined) return "max_tokens";
  if (getPathValue(mapping, requestBodyPath("generationConfig.maxOutputTokens")) !== undefined) return "generationConfig.maxOutputTokens";
  return "auto";
}

function tokenLimitValueForMapping(mapping: Record<string, unknown> | null) {
  if (!mapping) return "";
  const field = tokenLimitFieldForMapping(mapping);
  if (field === "auto") return "";
  if (field === "max_tokens") {
    return String(getPathValue(mapping, "max_tokens") ?? getPathValue(mapping, requestBodyPath("max_tokens")) ?? "");
  }
  return String(getPathValue(mapping, requestBodyPath(field)) ?? "");
}

function setTokenLimit(raw: string, field: string, value: string) {
  return updateRequestMappingJson(raw, (mapping) => {
    deletePathValue(mapping, "max_tokens");
    deletePathValue(mapping, requestBodyPath("max_tokens"));
    deletePathValue(mapping, requestBodyPath("max_completion_tokens"));
    deletePathValue(mapping, requestBodyPath("generationConfig.maxOutputTokens"));
    const parsedValue = value === "" ? undefined : Number(value);
    if (field === "auto" || parsedValue === undefined || !Number.isFinite(parsedValue)) return;
    if (field === "max_tokens") {
      setPathValue(mapping, "max_tokens", parsedValue);
      return;
    }
    setPathValue(mapping, requestBodyPath(field), parsedValue);
  });
}

function fieldTranslation(payload: ConfigPayload["pipeline"]) {
  return payload.translation as
    | {
        style_preset?: string;
        style_prompt?: string;
        chunk_lines?: number;
        context_before_lines?: number;
        context_after_lines?: number;
        repair?: { enabled?: boolean };
      }
    | undefined;
}

function App() {
  const [activeView, setActiveView] = useState<ActiveView>("start");
  const [config, setConfig] = useState<ConfigPayload | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [tasks, setTasks] = useState<TaskRecord[]>([]);
  const [events, setEvents] = useState<WorkerEvent[]>([]);
  const [doctorReport, setDoctorReport] = useState<DoctorPayload | null>(null);
  const [running, setRunning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [providerDraft, setProviderDraft] = useState<ProviderDraft | null>(null);
  const [providerTemplateId, setProviderTemplateId] = useState("openai_chat");
  const [requestMappingText, setRequestMappingText] = useState("");
  const [providerAdvancedOpen, setProviderAdvancedOpen] = useState(false);
  const [providerResult, setProviderResult] = useState<ProviderDiagnostic | ProviderTestPayload | null>(null);
  const [customModel, setCustomModel] = useState("");
  const [routingDraft, setRoutingDraft] = useState<{ primary: RouteTarget; fallback: RouteTarget[] }>({
    primary: { provider: "", model: "" },
    fallback: [],
  });
  const [taskResult, setTaskResult] = useState<TaskResultPayload | null>(null);
  const [selectedSegmentId, setSelectedSegmentId] = useState<number | null>(null);

  const selectedProvider = useMemo(
    () => config?.providers.find((provider) => provider.name === form.provider),
    [config, form.provider],
  );

  const selectedTemplate = useMemo(
    () => config?.provider_templates.find((template) => template.id === providerTemplateId) || config?.provider_templates.find((template) => template.compat_mode === providerDraft?.compat_mode),
    [config, providerDraft?.compat_mode, providerTemplateId],
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
      return `操作失败：${text}`;
    }
  }

  async function refreshConfig() {
    const payload = await invoke<ConfigPayload>("get_config");
    const translation = fieldTranslation(payload.pipeline);
    setConfig(payload);
    setRoutingDraft({
      primary: payload.routing.primary,
      fallback: payload.routing.fallback || [],
    });
    setProviderDraft((current) => {
      if (current) return current;
      const providerName = payload.routing.primary.provider || payload.providers[0]?.name || "";
      const providerConfig = payload.providers.find((item) => item.name === providerName) || payload.providers[0];
      if (providerConfig) return providerToDraft(providerConfig);
      const template = defaultTemplate(payload);
      return template ? templateToDraft(template) : current;
    });
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
        translationStylePreset: textValue(translation?.style_preset, current.translationStylePreset),
        translationStylePrompt: textValue(translation?.style_prompt, current.translationStylePrompt),
        translationChunkLines: numberValue(translation?.chunk_lines, current.translationChunkLines),
        translationContextBeforeLines: numberValue(
          translation?.context_before_lines,
          current.translationContextBeforeLines,
        ),
        translationContextAfterLines: numberValue(translation?.context_after_lines, current.translationContextAfterLines),
        translationRepairEnabled: translation?.repair?.enabled ?? current.translationRepairEnabled,
        outputFormat: textValue(payload.pipeline.output_format, current.outputFormat) as FormState["outputFormat"],
        concurrency: numberValue(payload.pipeline.default_concurrency, current.concurrency),
      };
    });
  }

  async function refreshTasks() {
    setTasks(await invoke<TaskRecord[]>("list_tasks"));
  }

  async function refreshDoctor() {
    setDoctorReport(await invoke<DoctorPayload>("doctor"));
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

  useEffect(() => {
    if (!selectedProvider) return;
    const draft = providerToDraft(selectedProvider);
    const template =
      config?.provider_templates.find((item) => item.compat_mode === draft.compat_mode && item.base_url === draft.base_url) ||
      config?.provider_templates.find((item) => item.compat_mode === draft.compat_mode);
    setProviderTemplateId(template?.id || draft.compat_mode);
    setProviderDraft(draft);
    setRequestMappingText(JSON.stringify(draft.request_mapping, null, 2));
    setProviderResult(null);
    setCustomModel("");
  }, [selectedProvider?.name, config?.provider_templates]);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function updateProviderDraft(patch: Partial<ProviderDraft>) {
    setProviderDraft((current) => {
      const template = defaultTemplate(config);
      const base = current || (template ? templateToDraft(template) : null);
      if (!base) return current;
      return { ...base, ...patch };
    });
    if (patch.request_mapping) setRequestMappingText(JSON.stringify(patch.request_mapping, null, 2));
  }

  function updateProviderTemplate(templateId: string) {
    const template =
      config?.provider_templates.find((item) => item.id === templateId) ||
      config?.provider_templates.find((item) => item.compat_mode === templateId);
    if (!template) return;
    setProviderTemplateId(template.id);
    setProviderDraft((current) => {
      const base = current || templateToDraft(template);
      return {
        ...base,
        api_type: template.api_type,
        compat_mode: template.compat_mode,
        base_url: base.base_url || template.base_url,
        auth: { ...template.auth },
        endpoint: { ...template.endpoint },
        request_mapping: { ...template.request_mapping },
        response_mapping: { text_paths: [...(template.response_mapping?.text_paths || [])] },
        extra_headers: { ...(template.extra_headers || {}) },
        model_list: {
          path_template: template.model_list?.path_template || "/models",
          method: template.model_list?.method || "GET",
          response_paths: [...(template.model_list?.response_paths || ["data[].id"])],
        },
        capabilities: { ...(template.capabilities || {}) },
      };
    });
    setRequestMappingText(JSON.stringify(template.request_mapping, null, 2));
  }

  function newProviderDraft() {
    const template = defaultTemplate(config);
    if (!template) return;
    const name = `custom_${Date.now().toString().slice(-5)}`;
    const draft = templateToDraft(template, name);
    setProviderTemplateId(template.id);
    setProviderDraft(draft);
    setRequestMappingText(JSON.stringify(draft.request_mapping, null, 2));
    setProviderResult(null);
    setCustomModel("");
  }

  function addCustomModel() {
    const model = customModel.trim();
    if (!model || !providerDraft) return;
    const models = providerDraft.models.includes(model) ? providerDraft.models : [...providerDraft.models, model];
    updateProviderDraft({ models });
    update("model", model);
    setCustomModel("");
  }

  async function chooseVideo() {
    const selected = await open({
      multiple: false,
      filters:
        form.inputType === "srt"
          ? [{ name: "Subtitle", extensions: ["srt"] }]
          : [{ name: "Video", extensions: ["mp4", "mkv", "mov", "webm", "avi"] }],
    });
    if (typeof selected === "string") update("input", selected);
  }

  async function chooseOutputDir() {
    const selected = await open({ multiple: false, directory: true });
    if (typeof selected === "string") update("outputDir", selected);
  }

  async function probe() {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("probe_provider", { provider: form.provider, model: form.model });
      setNotice(t("preflightPassed"));
      await Promise.all([refreshConfig(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function saveProvider() {
    if (!providerDraft) return;
    setBusy(true);
    setError("");
    setNotice("");
    setProviderResult(null);
    try {
      const requestMapping = JSON.parse(requestMappingText || "{}");
      if (!requestMapping || Array.isArray(requestMapping) || typeof requestMapping !== "object") {
        throw new Error("request_mapping 必须是 JSON object。");
      }
      await invoke("save_provider_config", {
        providerDraft: { ...providerDraft, request_mapping: requestMapping },
        apiKey: form.apiKey.trim() || null,
      });
      update("provider", providerDraft.name);
      update("model", providerDraft.models[0] || form.model);
      update("apiKey", "");
      setNotice(t("providerSaved"));
      await Promise.all([refreshConfig(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function saveRouting() {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("save_provider_routing", { routing: routingDraft });
      setNotice("Fallback 路由已保存");
      await refreshConfig();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function deleteProvider() {
    if (!providerDraft?.name) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("delete_provider_config", { name: providerDraft.name });
      setNotice(t("providerDeleted"));
      setProviderDraft(null);
      update("provider", "");
      update("model", "");
      await Promise.all([refreshConfig(), refreshDoctor()]);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function fetchModels() {
    if (!providerDraft) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const requestMapping = JSON.parse(requestMappingText || "{}");
      const payload = await invoke<ProviderModelsPayload>("fetch_provider_models", {
        providerDraft: { ...providerDraft, request_mapping: requestMapping },
        apiKey: form.apiKey.trim() || null,
      });
      setProviderResult(payload);
      if (payload.models.length > 0) {
        const models = Array.from(new Set([...providerDraft.models, ...payload.models]));
        updateProviderDraft({ models });
        update("model", models[0]);
        setNotice(t("modelsFetched"));
      }
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function testConnection() {
    if (!providerDraft) return;
    const model = form.model || providerDraft.models[0] || customModel.trim();
    if (!model) {
      setError("请先选择或添加一个模型。");
      return;
    }
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const requestMapping = JSON.parse(requestMappingText || "{}");
      const payload = await invoke<ProviderTestPayload>("test_provider_connection", {
        providerDraft: { ...providerDraft, request_mapping: requestMapping, models: providerDraft.models.includes(model) ? providerDraft.models : [model, ...providerDraft.models] },
        model,
        apiKey: form.apiKey.trim() || null,
      });
      setProviderResult(payload);
      if (payload.status === "PASS") setNotice(t("connectionPassed"));
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  function useProviderForTask() {
    if (!providerDraft) return;
    update("provider", providerDraft.name);
    update("model", form.model || providerDraft.models[0] || "");
    setNotice("已用于当前任务。");
  }

  function taskRequest() {
    return {
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
    };
  }

  async function startTask() {
    if (!form.input) {
      setError(t("chooseVideoFirst"));
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
          inputType: form.inputType,
          outputDir: form.outputDir || null,
          sourceLang: form.sourceLang,
          targetLang: form.targetLang,
          bilingual: form.bilingual,
          ...taskRequest(),
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
      setNotice(t("cancelRequested"));
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
          ...taskRequest(),
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
      setEvents(await invoke<WorkerEvent[]>("read_events", { taskId }));
      setActiveView("history");
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  async function openTaskResult(taskId: string) {
    setBusy(true);
    setError("");
    try {
      const payload = await invoke<TaskResultPayload>("open_task_result", { taskId });
      setTaskResult(payload);
      setSelectedSegmentId(payload.segments[0]?.id || null);
      setActiveView("result");
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  function updateResultSegment(id: number, patch: Partial<ResultSegment>) {
    setTaskResult((current) => {
      if (!current) return current;
      return {
        ...current,
        segments: current.segments.map((segment) => (segment.id === id ? { ...segment, ...patch } : segment)),
      };
    });
  }

  async function saveResultSegments() {
    if (!taskResult) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const payload = await invoke<TaskResultPayload>("save_task_segments", {
        taskId: taskResult.task.task_id,
        segments: taskResult.segments,
      });
      setTaskResult(payload);
      setNotice(t("resultSaved"));
      await refreshTasks();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function reexportResult() {
    if (!taskResult) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("reexport_task", { taskId: taskResult.task.task_id, outputFormat: form.outputFormat });
      setNotice(t("reexported"));
      const payload = await invoke<TaskResultPayload>("open_task_result", { taskId: taskResult.task.task_id });
      setTaskResult(payload);
      await refreshTasks();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  const latestDonePath = [...events].reverse().map(eventOutputPath).find(Boolean);

  return (
    <AppShell
      activeView={activeView}
      setActiveView={setActiveView}
      config={config}
      error={error}
      notice={notice}
      onRefresh={boot}
      sidebar={
        <Sidebar
          activeView={activeView}
          setActiveView={setActiveView}
          running={running}
          doctorStatus={doctorReport?.status}
          taskCount={tasks.length}
        />
      }
      aside={
        <RightRail
          running={running}
          progress={progress}
          latestDonePath={latestDonePath || ""}
          openPath={openPath}
          events={events}
          doctorReport={doctorReport}
          checks={importantChecks}
        />
      }
    >
      {activeView === "start" && (
        <TaskWorkspace
          form={form}
          update={update}
          busy={busy}
          running={running}
          advancedOpen={advancedOpen}
          setAdvancedOpen={setAdvancedOpen}
          chooseVideo={chooseVideo}
          chooseOutputDir={chooseOutputDir}
          startTask={startTask}
          cancelTask={cancelTask}
          probe={probe}
        />
      )}
      {activeView === "translation" && <TranslationPanel form={form} update={update} />}
      {activeView === "provider" && (
        <ConfigPanel
          form={form}
          update={update}
          config={config}
          selectedProvider={selectedProvider}
          selectedTemplate={selectedTemplate}
          providerTemplateId={providerTemplateId}
          providerDraft={providerDraft}
          requestMappingText={requestMappingText}
          setRequestMappingText={setRequestMappingText}
          providerAdvancedOpen={providerAdvancedOpen}
          setProviderAdvancedOpen={setProviderAdvancedOpen}
          providerResult={providerResult}
          customModel={customModel}
          setCustomModel={setCustomModel}
          updateProviderDraft={updateProviderDraft}
          updateProviderTemplate={updateProviderTemplate}
          newProviderDraft={newProviderDraft}
          saveProvider={saveProvider}
          deleteProvider={deleteProvider}
          fetchModels={fetchModels}
          testConnection={testConnection}
          useProviderForTask={useProviderForTask}
          addCustomModel={addCustomModel}
          routingDraft={routingDraft}
          setRoutingDraft={setRoutingDraft}
          saveRouting={saveRouting}
          probe={probe}
          busy={busy}
        />
      )}
      {activeView === "history" && (
        <HistoryPanel tasks={tasks} loadTaskEvents={loadTaskEvents} openTaskResult={openTaskResult} openPath={openPath} resumeTask={resumeTask} busy={busy} running={running} />
      )}
      {activeView === "result" && (
        <ResultPanel
          result={taskResult}
          selectedSegmentId={selectedSegmentId}
          setSelectedSegmentId={setSelectedSegmentId}
          updateSegment={updateResultSegment}
          saveResultSegments={saveResultSegments}
          reexportResult={reexportResult}
          busy={busy}
          outputFormat={form.outputFormat}
          updateOutputFormat={(value) => update("outputFormat", value)}
        />
      )}
      {activeView === "environment" && <EnvironmentPanel report={doctorReport} checks={importantChecks} refresh={refreshDoctor} />}
    </AppShell>
  );
}

function AppShell({
  activeView,
  setActiveView,
  config,
  error,
  notice,
  onRefresh,
  sidebar,
  aside,
  children,
}: {
  activeView: ActiveView;
  setActiveView: (view: ActiveView) => void;
  config: ConfigPayload | null;
  error: string;
  notice: string;
  onRefresh: () => void;
  sidebar: React.ReactNode;
  aside: React.ReactNode;
  children: React.ReactNode;
}) {
  const title = {
    start: t("start"),
    translation: t("translation"),
    provider: t("provider"),
    history: t("history"),
    result: t("result"),
    environment: t("environment"),
  }[activeView];
  return (
    <main className="grid min-h-screen grid-cols-[224px_minmax(0,1fr)_340px] bg-canvas text-ink">
      {sidebar}
      <section className="min-w-0 border-x border-line">
        <header className="sticky top-0 z-10 flex min-h-20 items-center justify-between border-b border-line bg-canvas/95 px-6 backdrop-blur">
          <div className="min-w-0">
            <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
            <p className="mt-1 truncate text-xs text-muted">{config?.root_dir || "正在读取工作区..."}</p>
          </div>
          <button className="tvx-btn" onClick={onRefresh} title={t("refresh")}>
            <RefreshCw size={17} /> {t("refresh")}
          </button>
        </header>
        <div className="space-y-4 p-6">
          {(error || notice) && (
            <div
              className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-sm ${
                error ? "border-red-200 bg-red-50 text-danger" : "border-emerald-200 bg-emerald-50 text-brand"
              }`}
            >
              {error ? <CircleAlert size={17} /> : <CheckCircle2 size={17} />}
              <span>{error || notice}</span>
            </div>
          )}
          {children}
        </div>
      </section>
      {aside}
    </main>
  );
}

function Sidebar({
  activeView,
  setActiveView,
  running,
  doctorStatus,
  taskCount,
}: {
  activeView: ActiveView;
  setActiveView: (view: ActiveView) => void;
  running: boolean;
  doctorStatus?: string;
  taskCount: number;
}) {
  const items: Array<{ key: ActiveView; label: string; icon: React.ElementType; badge?: string }> = [
    { key: "start", label: t("start"), icon: Play, badge: running ? "RUNNING" : undefined },
    { key: "translation", label: t("translation"), icon: Languages },
    { key: "provider", label: t("provider"), icon: Settings2 },
    { key: "history", label: t("history"), icon: History, badge: taskCount ? String(taskCount) : undefined },
    { key: "result", label: t("result"), icon: SearchCheck },
    { key: "environment", label: t("environment"), icon: MonitorCheck, badge: doctorStatus },
  ];
  return (
    <aside className="flex min-h-screen flex-col border-r border-line bg-white px-3 py-4">
      <div className="px-2 pb-5">
        <div className="text-lg font-semibold">TransVortex</div>
        <div className="mt-1 text-xs text-muted">{t("appSubtitle")}</div>
      </div>
      <nav className="grid gap-1">
        {items.map((item) => {
          const Icon = item.icon;
          const active = activeView === item.key;
          return (
            <button
              key={item.key}
              className={`flex min-h-11 items-center justify-between rounded-md px-3 text-left text-sm transition ${
                active ? "bg-emerald-50 text-brand" : "text-slate-700 hover:bg-slate-50"
              }`}
              onClick={() => setActiveView(item.key)}
            >
              <span className="flex items-center gap-2">
                <Icon size={17} />
                {item.label}
              </span>
              {item.badge && <span className={`text-[11px] font-semibold ${statusTone(item.badge)}`}>{item.badge}</span>}
            </button>
          );
        })}
      </nav>
      <div className="mt-auto rounded-lg bg-slate-50 p-3 text-xs leading-relaxed text-muted">
        V1 聚焦本地桌面工作流。CLI 保持为诊断和自动化入口。
      </div>
    </aside>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="tvx-panel p-4">
      <h2 className="mb-4 text-base font-semibold">{title}</h2>
      {children}
    </section>
  );
}

function TaskWorkspace({
  form,
  update,
  busy,
  running,
  advancedOpen,
  setAdvancedOpen,
  chooseVideo,
  chooseOutputDir,
  startTask,
  cancelTask,
  probe,
}: {
  form: FormState;
  update: <K extends keyof FormState>(key: K, value: FormState[K]) => void;
  busy: boolean;
  running: boolean;
  advancedOpen: boolean;
  setAdvancedOpen: (open: boolean) => void;
  chooseVideo: () => void;
  chooseOutputDir: () => void;
  startTask: () => void;
  cancelTask: () => void;
  probe: () => void;
}) {
  return (
    <div className="space-y-4">
      <Panel title="视频与语言">
        <div className="mb-4 grid grid-cols-[180px_minmax(0,1fr)] gap-4">
          <label className="tvx-label">
            {t("inputType")}
            <select className="tvx-input" value={form.inputType} onChange={(event) => update("inputType", event.target.value as FormState["inputType"])}>
              <option value="video">{t("videoInput")}</option>
              <option value="srt">{t("srtInput")}</option>
            </select>
          </label>
        </div>
        <section
          className="grid min-h-28 grid-cols-[44px_minmax(0,1fr)_auto] items-center gap-4 rounded-lg border border-dashed border-line bg-slate-50 p-4"
          onDragOver={(event) => event.preventDefault()}
          onDrop={(event) => {
            event.preventDefault();
            const file = event.dataTransfer.files.item(0) as DroppedFile | null;
            if (file) update("input", file.path || file.name);
          }}
        >
          <Video className="text-brand" size={34} />
          <div className="min-w-0">
            <strong className="block truncate text-sm">{form.input || (form.inputType === "srt" ? "拖入 SRT 字幕文件" : t("dropVideo"))}</strong>
            <span className="mt-1 block text-xs text-muted">{form.input ? t("videoReady") : form.inputType === "srt" ? "保留时间轴，跳过 ASR 直接翻译" : t("videoHint")}</span>
          </div>
          <button className="tvx-btn" onClick={chooseVideo}>
            <FolderOpen size={16} /> {t("choose")}
          </button>
        </section>
        <div className="mt-4 grid grid-cols-2 gap-4">
          <label className="tvx-label">
            {t("sourceLang")}
            <LanguageSelect value={form.sourceLang} onChange={(value) => update("sourceLang", value)} />
          </label>
          <label className="tvx-label">
            {t("targetLang")}
            <LanguageSelect value={form.targetLang} onChange={(value) => update("targetLang", value)} />
          </label>
        </div>
      </Panel>

      <Panel title="输出">
        <div className="grid grid-cols-[160px_minmax(0,1fr)] gap-4">
          <label className="tvx-label">
            {t("outputFormat")}
            <select className="tvx-input" value={form.outputFormat} onChange={(event) => update("outputFormat", event.target.value as FormState["outputFormat"])}>
              <option value="srt">srt</option>
              <option value="ass">ass</option>
              <option value="both">both</option>
            </select>
          </label>
          <label className="tvx-label">
            {t("outputDir")}
            <div className="grid grid-cols-[minmax(0,1fr)_44px] gap-2">
              <input className="tvx-input" value={form.outputDir} onChange={(event) => update("outputDir", event.target.value)} />
              <button className="tvx-btn px-0" onClick={chooseOutputDir}>
                <FolderOpen size={16} />
              </button>
            </div>
          </label>
        </div>
        <label className="mt-4 inline-flex items-center gap-2 text-sm text-ink">
          <input className="h-4 w-4" type="checkbox" checked={form.bilingual} onChange={(event) => update("bilingual", event.target.checked)} />
          {t("bilingual")}
        </label>
      </Panel>

      <Panel title={t("advanced")}>
        <button className="tvx-btn mb-4" onClick={() => setAdvancedOpen(!advancedOpen)}>
          {advancedOpen ? "收起高级设置" : "展开高级设置"}
        </button>
        {advancedOpen && (
          <div className="grid grid-cols-4 gap-4">
            <label className="tvx-label">
              {t("chunkSec")}
              <input className="tvx-input" type="number" value={form.chunkSeconds} onChange={(event) => update("chunkSeconds", Number(event.target.value))} />
            </label>
            <label className="tvx-label">
              {t("overlapSec")}
              <input className="tvx-input" type="number" value={form.chunkOverlapSeconds} onChange={(event) => update("chunkOverlapSeconds", Number(event.target.value))} />
            </label>
            <label className="tvx-label">
              {t("concurrency")}
              <input className="tvx-input" type="number" value={form.concurrency} onChange={(event) => update("concurrency", Number(event.target.value))} />
            </label>
          </div>
        )}
      </Panel>

      <div className="flex items-center justify-between rounded-lg border border-line bg-white p-4">
        <button className="tvx-btn" onClick={probe} disabled={busy}>
          <ClipboardList size={17} /> {t("preflight")}
        </button>
        {running ? (
          <button className="tvx-btn tvx-btn-danger" onClick={cancelTask} disabled={busy}>
            <Square size={17} /> {t("cancel")}
          </button>
        ) : (
          <button className="tvx-btn tvx-btn-primary min-w-32" onClick={startTask} disabled={busy}>
            {busy ? <Loader2 className="animate-spin" size={17} /> : <Play size={17} />} {t("startRun")}
          </button>
        )}
      </div>
    </div>
  );
}

function LanguageSelect({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const known = languageOptions.some((item) => item.code === value);
  return (
    <div className="grid grid-cols-[minmax(0,1fr)_120px] gap-2">
      <select className="tvx-input" value={known ? value : "custom"} onChange={(event) => event.target.value !== "custom" && onChange(event.target.value)}>
        {languageOptions.map((item) => (
          <option key={item.code} value={item.code}>
            {item.label} ({item.code})
          </option>
        ))}
        <option value="custom">自定义</option>
      </select>
      <input className="tvx-input" value={value} onChange={(event) => onChange(event.target.value)} />
    </div>
  );
}

function TranslationPanel({
  form,
  update,
}: {
  form: FormState;
  update: <K extends keyof FormState>(key: K, value: FormState[K]) => void;
}) {
  function applyContextPreset(value: string) {
    if (value === "compact") {
      update("translationChunkLines", 24);
      update("translationBatchSize", 24);
      update("translationContextBeforeLines", 8);
      update("translationContextAfterLines", 4);
    } else if (value === "balanced") {
      update("translationChunkLines", 40);
      update("translationBatchSize", 40);
      update("translationContextBeforeLines", 20);
      update("translationContextAfterLines", 10);
    } else if (value === "wide") {
      update("translationChunkLines", 60);
      update("translationBatchSize", 60);
      update("translationContextBeforeLines", 40);
      update("translationContextAfterLines", 20);
    }
  }

  return (
    <Panel title="LLM 翻译控制">
      <div className="grid grid-cols-4 gap-4">
        <label className="tvx-label">
          {t("preset")}
          <select className="tvx-input" value={form.translationStylePreset} onChange={(event) => update("translationStylePreset", event.target.value)}>
            <option value="subtitle_natural">subtitle_natural</option>
            <option value="literal">literal</option>
            <option value="localized">localized</option>
            <option value="learning_friendly">learning_friendly</option>
          </select>
        </label>
        <label className="tvx-label">
          上下文预设
          <select className="tvx-input" defaultValue="custom" onChange={(event) => applyContextPreset(event.target.value)}>
            <option value="custom">自定义</option>
            <option value="compact">紧凑</option>
            <option value="balanced">均衡</option>
            <option value="wide">宽上下文</option>
          </select>
        </label>
        <label className="tvx-label">
          {t("chunkLines")}
          <input
            className="tvx-input"
            type="number"
            value={form.translationChunkLines}
            onChange={(event) => {
              update("translationChunkLines", Number(event.target.value));
              update("translationBatchSize", Number(event.target.value));
            }}
          />
        </label>
      </div>
      <div className="mt-4 grid grid-cols-4 gap-4">
        <label className="tvx-label">
          {t("contextBefore")}
          <input className="tvx-input" type="number" value={form.translationContextBeforeLines} onChange={(event) => update("translationContextBeforeLines", Number(event.target.value))} />
        </label>
        <label className="tvx-label">
          {t("contextAfter")}
          <input className="tvx-input" type="number" value={form.translationContextAfterLines} onChange={(event) => update("translationContextAfterLines", Number(event.target.value))} />
        </label>
      </div>
      <label className="tvx-label mt-4">
        {t("stylePrompt")}
        <textarea className="tvx-textarea" value={form.translationStylePrompt} onChange={(event) => update("translationStylePrompt", event.target.value)} />
      </label>
      <label className="mt-4 inline-flex items-center gap-2 text-sm">
        <input className="h-4 w-4" type="checkbox" checked={form.translationRepairEnabled} onChange={(event) => update("translationRepairEnabled", event.target.checked)} />
        {t("repairRows")}
      </label>
    </Panel>
  );
}

function ConfigPanel({
  form,
  update,
  config,
  selectedProvider,
  selectedTemplate,
  providerTemplateId,
  providerDraft,
  requestMappingText,
  setRequestMappingText,
  providerAdvancedOpen,
  setProviderAdvancedOpen,
  providerResult,
  customModel,
  setCustomModel,
  updateProviderDraft,
  updateProviderTemplate,
  newProviderDraft,
  saveProvider,
  deleteProvider,
  fetchModels,
  testConnection,
  useProviderForTask,
  addCustomModel,
  routingDraft,
  setRoutingDraft,
  saveRouting,
  probe,
  busy,
}: {
  form: FormState;
  update: <K extends keyof FormState>(key: K, value: FormState[K]) => void;
  config: ConfigPayload | null;
  selectedProvider?: ProviderConfig;
  selectedTemplate?: ProviderTemplate;
  providerTemplateId: string;
  providerDraft: ProviderDraft | null;
  requestMappingText: string;
  setRequestMappingText: (value: string) => void;
  providerAdvancedOpen: boolean;
  setProviderAdvancedOpen: (open: boolean) => void;
  providerResult: ProviderDiagnostic | ProviderTestPayload | null;
  customModel: string;
  setCustomModel: (value: string) => void;
  updateProviderDraft: (patch: Partial<ProviderDraft>) => void;
  updateProviderTemplate: (compatMode: string) => void;
  newProviderDraft: () => void;
  saveProvider: () => void;
  deleteProvider: () => void;
  fetchModels: () => void;
  testConnection: () => void;
  useProviderForTask: () => void;
  addCustomModel: () => void;
  routingDraft: { primary: RouteTarget; fallback: RouteTarget[] };
  setRoutingDraft: React.Dispatch<React.SetStateAction<{ primary: RouteTarget; fallback: RouteTarget[] }>>;
  saveRouting: () => void;
  probe: () => void;
  busy: boolean;
}) {
  const responsePaths = providerDraft?.response_mapping.text_paths.join("\n") || "";
  const modelListPaths = providerDraft?.model_list.response_paths.join("\n") || "";
  const requestMapping = parseJsonObject(requestMappingText);
  const reasoningEffort = String(getPathValue(requestMapping || {}, requestBodyPath("reasoning_effort")) ?? "");
  const knownReasoningEffort = ["", "none", "low", "medium", "high", "xhigh", "minimal", "max"].includes(reasoningEffort);
  const topP = String(getPathValue(requestMapping || {}, requestBodyPath("top_p")) ?? "");
  const tokenLimitField = tokenLimitFieldForMapping(requestMapping);
  const tokenLimitValue = tokenLimitValueForMapping(requestMapping);
  const geminiThinkingBudget = String(getPathValue(requestMapping || {}, requestBodyPath("extra_body.google.thinking_config.thinking_budget")) ?? getPathValue(requestMapping || {}, requestBodyPath("thinkingConfig.thinkingBudget")) ?? "");
  const requestMappingInvalid = requestMappingText.trim().length > 0 && !requestMapping;
  return (
    <div className="space-y-4">
      <Panel title="Provider 配置中心">
        <div className="grid grid-cols-[220px_minmax(0,1fr)] gap-4">
          <aside className="space-y-2">
            <button className="tvx-btn w-full justify-start" onClick={newProviderDraft} disabled={busy}>
              <Plus size={16} /> {t("newProvider")}
            </button>
            <div className="grid max-h-[360px] gap-2 overflow-auto pr-1">
              {config?.providers.map((provider) => (
                <button
                  key={provider.name}
                  className={`rounded-lg border p-3 text-left text-sm transition ${
                    provider.name === form.provider ? "border-brand bg-emerald-50" : "border-line bg-white hover:bg-slate-50"
                  }`}
                  onClick={() => {
                    update("provider", provider.name);
                    update("model", provider.models[0] || "");
                  }}
                >
                  <span className="block truncate font-semibold">{provider.name}</span>
                  <span className="mt-1 block truncate text-xs text-muted">{provider.compat_mode}</span>
                  <span className={`mt-2 block text-[11px] font-semibold ${provider.has_key ? "text-brand" : "text-warning"}`}>
                    {provider.has_key ? t("configured") : t("missing")}
                  </span>
                </button>
              ))}
            </div>
          </aside>

          <section className="space-y-4">
            {!providerDraft && <p className="rounded-lg bg-slate-50 p-3 text-sm text-muted">请选择或新建一个 provider。</p>}
            {providerDraft && (
              <>
                <div className="grid grid-cols-2 gap-4">
                  <label className="tvx-label">
                    {t("providerName")}
                    <input
                      className="tvx-input"
                      value={providerDraft.name}
                      onChange={(event) => {
                        const name = event.target.value;
                        updateProviderDraft({ name, env_key: providerDraft.env_key || envKeyForName(name) });
                      }}
                    />
                  </label>
                  <label className="tvx-label">
                    {t("compatMode")}
                    <select className="tvx-input" value={providerTemplateId} onChange={(event) => updateProviderTemplate(event.target.value)}>
                      {config?.provider_templates.map((template) => (
                        <option key={template.id} value={template.id}>
                          {template.label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="tvx-label">
                    {t("baseUrl")}
                    <input className="tvx-input" value={providerDraft.base_url} onChange={(event) => updateProviderDraft({ base_url: event.target.value })} />
                  </label>
                  <label className="tvx-label">
                    {t("envKey")}
                    <input className="tvx-input" value={providerDraft.env_key} onChange={(event) => updateProviderDraft({ env_key: event.target.value })} />
                  </label>
                </div>

                <section className="grid grid-cols-[24px_minmax(120px,1fr)_minmax(180px,260px)_auto] items-center gap-3 rounded-lg border border-line p-3">
                  <KeyRound className="text-brand" size={18} />
                  <div>
                    <strong className="block text-sm">{providerDraft.env_key}</strong>
                    <span className="text-xs text-muted">{selectedProvider?.name === providerDraft.name && selectedProvider?.has_key ? t("configured") : "可保存新 key"}</span>
                  </div>
                  <input className="tvx-input" type="password" placeholder={t("pasteKey")} value={form.apiKey} onChange={(event) => update("apiKey", event.target.value)} />
                  <button className="tvx-btn" disabled={!form.apiKey || busy} onClick={saveProvider}>
                    {t("save")}
                  </button>
                </section>

                <div className="grid grid-cols-[minmax(0,1fr)_220px] gap-4">
                  <label className="tvx-label">
                    {t("model")}
                    <select className="tvx-input" value={form.model} onChange={(event) => update("model", event.target.value)}>
                      {providerDraft.models.map((model) => (
                        <option key={model} value={model}>
                          {model}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="tvx-label">
                    {t("customModel")}
                    <div className="grid grid-cols-[minmax(0,1fr)_44px] gap-2">
                      <input className="tvx-input" value={customModel} onChange={(event) => setCustomModel(event.target.value)} />
                      <button className="tvx-btn px-0" onClick={addCustomModel} title={t("addModel")}>
                        <Plus size={16} />
                      </button>
                    </div>
                  </label>
                </div>

                <div className="flex flex-wrap gap-2">
                  <button className="tvx-btn tvx-btn-primary" onClick={saveProvider} disabled={busy}>
                    <Save size={16} /> {t("saveProvider")}
                  </button>
                  <button className="tvx-btn" onClick={testConnection} disabled={busy}>
                    <Wifi size={16} /> {t("testConnection")}
                  </button>
                  <button className="tvx-btn" onClick={fetchModels} disabled={busy}>
                    <DownloadCloud size={16} /> {t("fetchModels")}
                  </button>
                  <button className="tvx-btn" onClick={useProviderForTask} disabled={busy}>
                    <Database size={16} /> {t("useForTask")}
                  </button>
                  <button className="tvx-btn" onClick={probe} disabled={busy}>
                    <ClipboardList size={16} /> {t("preflight")}
                  </button>
                  <button className="tvx-btn tvx-btn-danger" onClick={deleteProvider} disabled={busy || !selectedProvider}>
                    <Trash2 size={16} /> {t("deleteProvider")}
                  </button>
                </div>

                {providerResult && (
                  <div className={`rounded-lg border p-3 text-sm ${providerResult.status === "FAIL" ? "border-red-200 bg-red-50 text-danger" : providerResult.status === "WARN" ? "border-yellow-200 bg-yellow-50 text-warning" : "border-emerald-200 bg-emerald-50 text-brand"}`}>
                    <strong>{providerResult.status}</strong>
                    <p className="mt-1 text-ink">{diagnosticText(providerResult)}</p>
                  </div>
                )}

                <button className="tvx-btn" onClick={() => setProviderAdvancedOpen(!providerAdvancedOpen)}>
                  <SlidersHorizontal size={16} /> {providerAdvancedOpen ? "收起高级设置" : "展开高级设置"}
                </button>

                {providerAdvancedOpen && (
                  <div className="grid grid-cols-2 gap-4 rounded-lg border border-line bg-slate-50 p-3">
                    <section className="col-span-2 rounded-lg border border-line bg-white p-3">
                      <div className="mb-3 flex items-center justify-between">
                        <strong className="text-sm">常用请求参数</strong>
                        <span className="text-xs text-muted">默认不指定，只有选择/填写后才写入 request_mapping。</span>
                      </div>
                      <div className="grid grid-cols-4 gap-3">
                        <label className="tvx-label">
                          reasoning_effort
                          <select
                            className="tvx-input"
                            value={knownReasoningEffort ? reasoningEffort || "auto" : "custom"}
                            onChange={(event) =>
                              setRequestMappingText(
                                setRequestBodyOverride(
                                  requestMappingText,
                                  "reasoning_effort",
                                  event.target.value === "auto" ? "" : event.target.value,
                                ),
                              )
                            }
                          >
                            <option value="auto">auto / 不指定</option>
                            <option value="none">none</option>
                            <option value="low">low</option>
                            <option value="medium">medium</option>
                            <option value="high">high</option>
                            <option value="xhigh">xhigh</option>
                            <option value="minimal">minimal</option>
                            <option value="max">max</option>
                            <option value="custom">自定义</option>
                          </select>
                        </label>
                        <label className="tvx-label">
                          reasoning 自定义
                          <input
                            className="tvx-input"
                            value={knownReasoningEffort ? "" : reasoningEffort}
                            placeholder="例如 vendor-specific"
                            onChange={(event) =>
                              setRequestMappingText(setRequestBodyOverride(requestMappingText, "reasoning_effort", event.target.value))
                            }
                          />
                        </label>
                        <label className="tvx-label">
                          top_p
                          <input
                            className="tvx-input"
                            type="number"
                            step="0.05"
                            min="0"
                            max="1"
                            value={topP}
                            placeholder="auto"
                            onChange={(event) =>
                              setRequestMappingText(
                                setRequestBodyOverride(
                                  requestMappingText,
                                  "top_p",
                                  event.target.value === "" ? "" : Number(event.target.value),
                                ),
                              )
                            }
                          />
                        </label>
                        <label className="tvx-label">
                          token 字段
                          <select
                            className="tvx-input"
                            value={tokenLimitField}
                            onChange={(event) => setRequestMappingText(setTokenLimit(requestMappingText, event.target.value, tokenLimitValue))}
                          >
                            {tokenLimitFields.map((field) => (
                              <option key={field.value} value={field.value}>
                                {field.label}
                              </option>
                            ))}
                          </select>
                        </label>
                        <label className="tvx-label">
                          token 上限
                          <input
                            className="tvx-input"
                            type="number"
                            value={tokenLimitValue}
                            placeholder="auto"
                            onChange={(event) => setRequestMappingText(setTokenLimit(requestMappingText, tokenLimitField, event.target.value))}
                          />
                        </label>
                        <label className="tvx-label">
                          Gemini thinking budget
                          <input
                            className="tvx-input"
                            type="number"
                            value={geminiThinkingBudget}
                            placeholder="auto"
                            onChange={(event) => {
                              const value = event.target.value === "" ? "" : Number(event.target.value);
                              const path =
                                providerDraft.compat_mode === "openai_chat"
                                  ? "extra_body.google.thinking_config.thinking_budget"
                                  : "thinkingConfig.thinkingBudget";
                              setRequestMappingText(setRequestBodyOverride(requestMappingText, path, value));
                            }}
                          />
                        </label>
                      </div>
                    </section>
                    <label className="tvx-label">
                      api_type
                      <input className="tvx-input" value={providerDraft.api_type} onChange={(event) => updateProviderDraft({ api_type: event.target.value })} />
                    </label>
                    <label className="tvx-label">
                      {t("authType")}
                      <select
                        className="tvx-input"
                        value={providerDraft.auth.type}
                        onChange={(event) => updateProviderDraft({ auth: { ...providerDraft.auth, type: event.target.value } })}
                      >
                        <option value="bearer">bearer</option>
                        <option value="header">header</option>
                        <option value="query">query</option>
                      </select>
                    </label>
                    <label className="tvx-label">
                      {t("endpointPath")}
                      <input
                        className="tvx-input"
                        value={providerDraft.endpoint.path_template}
                        onChange={(event) => updateProviderDraft({ endpoint: { ...providerDraft.endpoint, path_template: event.target.value } })}
                      />
                    </label>
                    <label className="tvx-label">
                      {t("modelListPath")}
                      <input
                        className="tvx-input"
                        value={providerDraft.model_list.path_template}
                        onChange={(event) => updateProviderDraft({ model_list: { ...providerDraft.model_list, path_template: event.target.value } })}
                      />
                    </label>
                    <label className="tvx-label">
                      header_name / query_name
                      <input
                        className="tvx-input"
                        value={providerDraft.auth.type === "query" ? providerDraft.auth.query_name || "" : providerDraft.auth.header_name || ""}
                        onChange={(event) =>
                          updateProviderDraft({
                            auth:
                              providerDraft.auth.type === "query"
                                ? { ...providerDraft.auth, query_name: event.target.value }
                                : { ...providerDraft.auth, header_name: event.target.value },
                          })
                        }
                      />
                    </label>
                    <label className="tvx-label">
                      auth prefix
                      <input className="tvx-input" value={providerDraft.auth.prefix || ""} onChange={(event) => updateProviderDraft({ auth: { ...providerDraft.auth, prefix: event.target.value } })} />
                    </label>
                    <label className="tvx-label">
                      {t("responsePaths")}
                      <textarea
                        className="tvx-textarea min-h-24"
                        value={responsePaths}
                        onChange={(event) => updateProviderDraft({ response_mapping: { text_paths: arrayValue(event.target.value.split(/\r?\n/)) } })}
                      />
                    </label>
                    <label className="tvx-label">
                      request_mapping JSON
                      <textarea
                        className={`tvx-textarea min-h-44 font-mono text-xs ${requestMappingInvalid ? "border-red-300" : ""}`}
                        value={requestMappingText}
                        onChange={(event) => setRequestMappingText(event.target.value)}
                      />
                      {requestMappingInvalid && <span className="text-xs text-danger">JSON 格式无效，保存/测试前需要修正。</span>}
                    </label>
                    <label className="tvx-label">
                      model list response paths
                      <textarea
                        className="tvx-textarea min-h-24"
                        value={modelListPaths}
                        onChange={(event) =>
                          updateProviderDraft({
                            model_list: { ...providerDraft.model_list, response_paths: arrayValue(event.target.value.split(/\r?\n/)) },
                          })
                        }
                      />
                    </label>
                    <p className="col-span-2 text-xs text-muted">
                      当前模板：{selectedTemplate?.label || providerDraft.compat_mode}。高级字段用于兼容非标准网关，普通 OpenAI-compatible 只需要 base_url、key 和模型。
                    </p>
                  </div>
                )}
              </>
            )}
          </section>
        </div>
      </Panel>

      <Panel title={t("routing")}>
        <div className="grid grid-cols-2 gap-4">
          <RouteEditor
            label="Primary"
            route={routingDraft.primary}
            providers={config?.providers || []}
            onChange={(route) => setRoutingDraft((current) => ({ ...current, primary: route }))}
          />
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-muted">Fallback</span>
              <button
                className="tvx-btn min-h-8 px-2"
                onClick={() => setRoutingDraft((current) => ({ ...current, fallback: [...current.fallback, { provider: "", model: "" }] }))}
              >
                <Plus size={14} /> 添加
              </button>
            </div>
            {routingDraft.fallback.map((route, index) => (
              <div key={index} className="grid grid-cols-[minmax(0,1fr)_36px] gap-2">
                <RouteEditor
                  label={`Fallback ${index + 1}`}
                  route={route}
                  providers={config?.providers || []}
                  onChange={(next) =>
                    setRoutingDraft((current) => ({
                      ...current,
                      fallback: current.fallback.map((item, itemIndex) => (itemIndex === index ? next : item)),
                    }))
                  }
                />
                <button
                  className="tvx-btn tvx-btn-danger mt-5 px-0"
                  onClick={() => setRoutingDraft((current) => ({ ...current, fallback: current.fallback.filter((_, itemIndex) => itemIndex !== index) }))}
                >
                  <Trash2 size={14} />
                </button>
              </div>
            ))}
            <button className="tvx-btn tvx-btn-primary" onClick={saveRouting} disabled={busy}>
              <Save size={16} /> 保存路由
            </button>
          </div>
        </div>
      </Panel>

      <Panel title="ASR">
        <div className="grid grid-cols-4 gap-4">
          <label className="tvx-label">
            {t("asrMode")}
            <select className="tvx-input" value={form.asrMode} onChange={(event) => update("asrMode", event.target.value)}>
              <option value="local">local</option>
              <option value="openai">openai</option>
            </select>
          </label>
          <label className="tvx-label">
            {t("device")}
            <select className="tvx-input" value={form.asrDevice} onChange={(event) => update("asrDevice", event.target.value)}>
              <option value="cpu">cpu</option>
              <option value="auto">auto</option>
              <option value="cuda">cuda</option>
            </select>
          </label>
          <label className="tvx-label">
            {t("modelSize")}
            <input className="tvx-input" value={form.asrModelSize} onChange={(event) => update("asrModelSize", event.target.value)} />
          </label>
          <label className="tvx-label">
            {t("compute")}
            <input className="tvx-input" value={form.asrComputeType} onChange={(event) => update("asrComputeType", event.target.value)} />
          </label>
        </div>
      </Panel>
    </div>
  );
}

function RouteEditor({
  label,
  route,
  providers,
  onChange,
}: {
  label: string;
  route: RouteTarget;
  providers: ProviderConfig[];
  onChange: (route: RouteTarget) => void;
}) {
  const provider = providers.find((item) => item.name === route.provider) || providers[0];
  const models = provider?.models || [];
  return (
    <div className="grid grid-cols-2 gap-2">
      <label className="tvx-label">
        {label} provider
        <select
          className="tvx-input"
          value={route.provider || provider?.name || ""}
          onChange={(event) => {
            const nextProvider = providers.find((item) => item.name === event.target.value);
            onChange({ provider: event.target.value, model: nextProvider?.models[0] || "" });
          }}
        >
          {providers.map((item) => (
            <option key={item.name} value={item.name}>
              {item.name}
            </option>
          ))}
        </select>
      </label>
      <label className="tvx-label">
        model
        <select className="tvx-input" value={route.model || models[0] || ""} onChange={(event) => onChange({ ...route, model: event.target.value })}>
          {models.map((model) => (
            <option key={model} value={model}>
              {model}
            </option>
          ))}
        </select>
      </label>
    </div>
  );
}

function RightRail({
  running,
  progress,
  latestDonePath,
  openPath,
  events,
  doctorReport,
  checks,
}: {
  running: boolean;
  progress: number;
  latestDonePath: string;
  openPath: (path?: string | null) => void;
  events: WorkerEvent[];
  doctorReport: DoctorPayload | null;
  checks: DoctorCheck[];
}) {
  return (
    <aside className="space-y-4 bg-canvas p-4">
      <section className="tvx-panel p-4">
        <div className="flex items-center justify-between">
          <span className="text-sm font-medium">{running ? t("running") : t("progress")}</span>
          <strong className="text-lg">{progress}%</strong>
        </div>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-slate-200">
          <div className="h-full rounded-full bg-brand transition-all" style={{ width: `${progress}%` }} />
        </div>
        {latestDonePath && (
          <button className="tvx-btn mt-3 w-full" onClick={() => openPath(latestDonePath)}>
            <FolderOpen size={16} /> {t("openOutput")}
          </button>
        )}
      </section>
      <section className="tvx-panel p-4">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-base font-semibold">{t("environmentSummary")}</h2>
          <strong className={`text-xs ${statusTone(doctorReport?.status || "")}`}>{doctorReport?.status || "UNKNOWN"}</strong>
        </div>
        <div className="grid gap-2">
          {checks.map((check) => (
            <article key={check.name} className="rounded-md border border-line bg-slate-50 p-2">
              <div className="flex items-center justify-between gap-3">
                <span className="truncate text-xs font-semibold">{check.name}</span>
                <strong className={`text-[11px] ${statusTone(check.status)}`}>{check.status}</strong>
              </div>
              <p className="mt-1 text-xs leading-relaxed text-muted">{check.hint_zh || check.message}</p>
            </article>
          ))}
        </div>
      </section>
      <EventPanel events={events} />
    </aside>
  );
}

function EventPanel({ events }: { events: WorkerEvent[] }) {
  return (
    <section className="tvx-panel p-4">
      <h2 className="mb-3 text-base font-semibold">{t("latestEvents")}</h2>
      {events.length === 0 && <p className="text-sm text-muted">{t("noEvents")}</p>}
      <div className="grid max-h-[320px] gap-2 overflow-auto pr-1">
        {[...events].reverse().slice(0, 14).map((event, index) => (
          <article key={`${event.created_at}-${index}`} className="border-t border-line py-2">
            <span className={`text-xs font-semibold ${event.level === "error" ? "text-danger" : "text-muted"}`}>{event.stage || event.type}</span>
            <p className="mt-1 text-xs leading-relaxed text-ink">{event.message || event.type}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function HistoryPanel({
  tasks,
  loadTaskEvents,
  openTaskResult,
  openPath,
  resumeTask,
  busy,
  running,
}: {
  tasks: TaskRecord[];
  loadTaskEvents: (taskId: string) => void;
  openTaskResult: (taskId: string) => void;
  openPath: (path?: string | null) => void;
  resumeTask: (taskId: string) => void;
  busy: boolean;
  running: boolean;
}) {
  return (
    <Panel title={t("history")}>
      {tasks.length === 0 && <p className="text-sm text-muted">{t("noTasks")}</p>}
      <div className="grid gap-3">
        {tasks.map((task) => (
          <article key={task.task_id} className="rounded-lg border border-line p-3">
            <div className="flex items-center justify-between gap-3">
              <strong className="truncate text-sm">{task.task_id}</strong>
              <span className={`text-xs font-semibold ${statusTone(task.status)}`}>{task.status}</span>
            </div>
            <p className="mt-2 truncate text-xs text-muted">{task.input_file}</p>
            {task.error && <p className="mt-2 text-xs text-danger">{task.error}</p>}
            <footer className="mt-3 flex flex-wrap gap-2">
              <button className="tvx-btn" onClick={() => openTaskResult(task.task_id)}>
                {t("inspect")}
              </button>
              <button className="tvx-btn" onClick={() => loadTaskEvents(task.task_id)}>
                {t("events")}
              </button>
              <button className="tvx-btn" onClick={() => openPath(task.task_dir)}>
                {t("folder")}
              </button>
              {outputPath(task, "srt") && <button className="tvx-btn" onClick={() => openPath(outputPath(task, "srt"))}>SRT</button>}
              {outputPath(task, "ass") && <button className="tvx-btn" onClick={() => openPath(outputPath(task, "ass"))}>ASS</button>}
              {!outputPath(task, "srt") && !outputPath(task, "ass") && task.output_path && (
                <button className="tvx-btn" onClick={() => openPath(task.output_path)}>
                  {t("openOutput")}
                </button>
              )}
              {["FAILED", "CANCELLED", "CANCEL_REQUESTED"].includes(task.status) && (
                <button className="tvx-btn" disabled={running || busy} onClick={() => resumeTask(task.task_id)}>
                  {t("resume")}
                </button>
              )}
            </footer>
          </article>
        ))}
      </div>
    </Panel>
  );
}

function ResultPanel({
  result,
  selectedSegmentId,
  setSelectedSegmentId,
  updateSegment,
  saveResultSegments,
  reexportResult,
  busy,
  outputFormat,
  updateOutputFormat,
}: {
  result: TaskResultPayload | null;
  selectedSegmentId: number | null;
  setSelectedSegmentId: (id: number) => void;
  updateSegment: (id: number, patch: Partial<ResultSegment>) => void;
  saveResultSegments: () => void;
  reexportResult: () => void;
  busy: boolean;
  outputFormat: FormState["outputFormat"];
  updateOutputFormat: (value: FormState["outputFormat"]) => void;
}) {
  if (!result) {
    return (
      <Panel title={t("result")}>
        <p className="text-sm text-muted">从任务历史中选择一个任务进行检查。</p>
      </Panel>
    );
  }
  const maxEnd = Math.max(...result.segments.map((segment) => segment.end), 1);
  const sortedSegments = [...result.segments].sort((a, b) => a.start - b.start || a.end - b.end || a.id - b.id);
  const gapById = new Map<number, number>();
  sortedSegments.forEach((segment, index) => {
    const previous = sortedSegments[index - 1];
    gapById.set(segment.id, previous ? segment.start - previous.end : segment.start);
  });
  return (
    <div className="space-y-4">
      <Panel title={t("timeline")}>
        <div className="mb-3 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <strong className="block truncate text-sm">{result.task.task_id}</strong>
            <span className="text-xs text-muted">{result.task.input_file}</span>
          </div>
          <div className="flex items-center gap-2">
            <select className="tvx-input w-28" value={outputFormat} onChange={(event) => updateOutputFormat(event.target.value as FormState["outputFormat"])}>
              <option value="srt">srt</option>
              <option value="ass">ass</option>
              <option value="both">both</option>
            </select>
            <button className="tvx-btn" disabled={busy} onClick={saveResultSegments}>
              <Save size={16} /> {t("saveEdits")}
            </button>
            <button className="tvx-btn tvx-btn-primary" disabled={busy} onClick={reexportResult}>
              <DownloadCloud size={16} /> {t("reexport")}
            </button>
          </div>
        </div>
        <div className="relative h-24 overflow-hidden rounded-lg border border-line bg-slate-50">
          {sortedSegments.map((segment) => {
            const left = `${(segment.start / maxEnd) * 100}%`;
            const width = `${Math.max(((segment.end - segment.start) / maxEnd) * 100, 0.6)}%`;
            const active = segment.id === selectedSegmentId;
            const duration = Math.max(segment.end - segment.start, 0);
            const gap = gapById.get(segment.id) || 0;
            return (
              <button
                key={segment.id}
                className={`absolute top-4 h-12 overflow-hidden rounded-sm border px-1 text-left text-[10px] leading-tight ${active ? "border-brand bg-emerald-100" : segment.issues?.length ? "border-yellow-300 bg-yellow-100" : "border-emerald-200 bg-white"}`}
                style={{ left, width }}
                onClick={() => setSelectedSegmentId(segment.id)}
                title={`${segment.id} ${formatClock(segment.start)} - ${formatClock(segment.end)} / ${duration.toFixed(1)}s / gap ${gap.toFixed(1)}s`}
              >
                <span className="block truncate">{segment.id}</span>
                <span className="block truncate">{duration.toFixed(1)}s</span>
              </button>
            );
          })}
        </div>
      </Panel>
      <Panel title="字幕行">
        <div className="max-h-[560px] overflow-auto">
          <table className="w-full border-collapse text-sm">
            <thead className="sticky top-0 bg-white text-xs text-muted">
              <tr>
                <th className="border-b border-line p-2 text-left">#</th>
                <th className="border-b border-line p-2 text-left">开始</th>
                <th className="border-b border-line p-2 text-left">结束</th>
                <th className="border-b border-line p-2 text-left">时长/间隔</th>
                <th className="border-b border-line p-2 text-left">原文</th>
                <th className="border-b border-line p-2 text-left">译文</th>
                <th className="border-b border-line p-2 text-left">模型</th>
                <th className="border-b border-line p-2 text-left">问题</th>
              </tr>
            </thead>
            <tbody>
              {sortedSegments.map((segment) => (
                <tr key={segment.id} className={segment.id === selectedSegmentId ? "bg-emerald-50" : ""} onClick={() => setSelectedSegmentId(segment.id)}>
                  <td className="border-b border-line p-2 align-top text-xs font-semibold">{segment.id}</td>
                  <td className="border-b border-line p-2 align-top">
                    <input className="tvx-input min-h-8 w-28 px-2 text-xs" value={formatClock(segment.start)} onChange={(event) => updateSegment(segment.id, { start: parseClock(event.target.value) })} />
                  </td>
                  <td className="border-b border-line p-2 align-top">
                    <input className="tvx-input min-h-8 w-28 px-2 text-xs" value={formatClock(segment.end)} onChange={(event) => updateSegment(segment.id, { end: parseClock(event.target.value) })} />
                  </td>
                  <td className="border-b border-line p-2 align-top text-xs text-muted">
                    <div>{Math.max(segment.end - segment.start, 0).toFixed(2)}s</div>
                    <div className={gapById.get(segment.id)! < 0 ? "mt-1 text-warning" : "mt-1"}>gap {Number(gapById.get(segment.id) || 0).toFixed(2)}s</div>
                  </td>
                  <td className="border-b border-line p-2 align-top">
                    <textarea className="tvx-textarea min-h-20" value={segment.text_src} onChange={(event) => updateSegment(segment.id, { text_src: event.target.value })} />
                  </td>
                  <td className="border-b border-line p-2 align-top">
                    <textarea className="tvx-textarea min-h-20" value={segment.text_tgt || ""} onChange={(event) => updateSegment(segment.id, { text_tgt: event.target.value })} />
                  </td>
                  <td className="border-b border-line p-2 align-top text-xs text-muted">
                    <div>{segment.provider || "-"}</div>
                    <div className="mt-1">{segment.model || "-"}</div>
                  </td>
                  <td className="border-b border-line p-2 align-top text-xs text-warning">{segment.issues?.join("；")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>
    </div>
  );
}

function EnvironmentPanel({
  report,
  checks,
  refresh,
}: {
  report: DoctorPayload | null;
  checks: DoctorCheck[];
  refresh: () => void;
}) {
  return (
    <Panel title={t("environment")}>
      <div className="mb-4 flex items-center justify-between rounded-lg bg-slate-50 p-3">
        <div>
          <div className="text-sm font-semibold">Doctor</div>
          <div className="text-xs text-muted">{report?.providers_file || "未读取 provider 文件"}</div>
        </div>
        <div className="flex items-center gap-3">
          <strong className={`text-sm ${statusTone(report?.status || "")}`}>{report?.status || "UNKNOWN"}</strong>
          <button className="tvx-btn" onClick={refresh}>
            <RefreshCw size={16} /> {t("refresh")}
          </button>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        {checks.map((check) => (
          <article key={check.name} className="rounded-lg border border-line p-3">
            <div className="flex items-center justify-between gap-3">
              <strong className="text-sm">{check.name}</strong>
              <span className={`text-xs font-semibold ${statusTone(check.status)}`}>{check.status}</span>
            </div>
            <p className="mt-2 text-sm leading-relaxed text-muted">{check.hint_zh || check.message}</p>
            <p className="mt-2 text-xs text-slate-400">{check.code}</p>
          </article>
        ))}
      </div>
    </Panel>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
