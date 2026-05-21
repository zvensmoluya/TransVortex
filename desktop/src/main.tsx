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
  FileText,
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
import { t } from "./i18n";
import {
  getPathValue,
  parseJsonObject,
  requestBodyPath,
  setRequestBodyOverride,
  setTokenLimit,
  tokenLimitFieldForMapping,
  tokenLimitFields,
  tokenLimitValueForMapping,
} from "./jsonMapping";
import {
  arrayValue,
  defaultTemplate,
  diagnosticHint,
  diagnosticText,
  envKeyForName,
  fieldTranslation,
  nextRouteProfileIdFromSeq,
  nextRouteProfileName,
  normalizeRoutingProfiles,
  numberValue,
  objectValue,
  protocolTemplates,
  providerToDraft,
  templateToDraft,
  textValue,
  validateRoutingProfileDrafts,
} from "./providerConfig";
import type {
  ActiveView,
  ConfigPayload,
  DoctorCheck,
  DoctorPayload,
  DroppedFile,
  FormState,
  AsrPromptProfile,
  ProviderConfig,
  ProviderDiagnostic,
  ProviderDraft,
  ProviderModelsPayload,
  ProviderTemplate,
  ProviderTestPayload,
  ResultSegment,
  RouteTarget,
  RoutingProfile,
  SubtitleStream,
  TaskRecord,
  TaskResultPayload,
  WorkerEvent,
} from "./types";
import { emptyForm, languageOptions } from "./types";
import "./styles.css";

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

function memoryPresetRefs(value: string) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function memoryPresetString(value: unknown) {
  if (!Array.isArray(value)) return "";
  return value
    .map((item) => {
      if (typeof item === "string") return item;
      if (!item || typeof item !== "object") return "";
      const row = item as { id?: unknown; override_status?: unknown };
      const id = typeof row.id === "string" ? row.id.trim() : "";
      const status = typeof row.override_status === "string" ? row.override_status.trim() : "";
      return id && status ? `${id}:${status}` : id;
    })
    .filter(Boolean)
    .join(", ");
}

function buildTranslationStylePrompt(projectPrompt: string, stylePrompt: string) {
  const project = projectPrompt.trim();
  const style = stylePrompt.trim();
  if (project && style) return `Project context:\n${project}\n\nStyle instructions:\n${style}`;
  if (project) return `Project context:\n${project}`;
  return style;
}

function asrPromptProfiles(payload: ConfigPayload | null): AsrPromptProfile[] {
  const prompt = objectValue(payload?.pipeline?.asr_prompt);
  const rows = Array.isArray(prompt.profiles) ? prompt.profiles : [];
  return rows
    .filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item))
    .map((item) => ({
      id: String(item.id || ""),
      name: String(item.name || item.id || ""),
      scope: String(item.scope || "project"),
      version: numberValue(item.version, 1),
      path: String(item.path || ""),
      include_previous_text: Boolean(item.include_previous_text),
      max_chars: numberValue(item.max_chars, 800),
      text: typeof item.text === "string" ? item.text : "",
    }))
    .filter((item) => item.id);
}

function nextAsrPromptId(profiles: AsrPromptProfile[]) {
  const used = new Set(profiles.map((item) => item.id));
  for (let index = 1; index < 1000; index += 1) {
    const candidate = `asr_prompt_${index}`;
    if (!used.has(candidate)) return candidate;
  }
  return `asr_prompt_${Date.now()}`;
}

