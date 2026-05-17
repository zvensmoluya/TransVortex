from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..prompts import FALLBACK_TRANSLATION_STYLE_PROMPT


@dataclass
class AuthConfig:
    type: str = "bearer"  # bearer | header | query
    header_name: str = "Authorization"
    query_name: str = "key"
    prefix: str = "Bearer "


@dataclass
class EndpointConfig:
    path_template: str = ""
    method: str = "POST"


@dataclass
class CapabilityConfig:
    supports_system_prompt: bool = True
    supports_temperature: bool = True
    supports_json_mode: bool = False
    max_batch_lines: int = 200


@dataclass
class MappingConfig:
    request: dict[str, Any] = field(default_factory=dict)
    response: dict[str, Any] = field(default_factory=dict)


@dataclass
class ModelListConfig:
    path_template: str = ""
    method: str = "GET"
    response_paths: list[str] = field(default_factory=list)


@dataclass
class ProviderLimits:
    concurrency: int = 8
    timeout_seconds: int = 30
    retry: int = 3
    connect_timeout_seconds: float = 10.0
    read_timeout_seconds: float = 30.0
    write_timeout_seconds: float = 30.0
    pool_timeout_seconds: float = 5.0
    max_connections: int = 20
    max_keepalive_connections: int = 10
    http2: bool = True
    streaming_enabled: bool = True


@dataclass
class ProviderConfig:
    name: str
    api_type: str
    base_url: str
    env_key: str
    models: list[str]
    credential_id: str = ""
    credential_root_dir: Path | None = None
    compat_mode: str = ""
    auth: AuthConfig = field(default_factory=AuthConfig)
    endpoint: EndpointConfig = field(default_factory=EndpointConfig)
    mapping: MappingConfig = field(default_factory=MappingConfig)
    extra_headers: dict[str, str] = field(default_factory=dict)
    model_list: ModelListConfig = field(default_factory=ModelListConfig)
    capabilities: CapabilityConfig = field(default_factory=CapabilityConfig)
    limits: ProviderLimits = field(default_factory=ProviderLimits)


@dataclass
class RouteTarget:
    provider: str
    model: str


@dataclass
class RoutingConfig:
    primary: RouteTarget
    fallback: list[RouteTarget] = field(default_factory=list)


@dataclass
class RoutingProfile:
    id: str
    name: str
    primary: RouteTarget
    fallback: list[RouteTarget] = field(default_factory=list)


DEFAULT_TRANSLATION_STYLE_PROMPT = FALLBACK_TRANSLATION_STYLE_PROMPT


@dataclass
class RefusalDetectionConfig:
    enabled: bool = True


@dataclass
class RepairConfig:
    enabled: bool = True
    max_attempts: int = 2


@dataclass
class AsrUncertaintyHintsConfig:
    enabled: bool = False


@dataclass
class AsrSilenceChunkingConfig:
    noise_db: float = -35.0
    min_silence_seconds: float = 0.25
    cut_padding_seconds: float = 0.15
    fallback_mode: str = "hard_cut"


@dataclass
class AsrChunkingConfig:
    mode: str = "silence"  # auto | fixed | none | silence
    window_seconds: int = 300
    max_window_seconds: int = 120
    min_window_seconds: int = 12
    overlap_seconds: int = 5
    short_audio_seconds: int = 300
    max_upload_mb: float = 24.0
    silence: AsrSilenceChunkingConfig = field(default_factory=AsrSilenceChunkingConfig)
    fuzzy_dedupe: bool = True


@dataclass
class AsrExecutionConfig:
    cloud_concurrency: int = 8
    adaptive_concurrency: bool = True
    min_cloud_concurrency: int = 1
    max_cloud_concurrency: int = 8
    max_inflight_upload_mb: float = 128.0


@dataclass
class AsrLocalConfig:
    model_size: str = "small"
    device: str = "auto"
    compute_type: str = "int8"
    max_initial_timestamp: float = 30.0


@dataclass
class AsrCloudConfig:
    base_url: str = "https://api.openai.com"
    endpoint: str = "/v1/audio/transcriptions"
    model: str = "whisper-1"
    env_key: str = "TVX_MODEL_API_KEY"
    credential_id: str = "TVX_MODEL_API_KEY"
    timeout_seconds: int = 300


@dataclass
class AsrProviderRequestConfig:
    response_format: str = "verbose_json"
    temperature: float = 0.0
    timestamp_granularities: list[str] = field(default_factory=lambda: ["segment"])
    include: list[str] = field(default_factory=list)
    extra_form_fields: dict[str, Any] = field(default_factory=dict)
    array_format: str = "brackets"  # repeat | brackets


