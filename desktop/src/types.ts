export type AuthConfig = {
  type: string;
  header_name?: string;
  query_name?: string;
  prefix?: string;
};

export type EndpointConfig = {
  path_template: string;
  method: string;
};

export type ModelListConfig = {
  path_template: string;
  method: string;
  response_paths: string[];
};

export type ProviderConfig = {
  name: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  env_key: string;
  credential_id?: string;
  credential_source?: string;
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

export type ProviderTemplate = {
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

export type RouteTarget = { provider: string; model: string };

export type RoutingProfile = {
  id: string;
  name: string;
  primary: RouteTarget;
  fallback: RouteTarget[];
};

export type ProviderPreset = ProviderTemplate & {
  protocol_template_id?: string;
};

export type FileVersion = { mtime_ns: number; size: number } | null;

export type ConfigPayload = {
  root_dir: string;
  providers_file?: string;
  providers_file_version?: FileVersion;
  artifacts_dir: string;
  pipeline: Record<string, unknown>;
  routing: { primary: RouteTarget; fallback?: RouteTarget[] };
  active_routing_profile?: string;
  routing_profiles?: RoutingProfile[];
  routing_profile_next_seq?: number;
  protocol_templates?: ProviderTemplate[];
  provider_presets?: ProviderPreset[];
  custom_adapter_template?: ProviderTemplate;
  provider_templates: ProviderTemplate[];
  providers: ProviderConfig[];
};

export type ProviderDraft = {
  name: string;
  api_type: string;
  compat_mode: string;
  base_url: string;
  env_key: string;
  credential_id: string;
  models: string[];
  auth: AuthConfig;
  endpoint: EndpointConfig;
  request_mapping: Record<string, unknown>;
  response_mapping: { text_paths: string[] };
  extra_headers: Record<string, string>;
  model_list: ModelListConfig;
  capabilities: Record<string, unknown>;
};

export type ProviderDiagnostic = {
  name?: string;
  status: "PASS" | "WARN" | "FAIL";
  code: string;
  message: string;
  hint_zh?: string;
  details?: Record<string, unknown>;
  credential_id?: string;
  credential_source?: string;
};

export type ProviderTestPayload = {
  status: "PASS" | "WARN" | "FAIL";
  checks: ProviderDiagnostic[];
};

export type ProviderModelsPayload = ProviderDiagnostic & {
  models: string[];
};

export type TaskRecord = {
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

export type ResultSegment = {
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
  quality_issues?: Array<{ code: string; level: string; message: string }>;
};

export type TaskResultPayload = {
  task: TaskRecord & { settings?: Record<string, unknown>; task_dir?: string };
  segments: ResultSegment[];
  quality?: {
    mode?: string;
    status?: string;
    segments?: number;
    segments_with_issues?: number;
    issue_counts?: Record<string, number>;
    residual_counts?: Record<string, number>;
    action_counts?: Record<string, number>;
    max_cps?: number;
    thresholds?: Record<string, number>;
  };
  reflow?: {
    enabled: boolean;
    windows: number;
    reflowed: number;
    failed: number;
    path: string;
  };
  memory?: {
    enabled: boolean;
    entries: number;
    runtime_entries: number;
    preset_entries: number;
    issues: number;
    paths: {
      translation_memory: string;
      selected_presets: string;
      consistency_issues: string;
    };
  };
  output_paths?: Record<string, string>;
};

export type WorkerEvent = {
  type: string;
  task_id?: string;
  created_at?: string;
  stage?: string;
  level?: string;
  message?: string;
  progress?: number;
  details?: Record<string, unknown>;
};

export type DoctorCheck = {
  name: string;
  status: "PASS" | "WARN" | "FAIL";
  code: string;
  message: string;
  hint_zh?: string;
  details?: Record<string, unknown>;
};

export type DoctorPayload = {
  status: "PASS" | "WARN" | "FAIL";
  root_dir: string;
  providers_file?: string;
  artifacts_dir?: string;
  checks: DoctorCheck[];
};

export type ActiveView = "start" | "translation" | "provider" | "history" | "result" | "environment";

export type FormState = {
  input: string;
  inputType: "video" | "srt";
  sourceMode: "auto" | "asr" | "embedded_subtitle";
  subtitleTrack: string;
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
  asrCloudBaseUrl: string;
  asrCloudEndpoint: string;
  asrModel: string;
  asrCloudEnvKey: string;
  asrCloudCredentialId: string;
  asrCloudTimeoutSeconds: number;
  asrChunkingMode: "auto" | "fixed" | "none";
  chunkSeconds: number;
  chunkOverlapSeconds: number;
  translationBatchSize: number;
  translationStylePreset: string;
  translationStylePrompt: string;
  projectPrompt: string;
  memoryEnabled: boolean;
  memoryPreset: string;
  translationChunkLines: number;
  translationContextBeforeLines: number;
  translationContextAfterLines: number;
  translationRepairEnabled: boolean;
  subtitleQualityMode: "off" | "conservative" | "balanced";
  subtitleCompressionEnabled: boolean;
  subtitleReflowEnabled: boolean;
  outputFormat: "srt" | "ass" | "both";
  concurrency: number;
  apiKey: string;
};

export const emptyForm: FormState = {
  input: "",
  inputType: "video",
  sourceMode: "auto",
  subtitleTrack: "auto",
  outputDir: "",
  sourceLang: "en",
  targetLang: "zh-CN",
  bilingual: false,
  provider: "",
  model: "",
  asrMode: "local",
  asrDevice: "auto",
  asrModelSize: "small",
  asrComputeType: "int8",
  asrCloudBaseUrl: "https://api.openai.com",
  asrCloudEndpoint: "/v1/audio/transcriptions",
  asrModel: "whisper-1",
  asrCloudEnvKey: "TVX_MODEL_API_KEY",
  asrCloudCredentialId: "TVX_MODEL_API_KEY",
  asrCloudTimeoutSeconds: 120,
  asrChunkingMode: "auto",
  chunkSeconds: 300,
  chunkOverlapSeconds: 30,
  translationBatchSize: 40,
  translationStylePreset: "subtitle_natural",
  translationStylePrompt: "",
  projectPrompt: "",
  memoryEnabled: true,
  memoryPreset: "",
  translationChunkLines: 40,
  translationContextBeforeLines: 20,
  translationContextAfterLines: 10,
  translationRepairEnabled: true,
  subtitleQualityMode: "balanced",
  subtitleCompressionEnabled: false,
  subtitleReflowEnabled: false,
  outputFormat: "srt",
  concurrency: 8,
  apiKey: "",
};

export type DroppedFile = File & { path?: string };

export type SubtitleStream = {
  index: number;
  codec_name: string;
  language: string;
  title: string;
  default: boolean;
  forced: boolean;
  supported: boolean;
};

export const languageOptions = [
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