function compactCountMap(value?: Record<string, number>) {
  return Object.entries(value || {})
    .filter(([, count]) => count > 0)
    .map(([key, count]) => `${key}:${count}`)
    .join(" · ");
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
  const [subtitleStreams, setSubtitleStreams] = useState<SubtitleStream[]>([]);
  const [routingProfilesDraft, setRoutingProfilesDraft] = useState<RoutingProfile[]>([]);
  const [activeRoutingProfileId, setActiveRoutingProfileId] = useState("default");
  const [routingProfileNextSeq, setRoutingProfileNextSeq] = useState(1);
  const [taskResult, setTaskResult] = useState<TaskResultPayload | null>(null);
  const [selectedSegmentId, setSelectedSegmentId] = useState<number | null>(null);

  const selectedProvider = useMemo(
    () => config?.providers.find((provider) => provider.name === form.provider),
    [config, form.provider],
  );

  const selectedTemplate = useMemo(
    () => protocolTemplates(config).find((template) => template.id === providerTemplateId) || protocolTemplates(config).find((template) => template.compat_mode === providerDraft?.compat_mode),
    [config, providerDraft?.compat_mode, providerTemplateId],
  );

  const asrProfiles = useMemo(() => asrPromptProfiles(config), [config]);

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
      if (failed) return `${diagnosticHint(failed)} (${failed.code})`;
      return payload.message || text;
    } catch {
      return `操作失败：${text}`;
    }
  }

  async function refreshConfig() {
    const payload = await invoke<ConfigPayload>("get_config");
    const translation = fieldTranslation(payload.pipeline);
    const profiles = normalizeRoutingProfiles(payload);
    const activeProfileId = payload.active_routing_profile || profiles[0]?.id || "default";
    const fallbackSeq =
      profiles.reduce((max, profile) => {
        const match = /^route_(\d+)$/.exec(profile.id);
        return match ? Math.max(max, Number(match[1])) : max;
      }, 0) + 1;
    setConfig(payload);
    setRoutingProfilesDraft(profiles);
    setActiveRoutingProfileId(activeProfileId);
    setRoutingProfileNextSeq(Math.max(payload.routing_profile_next_seq || 1, fallbackSeq));
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
      const memory = objectValue(payload.pipeline.memory);
      const subtitle = objectValue(payload.pipeline.subtitle);
      const asrLocal = objectValue(payload.pipeline.asr_local);
      const asrCloud = objectValue(payload.pipeline.asr_cloud);
      const asrChunking = objectValue(payload.pipeline.asr_chunking);
      const asrPrompt = objectValue(payload.pipeline.asr_prompt);
      const promptProfiles = asrPromptProfiles(payload);
      const activeAsrPrompt = typeof asrPrompt.active_profile === "string" ? asrPrompt.active_profile : current.asrPromptProfile;
      const activePromptProfile = promptProfiles.find((item) => item.id === activeAsrPrompt);
      const reflow = objectValue(subtitle.reflow);
      return {
        ...current,
        provider,
        model: current.model || payload.routing.primary.model || providerConfig?.models[0] || "",
        asrMode: textValue(payload.pipeline.asr_mode, current.asrMode),
        asrDevice: textValue(asrLocal.device, current.asrDevice),
        asrModelSize: textValue(asrLocal.model_size, current.asrModelSize),
        asrComputeType: textValue(asrLocal.compute_type, current.asrComputeType),
        asrCloudBaseUrl: textValue(asrCloud.base_url, current.asrCloudBaseUrl),
        asrCloudEndpoint: textValue(asrCloud.endpoint, current.asrCloudEndpoint),
        asrModel: textValue(asrCloud.model, current.asrModel),
        asrCloudEnvKey: textValue(asrCloud.env_key, current.asrCloudEnvKey),
        asrCloudCredentialId: textValue(asrCloud.credential_id, current.asrCloudCredentialId),
        asrCloudTimeoutSeconds: numberValue(asrCloud.timeout_seconds, current.asrCloudTimeoutSeconds),
        asrPromptEnabled: (asrPrompt.enabled as boolean | undefined) ?? current.asrPromptEnabled,
        asrPromptProfile: activeAsrPrompt,
        asrPromptName: activePromptProfile?.name || current.asrPromptName,
        asrPromptText:
          activePromptProfile?.text ?? (typeof asrPrompt.text === "string" ? asrPrompt.text : current.asrPromptText),
        asrPromptIncludePreviousText:
          activePromptProfile?.include_previous_text ??
          ((asrPrompt.include_previous_text as boolean | undefined) ?? current.asrPromptIncludePreviousText),
        asrPromptMaxChars: activePromptProfile?.max_chars ?? numberValue(asrPrompt.max_chars, current.asrPromptMaxChars),
        sourceMode: textValue(payload.pipeline.source_mode, current.sourceMode) as FormState["sourceMode"],
        subtitleTrack: textValue(payload.pipeline.subtitle_track, current.subtitleTrack),
        asrChunkingMode: textValue(asrChunking?.mode, current.asrChunkingMode) as FormState["asrChunkingMode"],
        chunkSeconds: numberValue(asrChunking?.window_seconds, current.chunkSeconds),
        chunkOverlapSeconds: numberValue(asrChunking?.overlap_seconds, current.chunkOverlapSeconds),
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
        memoryEnabled: (memory.enabled as boolean | undefined) ?? current.memoryEnabled,
        memoryBootstrapEnabled:
          (objectValue(memory.bootstrap).enabled as boolean | undefined) ?? current.memoryBootstrapEnabled,
        memoryInjectEnabled: (objectValue(memory.inject).enabled as boolean | undefined) ?? current.memoryInjectEnabled,
        memoryPatchEnabled: (objectValue(memory.patch).enabled as boolean | undefined) ?? current.memoryPatchEnabled,
        memoryIntensity: textValue(objectValue(memory.inject).intensity, current.memoryIntensity) as FormState["memoryIntensity"],
        memoryPreset: current.memoryPreset || memoryPresetString(memory.presets),
        subtitleQualityMode: textValue(
          objectValue(subtitle.quality).mode,
          current.subtitleQualityMode,
        ) as FormState["subtitleQualityMode"],
        subtitleCompressionEnabled:
          (objectValue(subtitle.compression).enabled as boolean | undefined) ?? current.subtitleCompressionEnabled,
        subtitleReflowEnabled: (reflow.enabled as boolean | undefined) ?? current.subtitleReflowEnabled,
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
      protocolTemplates(config).find((item) => item.compat_mode === draft.compat_mode && item.base_url === draft.base_url) ||
      protocolTemplates(config).find((item) => item.compat_mode === draft.compat_mode);
    setProviderTemplateId(template?.id || draft.compat_mode);
    setProviderDraft(draft);
    setRequestMappingText(JSON.stringify(draft.request_mapping, null, 2));
    setProviderResult(null);
    setCustomModel("");
  }, [selectedProvider?.name, config?.protocol_templates, config?.provider_templates]);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => {
      const next: FormState = { ...current, [key]: value };
      if ((key === "memoryEnabled" || key === "memoryInjectEnabled") && value === false) {
        next.memoryPatchEnabled = false;
      }
      return next;
    });
  }

  function applySubtitleStreams(streams: SubtitleStream[], sourceLang: string) {
    const normalize = (value: string) => {
      const raw = value.trim().toLowerCase().replace("_", "-");
      const aliases: Record<string, string> = {
        jpn: "ja",
        jp: "ja",
        japanese: "ja",
        eng: "en",
        english: "en",
        chi: "zh",
        zho: "zh",
        chs: "zh",
        cht: "zh",
        "zh-cn": "zh",
        "zh-tw": "zh",
      };
      return aliases[raw] || raw.split("-")[0];
    };
    const wanted = normalize(sourceLang);
    const supported = streams.filter((stream) => stream.supported);
    const matched = supported.find((stream) => normalize(stream.language || "") === wanted);
    setSubtitleStreams(streams);
    if (matched) {
      update("sourceMode", "embedded_subtitle");
      update("subtitleTrack", String(matched.index));
    } else {
      update("sourceMode", "asr");
      update("subtitleTrack", "auto");
    }
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
      protocolTemplates(config).find((item) => item.id === templateId) ||
      protocolTemplates(config).find((item) => item.compat_mode === templateId);
    if (!template) return;
    setProviderTemplateId(template.id);
    setProviderDraft((current) => {
      const base = current || templateToDraft(template);
      return {
        name: base.name,
        env_key: base.env_key,
        credential_id: base.credential_id,
        models: [...base.models],
        api_type: template.api_type,
        compat_mode: template.compat_mode,
        base_url: template.base_url,
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

  function applyProviderPreset(presetId: string) {
    const preset = config?.provider_presets?.find((item) => item.id === presetId);
    if (!preset) return;
    const protocolId = preset.protocol_template_id || preset.id;
    setProviderTemplateId(protocolId);
    setProviderDraft((current) => {
      const base = current || templateToDraft(preset);
      return {
        name: base.name,
        env_key: base.env_key,
        credential_id: base.credential_id,
        models: [...base.models],
        api_type: preset.api_type,
        compat_mode: preset.compat_mode,
        base_url: preset.base_url,
        auth: { ...preset.auth },
        endpoint: { ...preset.endpoint },
        request_mapping: { ...preset.request_mapping },
        response_mapping: { text_paths: [...(preset.response_mapping?.text_paths || [])] },
        extra_headers: { ...(preset.extra_headers || {}) },
        model_list: {
          path_template: preset.model_list?.path_template || "/models",
          method: preset.model_list?.method || "GET",
          response_paths: [...(preset.model_list?.response_paths || ["data[].id"])],
        },
        capabilities: { ...(preset.capabilities || {}) },
      };
    });
    setRequestMappingText(JSON.stringify(preset.request_mapping, null, 2));
  }

  function useCustomAdapter() {
    const template = config?.custom_adapter_template || config?.provider_templates.find((item) => item.id === "custom_json");
    if (!template) return;
    setProviderTemplateId(template.id);
    setProviderDraft((current) => {
      const base = current || templateToDraft(template);
      return {
        name: base.name,
        env_key: base.env_key,
        credential_id: base.credential_id,
        models: [...base.models],
        api_type: template.api_type,
        compat_mode: template.compat_mode,
        base_url: template.base_url,
        auth: { ...template.auth },
        endpoint: { ...template.endpoint },
        request_mapping: { ...template.request_mapping },
        response_mapping: { text_paths: [...(template.response_mapping?.text_paths || [])] },
        extra_headers: { ...(template.extra_headers || {}) },
        model_list: {
          path_template: template.model_list?.path_template || "",
          method: template.model_list?.method || "GET",
          response_paths: [...(template.model_list?.response_paths || [])],
        },
        capabilities: { ...(template.capabilities || {}) },
      };
    });
    setRequestMappingText(JSON.stringify(template.request_mapping, null, 2));
    setProviderAdvancedOpen(true);
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

  function updateRoutingProfile(profileId: string, patch: Partial<RoutingProfile>) {
    setRoutingProfilesDraft((current) => current.map((profile) => (profile.id === profileId ? { ...profile, ...patch } : profile)));
  }

  function newRoutingProfile() {
    setRoutingProfilesDraft((current) => {
      const id = nextRouteProfileIdFromSeq(routingProfileNextSeq);
      const name = nextRouteProfileName(current);
      const primary = {
        provider: form.provider || config?.routing.primary.provider || config?.providers[0]?.name || "",
        model: form.model || config?.routing.primary.model || "",
      };
      const next = [...current, { id, name, primary, fallback: [] }];
      setActiveRoutingProfileId(id);
      setRoutingProfileNextSeq((value) => Math.max(value + 1, routingProfileNextSeq + 1));
      return next;
    });
  }

  function duplicateRoutingProfile(profileId: string) {
    setRoutingProfilesDraft((current) => {
      const source = current.find((profile) => profile.id === profileId) || current[0];
      if (!source) return current;
      const id = nextRouteProfileIdFromSeq(routingProfileNextSeq);
      const name = nextRouteProfileName(current);
      const next = [...current, { ...source, id, name, fallback: [...source.fallback] }];
      setActiveRoutingProfileId(id);
      setRoutingProfileNextSeq((value) => Math.max(value + 1, routingProfileNextSeq + 1));
      return next;
    });
  }

  function deleteRoutingProfile(profileId: string) {
    setRoutingProfilesDraft((current) => {
      if (current.length <= 1) return current;
      const next = current.filter((profile) => profile.id !== profileId);
      if (profileId === activeRoutingProfileId) setActiveRoutingProfileId(next[0]?.id || "default");
      return next;
    });
  }

  async function chooseVideo() {
    const selected = await open({
      multiple: false,
      filters:
        form.inputType === "srt"
          ? [{ name: "Subtitle", extensions: ["srt"] }]
          : [{ name: "Video", extensions: ["mp4", "mkv", "mov", "webm", "avi"] }],
    });
    if (typeof selected === "string") await setInputPath(selected);
  }

  async function setInputPath(path: string) {
    update("input", path);
    if (form.inputType !== "video") return;
    try {
      const streams = await invoke<SubtitleStream[]>("probe_subtitle_streams", { input: path });
      applySubtitleStreams(streams, form.sourceLang);
    } catch {
      setSubtitleStreams([]);
      update("sourceMode", "asr");
      update("subtitleTrack", "auto");
    }
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
        expectedVersion: config?.providers_file_version || null,
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

  async function persistRouting(activeProfileId: string, noticeMessage: string) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const profiles = routingProfilesDraft.length
        ? routingProfilesDraft
        : [
            {
              id: "default",
              name: "Default",
              primary: { provider: form.provider, model: form.model },
              fallback: [],
            },
          ];
      const activeProfile = profiles.find((profile) => profile.id === activeProfileId) || profiles[0];
      const validationError = validateRoutingProfileDrafts(profiles);
      if (validationError) throw new Error(validationError);
      await invoke("save_provider_routing", {
        routing: {
          active_profile: activeProfile.id,
          profiles,
          next_profile_seq: routingProfileNextSeq,
          expected_version: config?.providers_file_version || null,
        },
      });
      setActiveRoutingProfileId(activeProfile.id);
      update("provider", activeProfile.primary.provider);
      update("model", activeProfile.primary.model);
      setNotice(noticeMessage);
      await refreshConfig();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function saveRouting() {
    await persistRouting(activeRoutingProfileId, "Route profile 已保存");
  }

  async function activateRoutingProfile(profileId: string) {
    if (profileId === activeRoutingProfileId) return;
    await persistRouting(profileId, "Route profile 已切换并设为默认");
  }

  async function deleteProvider() {
    if (!providerDraft?.name) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const payload = await invoke<{ deleted: boolean; blocked?: boolean; hint_zh?: string; message?: string; references?: Array<Record<string, string>> }>("delete_provider_config", {
        name: providerDraft.name,
        expectedVersion: config?.providers_file_version || null,
      });
      if (payload.blocked) {
        const refs = payload.references?.map((item) => `${item.profile_name || item.profile_id}:${item.route}`).join("，");
        setError(`${payload.hint_zh || payload.message || "Provider 正在被使用。"}${refs ? ` 引用：${refs}` : ""}`);
        await refreshConfig();
        return;
      }
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

  function selectAsrPromptProfile(profileId: string) {
    const profile = asrProfiles.find((item) => item.id === profileId);
    update("asrPromptProfile", profileId);
    if (profile) {
      update("asrPromptName", profile.name);
      update("asrPromptText", profile.text || "");
      update("asrPromptIncludePreviousText", profile.include_previous_text);
      update("asrPromptMaxChars", profile.max_chars);
    }
  }

  function newAsrPromptProfile() {
    const id = nextAsrPromptId(asrProfiles);
    update("asrPromptProfile", id);
    update("asrPromptName", `ASR Prompt ${asrProfiles.length + 1}`);
    update("asrPromptText", "");
    update("asrPromptIncludePreviousText", false);
    update("asrPromptMaxChars", 800);
  }

  function duplicateAsrPromptProfile() {
    const id = nextAsrPromptId(asrProfiles);
    update("asrPromptProfile", id);
    update("asrPromptName", `${form.asrPromptName || "ASR Prompt"} Copy`);
  }

  async function saveAsrPromptProfile() {
    if (!form.asrPromptProfile.trim()) {
      setError("ASR prompt profile id 不能为空。");
      return;
    }
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("save_asr_prompt_profile", {
        profile: {
          id: form.asrPromptProfile.trim(),
          name: form.asrPromptName.trim() || form.asrPromptProfile.trim(),
          scope: "project",
          version: asrProfiles.find((item) => item.id === form.asrPromptProfile)?.version || 1,
          text: form.asrPromptText,
          include_previous_text: form.asrPromptIncludePreviousText,
          max_chars: form.asrPromptMaxChars,
          enabled: form.asrPromptEnabled,
          active: true,
        },
      });
      setNotice("ASR prompt profile 已保存");
      await refreshConfig();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function deleteAsrPromptProfile() {
    if (!form.asrPromptProfile.trim()) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await invoke("delete_asr_prompt_profile", { profileId: form.asrPromptProfile.trim() });
      setNotice("ASR prompt profile 已删除");
      update("asrPromptProfile", "");
      update("asrPromptName", "");
      update("asrPromptText", "");
      await refreshConfig();
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
    const memoryPresets = memoryPresetRefs(form.memoryPreset);
    return {
      provider: form.provider || null,
      model: form.model || null,
      asrMode: form.asrMode || null,
      asrDevice: form.asrDevice || null,
      asrModelSize: form.asrModelSize || null,
      asrComputeType: form.asrComputeType || null,
      asrCloudBaseUrl: form.asrCloudBaseUrl || null,
      asrCloudEndpoint: form.asrCloudEndpoint || null,
      asrModel: form.asrModel || null,
      asrCloudEnvKey: form.asrCloudEnvKey || null,
      asrCloudCredentialId: form.asrCloudCredentialId || null,
      asrCloudTimeoutSeconds: form.asrCloudTimeoutSeconds,
      asrPromptProfile: form.asrPromptProfile || null,
      asrPromptText: form.asrPromptText || null,
      asrPromptEnabled: form.asrPromptEnabled,
      asrPromptIncludePreviousText: form.asrPromptIncludePreviousText,
      asrPromptMaxChars: form.asrPromptMaxChars,
      asrChunkingMode: form.asrChunkingMode || null,
      asrWindowSeconds: form.chunkSeconds,
      asrOverlapSeconds: form.chunkOverlapSeconds,
      sourceMode: form.sourceMode || null,
      subtitleTrack: form.subtitleTrack || null,
      translationBatchSize: form.translationBatchSize,
      translationStylePreset: form.translationStylePreset,
      translationStylePrompt: buildTranslationStylePrompt(form.projectPrompt, form.translationStylePrompt),
      translationChunkLines: form.translationChunkLines,
      translationContextBeforeLines: form.translationContextBeforeLines,
      translationContextAfterLines: form.translationContextAfterLines,
      translationRepairEnabled: form.translationRepairEnabled,
      subtitleQualityMode: form.subtitleQualityMode,
      subtitleCompressionEnabled: form.subtitleCompressionEnabled,
      subtitleReflowEnabled: form.subtitleReflowEnabled,
      memoryEnabled: form.memoryEnabled,
      memoryBootstrapEnabled: form.memoryBootstrapEnabled,
      memoryInjectEnabled: form.memoryInjectEnabled,
      memoryPatchEnabled: form.memoryEnabled && form.memoryInjectEnabled ? form.memoryPatchEnabled : false,
      memoryIntensity: form.memoryIntensity,
      memoryPreset: memoryPresets.length ? memoryPresets.join(",") : null,
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
      await invoke("reexport_task", {
        taskId: taskResult.task.task_id,
        outputFormat: form.outputFormat,
        bilingual: form.bilingual,
      });
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
          subtitleStreams={subtitleStreams}
          chooseVideo={chooseVideo}
          setInputPath={setInputPath}
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
          applyProviderPreset={applyProviderPreset}
          useCustomAdapter={useCustomAdapter}
          newProviderDraft={newProviderDraft}
          saveProvider={saveProvider}
          deleteProvider={deleteProvider}
          fetchModels={fetchModels}
          testConnection={testConnection}
          useProviderForTask={useProviderForTask}
          addCustomModel={addCustomModel}
          routingProfilesDraft={routingProfilesDraft}
          activeRoutingProfileId={activeRoutingProfileId}
          updateRoutingProfile={updateRoutingProfile}
          newRoutingProfile={newRoutingProfile}
          duplicateRoutingProfile={duplicateRoutingProfile}
          deleteRoutingProfile={deleteRoutingProfile}
          saveRouting={saveRouting}
          activateRoutingProfile={activateRoutingProfile}
          asrProfiles={asrProfiles}
          selectAsrPromptProfile={selectAsrPromptProfile}
          newAsrPromptProfile={newAsrPromptProfile}
          duplicateAsrPromptProfile={duplicateAsrPromptProfile}
          saveAsrPromptProfile={saveAsrPromptProfile}
          deleteAsrPromptProfile={deleteAsrPromptProfile}
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
          openPath={openPath}
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
  subtitleStreams,
  chooseVideo,
  setInputPath,
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
  subtitleStreams: SubtitleStream[];
  chooseVideo: () => void;
  setInputPath: (path: string) => Promise<void>;
  chooseOutputDir: () => void;
  startTask: () => void;
  cancelTask: () => void;
  probe: () => void;
}) {
  const selectedPresetCount = memoryPresetRefs(form.memoryPreset).length;

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
            if (file) void setInputPath(file.path || file.name);
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
        {form.inputType === "video" && (
          <div className="mt-4 grid grid-cols-2 gap-4">
            <label className="tvx-label">
              {t("sourceMode")}
              <select className="tvx-input" value={form.sourceMode} onChange={(event) => update("sourceMode", event.target.value as FormState["sourceMode"])}>
                <option value="auto">{t("sourceAuto")}</option>
                <option value="asr">{t("sourceAsr")}</option>
                <option value="embedded_subtitle">{t("sourceEmbeddedSubtitle")}</option>
              </select>
            </label>
            <label className="tvx-label">
              {t("subtitleTrack")}
              <select className="tvx-input" value={form.subtitleTrack} onChange={(event) => update("subtitleTrack", event.target.value)}>
                <option value="auto">{subtitleStreams.some((stream) => stream.supported) ? t("sourceAuto") : t("noSubtitleTrack")}</option>
                {subtitleStreams
                  .filter((stream) => stream.supported)
                  .map((stream) => (
                    <option value={String(stream.index)} key={stream.index}>
                      #{stream.index} {stream.language || "-"} {stream.title || stream.codec_name}
                    </option>
                  ))}
              </select>
            </label>
          </div>
        )}
      </Panel>

      <Panel title={t("preTranslation")}>
        <div className="grid grid-cols-2 gap-4">
          <label className="tvx-label">
            {t("projectPrompt")}
            <textarea
              className="tvx-textarea min-h-28"
              placeholder={t("projectPromptPlaceholder")}
              value={form.projectPrompt}
              onChange={(event) => update("projectPrompt", event.target.value)}
            />
          </label>
          <label className="tvx-label">
            {t("stylePrompt")}
            <textarea
              className="tvx-textarea min-h-28"
              placeholder={t("stylePromptPlaceholder")}
              value={form.translationStylePrompt}
              onChange={(event) => update("translationStylePrompt", event.target.value)}
            />
          </label>
        </div>
        <div className="mt-4 grid grid-cols-[360px_160px_minmax(0,1fr)_120px] items-end gap-4">
          <div className="grid grid-cols-2 gap-2">
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={form.memoryEnabled} onChange={(event) => update("memoryEnabled", event.target.checked)} />
              {t("memoryEnabled")}
            </label>
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={form.memoryBootstrapEnabled} disabled={!form.memoryEnabled} onChange={(event) => update("memoryBootstrapEnabled", event.target.checked)} />
              {t("memoryBootstrap")}
            </label>
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={form.memoryInjectEnabled} disabled={!form.memoryEnabled} onChange={(event) => update("memoryInjectEnabled", event.target.checked)} />
              {t("memoryInject")}
            </label>
            <label className="flex items-center gap-2 text-sm text-text">
              <input type="checkbox" checked={form.memoryPatchEnabled} disabled={!form.memoryEnabled || !form.memoryInjectEnabled} onChange={(event) => update("memoryPatchEnabled", event.target.checked)} />
              {t("memoryPatch")}
            </label>
          </div>
          <label className="tvx-label">
            {t("memoryIntensity")}
            <select className="tvx-input" value={form.memoryIntensity} disabled={!form.memoryEnabled || !form.memoryInjectEnabled} onChange={(event) => update("memoryIntensity", event.target.value as FormState["memoryIntensity"])}>
              <option value="high">{t("memoryIntensityHigh")}</option>
              <option value="auto">{t("memoryIntensityAuto")}</option>
              <option value="low">{t("memoryIntensityLow")}</option>
              <option value="max">{t("memoryIntensityMax")}</option>
            </select>
          </label>
          <label className="tvx-label">
            {t("memoryPreset")}
            <input
              className="tvx-input"
              placeholder="nold, rezero:locked"
              value={form.memoryPreset}
              onChange={(event) => {
                update("memoryPreset", event.target.value);
              }}
            />
          </label>
          <div className="rounded-md border border-line bg-slate-50 px-3 py-2 text-xs text-muted">
            <strong className="block text-sm text-ink">{selectedPresetCount}</strong>
            preset
          </div>
        </div>
        <p className="mt-2 text-xs leading-relaxed text-muted">{t("memoryPresetHint")}</p>
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
              ASR chunking
              <select className="tvx-input" value={form.asrChunkingMode} onChange={(event) => update("asrChunkingMode", event.target.value as FormState["asrChunkingMode"])}>
                <option value="auto">auto</option>
                <option value="fixed">fixed</option>
                <option value="none">none</option>
              </select>
            </label>
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
        <label className="tvx-label">
          字幕质量
          <select className="tvx-input" value={form.subtitleQualityMode} onChange={(event) => update("subtitleQualityMode", event.target.value as FormState["subtitleQualityMode"])}>
            <option value="off">off</option>
            <option value="conservative">conservative</option>
            <option value="balanced">balanced</option>
          </select>
        </label>
      </div>
      <div className="mt-4 flex flex-wrap gap-6">
        <label className="inline-flex items-center gap-2 text-sm">
          <input className="h-4 w-4" type="checkbox" checked={form.translationRepairEnabled} onChange={(event) => update("translationRepairEnabled", event.target.checked)} />
          {t("repairRows")}
        </label>
        <label className="inline-flex items-center gap-2 text-sm">
          <input className="h-4 w-4" type="checkbox" checked={form.subtitleCompressionEnabled} onChange={(event) => update("subtitleCompressionEnabled", event.target.checked)} />
          模型压缩
        </label>
        <label className="inline-flex items-center gap-2 text-sm">
          <input className="h-4 w-4" type="checkbox" checked={form.subtitleReflowEnabled} onChange={(event) => update("subtitleReflowEnabled", event.target.checked)} />
          {t("reflowRows")}
        </label>
      </div>
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
  applyProviderPreset,
  useCustomAdapter,
  newProviderDraft,
  saveProvider,
  deleteProvider,
  fetchModels,
  testConnection,
  useProviderForTask,
  addCustomModel,
  routingProfilesDraft,
  activeRoutingProfileId,
  updateRoutingProfile,
  newRoutingProfile,
  duplicateRoutingProfile,
  deleteRoutingProfile,
  saveRouting,
  activateRoutingProfile,
  asrProfiles,
  selectAsrPromptProfile,
  newAsrPromptProfile,
  duplicateAsrPromptProfile,
  saveAsrPromptProfile,
  deleteAsrPromptProfile,
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
  applyProviderPreset: (presetId: string) => void;
  useCustomAdapter: () => void;
  newProviderDraft: () => void;
  saveProvider: () => void;
  deleteProvider: () => void;
  fetchModels: () => void;
  testConnection: () => void;
  useProviderForTask: () => void;
  addCustomModel: () => void;
  routingProfilesDraft: RoutingProfile[];
  activeRoutingProfileId: string;
  updateRoutingProfile: (profileId: string, patch: Partial<RoutingProfile>) => void;
  newRoutingProfile: () => void;
  duplicateRoutingProfile: (profileId: string) => void;
  deleteRoutingProfile: (profileId: string) => void;
  saveRouting: () => void;
  activateRoutingProfile: (profileId: string) => void;
  asrProfiles: AsrPromptProfile[];
  selectAsrPromptProfile: (profileId: string) => void;
  newAsrPromptProfile: () => void;
  duplicateAsrPromptProfile: () => void;
  saveAsrPromptProfile: () => void;
  deleteAsrPromptProfile: () => void;
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
  const activeProfile = routingProfilesDraft.find((profile) => profile.id === activeRoutingProfileId) || routingProfilesDraft[0];
  return (
    <div className="space-y-4">
      <Panel title="Route Profiles">
        <div className="grid grid-cols-[220px_minmax(0,1fr)] gap-4">
          <aside className="space-y-2">
            <button className="tvx-btn w-full justify-start" onClick={newRoutingProfile} disabled={busy}>
              <Plus size={16} /> 新建配置
            </button>
            <div className="grid max-h-[280px] gap-2 overflow-auto pr-1">
              {routingProfilesDraft.map((profile) => (
                <button
                  key={profile.id}
                  className={`rounded-lg border p-3 text-left text-sm transition ${
                    profile.id === activeRoutingProfileId ? "border-brand bg-emerald-50" : "border-line bg-white hover:bg-slate-50"
                  }`}
                  onClick={() => activateRoutingProfile(profile.id)}
                  disabled={busy}
                >
                  <span className="block truncate font-semibold">{profile.name}</span>
                  <span className="mt-1 block truncate text-xs text-muted">
                    {profile.primary.provider || "未选择"} · {profile.primary.model || "未选择模型"}
                  </span>
                  <span className="mt-2 block text-[11px] text-muted">Fallback {profile.fallback.length}</span>
                </button>
              ))}
            </div>
          </aside>
          <section className="space-y-3">
            {!activeProfile && <p className="rounded-lg bg-slate-50 p-3 text-sm text-muted">请新建一个模型路由配置。</p>}
            {activeProfile && (
              <>
                <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-end gap-3">
                  <label className="tvx-label">
                    配置名称
                    <input className="tvx-input" value={activeProfile.name} onChange={(event) => updateRoutingProfile(activeProfile.id, { name: event.target.value })} />
                  </label>
                  <button className="tvx-btn" onClick={() => duplicateRoutingProfile(activeProfile.id)} disabled={busy}>
                    <ClipboardList size={16} /> 复制
                  </button>
                  <button className="tvx-btn tvx-btn-danger" onClick={() => deleteRoutingProfile(activeProfile.id)} disabled={busy || routingProfilesDraft.length <= 1}>
                    <Trash2 size={16} /> 删除
                  </button>
                </div>
                <RouteEditor
                  label="Primary"
                  route={activeProfile.primary}
                  providers={config?.providers || []}
                  onChange={(route) => {
                    updateRoutingProfile(activeProfile.id, { primary: route });
                    update("provider", route.provider);
                    update("model", route.model);
                  }}
                />
                <div className="space-y-2">
                  <div className="flex items-center justify-between">
                    <span className="text-xs font-medium text-muted">Fallback</span>
                    <button
                      className="tvx-btn min-h-8 px-2"
                      onClick={() => updateRoutingProfile(activeProfile.id, { fallback: [...activeProfile.fallback, { provider: "", model: "" }] })}
                    >
                      <Plus size={14} /> 添加
                    </button>
                  </div>
                  {activeProfile.fallback.map((route, index) => (
                    <div key={index} className="grid grid-cols-[minmax(0,1fr)_36px] gap-2">
                      <RouteEditor
                        label={`Fallback ${index + 1}`}
                        route={route}
                        providers={config?.providers || []}
                        onChange={(next) =>
                          updateRoutingProfile(activeProfile.id, {
                            fallback: activeProfile.fallback.map((item, itemIndex) => (itemIndex === index ? next : item)),
                          })
                        }
                      />
                      <button
                        className="tvx-btn tvx-btn-danger mt-5 px-0"
                        onClick={() =>
                          updateRoutingProfile(activeProfile.id, {
                            fallback: activeProfile.fallback.filter((_, itemIndex) => itemIndex !== index),
                          })
                        }
                      >
                        <Trash2 size={14} />
                      </button>
                    </div>
                  ))}
                </div>
                <button className="tvx-btn tvx-btn-primary" onClick={saveRouting} disabled={busy || !activeProfile.primary.provider || !activeProfile.primary.model}>
                  <Save size={16} /> 保存并设为默认
                </button>
              </>
            )}
          </section>
        </div>
      </Panel>

      <Panel title="Provider Connections">
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
                    {provider.has_key ? `${t("configured")} · ${provider.credential_source || "unknown"}` : t("missing")}
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
                    Provider preset
                    <select className="tvx-input" defaultValue="" onChange={(event) => event.target.value && applyProviderPreset(event.target.value)}>
                      <option value="">不使用快捷预设</option>
                      {config?.provider_presets?.map((preset) => (
                        <option key={preset.id} value={preset.id}>
                          {preset.label}
                        </option>
                      ))}
                    </select>
                    <span className="text-xs font-normal text-muted">切换 preset 会重置协议字段，仅保留名称、凭据引用和模型列表。</span>
                  </label>
                  <label className="tvx-label">
                    Protocol
                    <select className="tvx-input" value={providerTemplateId} onChange={(event) => updateProviderTemplate(event.target.value)}>
                      {protocolTemplates(config).map((template) => (
                        <option key={template.id} value={template.id}>
                          {template.label}
                        </option>
                      ))}
                    </select>
                    <span className="text-xs font-normal text-muted">切换 protocol 会重置 auth、endpoint、mapping、headers 和 capabilities。</span>
                  </label>
                  <label className="tvx-label">
                    {t("providerName")}
                    <input
                      className="tvx-input"
                      value={providerDraft.name}
                      onChange={(event) => {
                        const name = event.target.value;
                        updateProviderDraft({ name, env_key: providerDraft.env_key || envKeyForName(name), credential_id: providerDraft.credential_id || name });
                      }}
                    />
                  </label>
                  <label className="tvx-label">
                    {t("baseUrl")}
                    <input className="tvx-input" value={providerDraft.base_url} onChange={(event) => updateProviderDraft({ base_url: event.target.value })} />
                  </label>
                  <label className="tvx-label">
                    {t("envKey")}
                    <input className="tvx-input" value={providerDraft.env_key} onChange={(event) => updateProviderDraft({ env_key: event.target.value })} />
                  </label>
                  <label className="tvx-label">
                    credential_id
                    <input className="tvx-input" value={providerDraft.credential_id} onChange={(event) => updateProviderDraft({ credential_id: event.target.value })} />
                  </label>
                  <div className="flex items-end">
                    <button className="tvx-btn w-full" onClick={useCustomAdapter} disabled={busy}>
                      <SlidersHorizontal size={16} /> 找不到你的 API？
                    </button>
                  </div>
                </div>

                <section className="grid grid-cols-[24px_minmax(120px,1fr)_minmax(180px,260px)_auto] items-center gap-3 rounded-lg border border-line p-3">
                  <KeyRound className="text-brand" size={18} />
                  <div>
                    <strong className="block text-sm">{providerDraft.env_key}</strong>
                    <span className="text-xs text-muted">
                      {selectedProvider?.name === providerDraft.name && selectedProvider?.has_key
                        ? `${t("configured")} · ${selectedProvider.credential_source || "unknown"}`
                        : "可保存新 key"}
                    </span>
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

      <Panel title="ASR">
        <div className="grid grid-cols-4 gap-4">
          <label className="tvx-label">
            {t("asrMode")}
            <select className="tvx-input" value={form.asrMode} onChange={(event) => update("asrMode", event.target.value)}>
              <option value="local">local</option>
              <option value="cloud">cloud</option>
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
          <label className="tvx-label">
            {t("asrCloudBaseUrl")}
            <input className="tvx-input" value={form.asrCloudBaseUrl} onChange={(event) => update("asrCloudBaseUrl", event.target.value)} />
          </label>
          <label className="tvx-label">
            {t("asrCloudEndpoint")}
            <input className="tvx-input" value={form.asrCloudEndpoint} onChange={(event) => update("asrCloudEndpoint", event.target.value)} />
          </label>
          <label className="tvx-label">
            {t("asrCloudModel")}
            <input className="tvx-input" value={form.asrModel} onChange={(event) => update("asrModel", event.target.value)} />
          </label>
          <label className="tvx-label">
            {t("asrCloudTimeout")}
            <input
              className="tvx-input"
              type="number"
              min="1"
              value={form.asrCloudTimeoutSeconds}
              onChange={(event) => update("asrCloudTimeoutSeconds", Number(event.target.value))}
            />
          </label>
          <label className="tvx-label">
            {t("asrCloudEnvKey")}
            <input className="tvx-input" value={form.asrCloudEnvKey} onChange={(event) => update("asrCloudEnvKey", event.target.value)} />
          </label>
          <label className="tvx-label">
            {t("asrCloudCredentialId")}
            <input className="tvx-input" value={form.asrCloudCredentialId} onChange={(event) => update("asrCloudCredentialId", event.target.value)} />
          </label>
        </div>
        <section className="mt-4 grid grid-cols-[220px_minmax(0,1fr)] gap-4">
          <aside className="space-y-2">
            <button className="tvx-btn w-full justify-start" onClick={newAsrPromptProfile} disabled={busy}>
              <Plus size={16} /> 新建 ASR Prompt
            </button>
            <div className="grid max-h-[240px] gap-2 overflow-auto pr-1">
              {asrProfiles.map((profile) => (
                <button
                  key={profile.id}
                  className={`rounded-lg border p-3 text-left text-sm transition ${
                    profile.id === form.asrPromptProfile ? "border-brand bg-emerald-50" : "border-line bg-white hover:bg-slate-50"
                  }`}
                  onClick={() => selectAsrPromptProfile(profile.id)}
                  disabled={busy}
                >
                  <span className="block truncate font-semibold">{profile.name || profile.id}</span>
                  <span className="mt-1 block truncate text-xs text-muted">{profile.id}</span>
                  <span className="mt-2 block text-[11px] text-muted">
                    {profile.include_previous_text ? "previous text" : "static"} · {profile.max_chars}
                  </span>
                </button>
              ))}
            </div>
          </aside>
          <div className="space-y-3">
            <div className="grid grid-cols-[minmax(0,180px)_minmax(0,1fr)_120px] gap-3">
              <label className="tvx-label">
                profile id
                <input className="tvx-input" value={form.asrPromptProfile} onChange={(event) => update("asrPromptProfile", event.target.value)} />
              </label>
              <label className="tvx-label">
                名称
                <input className="tvx-input" value={form.asrPromptName} onChange={(event) => update("asrPromptName", event.target.value)} />
              </label>
              <label className="tvx-label">
                max chars
                <input className="tvx-input" type="number" min="0" value={form.asrPromptMaxChars} onChange={(event) => update("asrPromptMaxChars", Number(event.target.value))} />
              </label>
            </div>
            <textarea
              className="tvx-textarea min-h-32"
              value={form.asrPromptText}
              placeholder="角色名、专有名词、转写风格或上下文提示。"
              onChange={(event) => update("asrPromptText", event.target.value)}
            />
            <div className="flex flex-wrap items-center gap-4">
              <label className="inline-flex items-center gap-2 text-sm">
                <input className="h-4 w-4" type="checkbox" checked={form.asrPromptEnabled} onChange={(event) => update("asrPromptEnabled", event.target.checked)} />
                启用 ASR prompt
              </label>
              <label className="inline-flex items-center gap-2 text-sm">
                <input className="h-4 w-4" type="checkbox" checked={form.asrPromptIncludePreviousText} onChange={(event) => update("asrPromptIncludePreviousText", event.target.checked)} />
                拼接上一段 transcript
              </label>
              <button className="tvx-btn" onClick={duplicateAsrPromptProfile} disabled={busy || !form.asrPromptProfile}>
                <ClipboardList size={16} /> 复制
              </button>
              <button className="tvx-btn tvx-btn-primary" onClick={saveAsrPromptProfile} disabled={busy || !form.asrPromptProfile}>
                <Save size={16} /> 保存
              </button>
              <button className="tvx-btn tvx-btn-danger" onClick={deleteAsrPromptProfile} disabled={busy || !form.asrPromptProfile}>
                <Trash2 size={16} /> 删除
              </button>
            </div>
          </div>
        </section>
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
              <p className="mt-1 text-xs leading-relaxed text-muted">{diagnosticHint(check)}</p>
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
  openPath,
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
  openPath: (path?: string | null) => void;
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
  const qualityResiduals = compactCountMap(result.quality?.residual_counts);
  const qualityActions = compactCountMap(result.quality?.action_counts);
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
      <div className="grid grid-cols-2 gap-4">
        <Panel title={t("qualitySummary")}>
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">status</span>
              <strong className={statusTone(result.quality?.status || "")}>{result.quality?.status || "-"}</strong>
            </div>
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">issues</span>
              <strong>{result.quality?.segments_with_issues ?? 0}</strong>
            </div>
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">max cps</span>
              <strong>{Number(result.quality?.max_cps || 0).toFixed(1)}</strong>
            </div>
          </div>
          <p className="mt-3 truncate text-xs text-muted">{qualityResiduals || qualityActions || "暂无质量问题记录"}</p>
        </Panel>
        <Panel title={t("memorySummary")}>
          <div className="grid grid-cols-4 gap-3 text-sm">
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">preset</span>
              <strong>{result.memory?.preset_entries ?? 0}</strong>
            </div>
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">runtime</span>
              <strong>{result.memory?.runtime_entries ?? 0}</strong>
            </div>
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">issues</span>
              <strong>{result.memory?.issues ?? 0}</strong>
            </div>
            <div className="rounded-md border border-line bg-slate-50 p-3">
              <span className="block text-xs text-muted">reflow</span>
              <strong>{result.reflow?.reflowed ?? 0}/{result.reflow?.windows ?? 0}</strong>
            </div>
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            {result.memory?.paths.selected_presets && (
              <button className="tvx-btn min-h-8 px-2 text-xs" onClick={() => openPath(result.memory?.paths.selected_presets)}>
                <FileText size={14} />
                selected_presets
              </button>
            )}
            {result.memory?.paths.translation_memory && (
              <button className="tvx-btn min-h-8 px-2 text-xs" onClick={() => openPath(result.memory?.paths.translation_memory)}>
                <FileText size={14} />
                runtime_memory
              </button>
            )}
            {result.reflow?.path && (
              <button className="tvx-btn min-h-8 px-2 text-xs" onClick={() => openPath(result.reflow?.path)}>
                <FileText size={14} />
                reflow_log
              </button>
            )}
          </div>
        </Panel>
      </div>
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
            <p className="mt-2 text-sm leading-relaxed text-muted">{diagnosticHint(check)}</p>
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