@dataclass
class AsrPromptConfig:
    enabled: bool = True
    text: str = ""
    include_previous_text: bool = False
    max_chars: int = 800


@dataclass
class AsrProviderConfig:
    name: str
    protocol: str = "openai_transcriptions"
    base_url: str = "https://api.openai.com"
    endpoint: str = "/v1/audio/transcriptions"
    model: str = "whisper-1"
    env_key: str = "TVX_MODEL_API_KEY"
    credential_id: str = "TVX_MODEL_API_KEY"
    timeout_seconds: int = 300
    retry: int = 2
    request: AsrProviderRequestConfig = field(default_factory=AsrProviderRequestConfig)


@dataclass
class AsrCloudTrimSilenceConfig:
    enabled: bool = True
    backend: str = "ffmpeg_silencedetect"
    noise_db: float = -35.0
    min_silence_seconds: float = 0.2
    keep_preroll_seconds: float = 0.25
    trim_trailing: bool = True
    keep_postroll_seconds: float = 0.1
    min_upload_seconds: float = 0.5


@dataclass
class AsrPreprocessingConfig:
    cloud_trim_silence: AsrCloudTrimSilenceConfig = field(default_factory=AsrCloudTrimSilenceConfig)


@dataclass
class TranslationBatchingConfig:
    mode: str = "adaptive"  # fixed | adaptive
    min_chunk_lines: int = 20
    grow_after_successes: int = 3


@dataclass
class TranslationConfig:
    chunk_lines: int = 120
    context_before_lines: int = 40
    context_after_lines: int = 20
    style_preset: str = "subtitle_natural"
    style_prompt: str = DEFAULT_TRANSLATION_STYLE_PROMPT
    system_prompt: str = ""
    refusal_detection: RefusalDetectionConfig = field(default_factory=RefusalDetectionConfig)
    repair: RepairConfig = field(default_factory=RepairConfig)
    asr_uncertainty_hints: AsrUncertaintyHintsConfig = field(default_factory=AsrUncertaintyHintsConfig)
    batching: TranslationBatchingConfig = field(default_factory=TranslationBatchingConfig)


@dataclass
class AssStyleConfig:
    font_name: str = "Microsoft YaHei"
    font_size: int = 42
    primary_color: str = "&H00FFFFFF"
    outline_color: str = "&H00000000"
    back_color: str = "&H64000000"
    outline: int = 2
    shadow: int = 1
    margin_v: int = 48
    bilingual_order: str = "target_source"
    source_font_size: int = 30
    source_primary_color: str = "&H00B8B8B8"
    source_margin_v: int = 104


@dataclass
class SubtitleQualityConfig:
    enabled: bool = True
    mode: str = "balanced"  # off | conservative | balanced
    target_cps: int = 17
    hard_max_cps: int = 22
    max_line_width: int = 42
    max_lines: int = 2
    min_duration_seconds: float = 0.8
    max_duration_seconds: float = 6.0
    min_gap_seconds: float = 0.04
    merge_short_segments: bool = True
    adjust_timing: bool = True


@dataclass
class SubtitleCompressionConfig:
    enabled: bool = False
    max_attempts: int = 1


@dataclass
class SubtitleReflowConfig:
    enabled: bool = False
    trigger: str = "fail_only"
    batch_windows: int = 10
    max_windows: int = 30
    max_window_segments: int = 10
    context_before_segments: int = 8
    context_after_segments: int = 8
    max_input_chars: int = 60000
    max_output_replacements: int = 80
    memory: bool = True
    max_attempts: int = 2
    allow_merge: bool = True
    allow_drop: bool = False


@dataclass
class SubtitleConfig:
    quality: SubtitleQualityConfig = field(default_factory=SubtitleQualityConfig)
    compression: SubtitleCompressionConfig = field(default_factory=SubtitleCompressionConfig)
    reflow: SubtitleReflowConfig = field(default_factory=SubtitleReflowConfig)


@dataclass
class MemoryBootstrapConfig:
    enabled: bool = False
    max_candidates: int = 80


@dataclass
class MemoryInjectConfig:
    locked: bool = True
    confirmed: bool = True
    proposed: bool = True
    strategy: str = "balanced"
    max_entries_per_chunk: int = 30


@dataclass
class MemoryPatchConfig:
    enabled: bool = True
    after_each_window: bool = True
    window_chunks: int = 8
    system_prompt: str = ""


@dataclass
class MemoryChunkingConfig:
    min_initial_chunk_lines: int = 80
    max_initial_chunks: int = 24


@dataclass
class MemoryMergeConfig:
    auto_confirm_high_confidence: bool = False
    conflict_policy: str = "record"


@dataclass
class MemoryConsistencyCheckConfig:
    enabled: bool = True


@dataclass
class MemoryPresetRef:
    id: str
    override_status: str = ""


@dataclass
class MemoryConfig:
    enabled: bool = False
    mode: str = "balanced"
    presets: list[MemoryPresetRef] = field(default_factory=list)
    bootstrap: MemoryBootstrapConfig = field(default_factory=MemoryBootstrapConfig)
    chunking: MemoryChunkingConfig = field(default_factory=MemoryChunkingConfig)
    inject: MemoryInjectConfig = field(default_factory=MemoryInjectConfig)
    patch: MemoryPatchConfig = field(default_factory=MemoryPatchConfig)
    merge: MemoryMergeConfig = field(default_factory=MemoryMergeConfig)
    consistency_check: MemoryConsistencyCheckConfig = field(default_factory=MemoryConsistencyCheckConfig)


@dataclass
class PipelineConfig:
    artifacts_dir: Path
    chunk_seconds: int = 60
    chunk_overlap_seconds: int = 1
    translation_batch_size: int = 120
    translation: TranslationConfig = field(default_factory=TranslationConfig)
    subtitle: SubtitleConfig = field(default_factory=SubtitleConfig)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    output_format: str = "srt"
    subtitle_ass_style: AssStyleConfig = field(default_factory=AssStyleConfig)
    default_concurrency: int = 8
    timeout_seconds: int = 30
    retry: int = 3
    max_cps: int = 20
    asr_mode: str = "local"
    asr_provider: str = ""
    asr_local: AsrLocalConfig = field(default_factory=AsrLocalConfig)
    asr_cloud: AsrCloudConfig = field(default_factory=AsrCloudConfig)
    asr_audio_track: str = "auto"
    asr_chunking: AsrChunkingConfig = field(default_factory=AsrChunkingConfig)
    asr_execution: AsrExecutionConfig = field(default_factory=AsrExecutionConfig)
    asr_preprocessing: AsrPreprocessingConfig = field(default_factory=AsrPreprocessingConfig)
    asr_prompt: AsrPromptConfig = field(default_factory=AsrPromptConfig)
    source_mode: str = "auto"
    subtitle_track: str = "auto"


@dataclass
class AppConfig:
    pipeline: PipelineConfig
    providers: dict[str, ProviderConfig]
    routing: RoutingConfig
    routing_profiles: list[RoutingProfile] = field(default_factory=list)
    active_routing_profile: str = ""
    routing_profile_next_seq: int = 1
    asr_providers: dict[str, AsrProviderConfig] = field(default_factory=dict)


@dataclass
class Segment:
    id: int
    start: float
    end: float
    text_src: str
    text_tgt: str | None = None
    confidence: float | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class Chunk:
    chunk_id: str
    segment_ids: list[int]
    lines: list[str]
    context_before: list[str] = field(default_factory=list)
    context_after: list[str] = field(default_factory=list)
    asr_uncertain_ids: list[int] = field(default_factory=list)


@dataclass
class NormalizedRequest:
    model: str
    lines: list[str]
    source_lang: str
    target_lang: str
    context_before: list[str] = field(default_factory=list)
    context_after: list[str] = field(default_factory=list)
    asr_uncertain_ids: list[int] = field(default_factory=list)
    include_asr_uncertainty_hints: bool = False
    style_prompt: str = ""
    memory_prompt: str = ""
    prompt_mode: str = "translate"
    repair_reason: str = ""
    bad_translation: str = ""
    temperature: float = 0.1
    system_prompt: str = ""


@dataclass
class NormalizedResponse:
    numbered_lines: list[str]
    raw_text: str
    usage: dict[str, Any] = field(default_factory=dict)
    provider_meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class TaskRecord:
    task_id: str
    input_file: str
    source_lang: str
    target_lang: str
    bilingual: bool
    status: str
    created_at: str
    updated_at: str
    output_path: str | None = None
    output_paths: dict[str, str] = field(default_factory=dict)
    error: str | None = None
    error_info: dict[str, Any] | None = None
    settings: dict[str, Any] = field(default_factory=dict)
