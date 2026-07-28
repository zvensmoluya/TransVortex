from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import TYPE_CHECKING, Any

from ..prompts import FALLBACK_TRANSLATION_STYLE_PROMPT

if TYPE_CHECKING:
    from ..asr_domain import (
        AsrCapabilities,
        AsrEngineSpec,
        AsrPolicyResolution,
        AsrUserOverrides,
    )


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
    max_context_tokens: int = 0
    max_input_tokens: int = 0
    max_output_tokens: int = 0
    recommended_output_tokens: int = 0
    output_token_param: str = ""
    reasoning_effort_param: str = ""
    reasoning_efforts: list[str] = field(default_factory=list)


@dataclass
class ModelConfig:
    max_batch_lines: int = 0
    max_context_tokens: int = 0
    max_input_tokens: int = 0
    max_output_tokens: int = 0
    recommended_output_tokens: int = 0
    reasoning_effort: str = ""


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


@dataclass(frozen=True)
class NetworkConfig:
    mode: str = "system"  # system | direct | local_proxy
    proxy_port: int = 0


@dataclass
class ProviderConfig:
    name: str
    api_type: str
    base_url: str
    env_key: str
    models: list[str]
    model_configs: dict[str, ModelConfig] = field(default_factory=dict)
    catalog_model_configs: dict[str, ModelConfig] = field(default_factory=dict)
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
    network: NetworkConfig = field(default_factory=NetworkConfig)

    def model_config(self, model: str) -> ModelConfig:
        model_id = str(model or "").strip()
        explicit = self.model_configs.get(model_id, ModelConfig())
        catalog = self.catalog_model_configs.get(model_id, ModelConfig())

        def effective_limit(explicit_value: int, catalog_value: int, provider_value: int) -> int:
            """Resolve a model limit without letting catalog data widen a channel cap.

            A model-level user value is an explicit deployment override. Otherwise
            catalog and provider values are both limits, so the lower known value
            wins. Zero means unknown rather than unlimited.
            """

            if int(explicit_value or 0) > 0:
                return int(explicit_value)
            known = [
                int(value)
                for value in (catalog_value, provider_value)
                if int(value or 0) > 0
            ]
            return min(known) if known else 0

        resolved = ModelConfig(
            max_batch_lines=effective_limit(
                explicit.max_batch_lines,
                catalog.max_batch_lines,
                self.capabilities.max_batch_lines,
            ),
            max_context_tokens=effective_limit(
                explicit.max_context_tokens,
                catalog.max_context_tokens,
                self.capabilities.max_context_tokens,
            ),
            max_input_tokens=effective_limit(
                explicit.max_input_tokens,
                catalog.max_input_tokens,
                self.capabilities.max_input_tokens,
            ),
            max_output_tokens=effective_limit(
                explicit.max_output_tokens,
                catalog.max_output_tokens,
                self.capabilities.max_output_tokens,
            ),
            recommended_output_tokens=effective_limit(
                explicit.recommended_output_tokens,
                catalog.recommended_output_tokens,
                self.capabilities.recommended_output_tokens,
            ),
            reasoning_effort=(explicit.reasoning_effort or catalog.reasoning_effort).strip(),
        )
        if (
            int(resolved.max_context_tokens or 0) > 0
            and int(resolved.max_input_tokens or 0) > int(resolved.max_context_tokens)
        ):
            resolved = replace(resolved, max_input_tokens=resolved.max_context_tokens)
        return resolved

    def capabilities_for_model(self, model: str) -> CapabilityConfig:
        model_config = self.model_config(model)
        max_output_tokens = (
            model_config.max_output_tokens
            if int(model_config.max_output_tokens or 0) > 0
            else self.capabilities.max_output_tokens
        )
        recommended_output_tokens = (
            model_config.recommended_output_tokens
            if int(model_config.recommended_output_tokens or 0) > 0
            else self.capabilities.recommended_output_tokens
        )
        if max_output_tokens > 0 and recommended_output_tokens > max_output_tokens:
            recommended_output_tokens = max_output_tokens
        return replace(
            self.capabilities,
            max_batch_lines=(
                model_config.max_batch_lines
                if int(model_config.max_batch_lines or 0) > 0
                else self.capabilities.max_batch_lines
            ),
            max_context_tokens=(
                model_config.max_context_tokens
                if int(model_config.max_context_tokens or 0) > 0
                else self.capabilities.max_context_tokens
            ),
            max_input_tokens=(
                model_config.max_input_tokens
                if int(model_config.max_input_tokens or 0) > 0
                else self.capabilities.max_input_tokens
            ),
            max_output_tokens=max_output_tokens,
            recommended_output_tokens=recommended_output_tokens,
        )


ROUTE_REASONING_EFFORTS = frozenset(
    {
        "auto",
        "service_default",
        "none",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "max",
    }
)


def normalize_route_reasoning_effort(value: Any) -> str:
    normalized = str(value or "auto").strip().lower()
    if normalized not in ROUTE_REASONING_EFFORTS:
        raise ValueError(f"invalid route reasoning_effort: {normalized}")
    return normalized


@dataclass
class RouteTarget:
    provider: str
    model: str
    reasoning_effort: str = "auto"


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
    concurrency: int = 1
    adaptive_concurrency: bool = False
    min_concurrency: int = 1
    max_concurrency: int = 1
    max_inflight_upload_mb: float = 128.0
    timeout_seconds: int = 300
    retry: int = 2


@dataclass
class AsrLocalConfig:
    model_size: str = "large-v3"
    model_source: str = "managed"  # managed | external
    model_path: str = ""
    managed_model_size: str = ""
    external_model_id: str = ""
    external_model_path: str = ""
    device: str = "auto"
    compute_type: str = "auto"
    max_initial_timestamp: float = 30.0
    beam_size: int = 5
    temperature: float = 0.0
    condition_on_previous_text: bool = False
    hotwords: str = ""


@dataclass
class AsrRuntimeConfig:
    source: str = "inprocess"  # inprocess | managed | external
    id: str = ""


@dataclass
class AsrAcceleratorConfig:
    source: str = "managed"  # managed | external
    id: str = "nvidia-cuda12"


@dataclass
class AsrAuthConfig:
    type: str = "bearer"  # none | bearer
    env_key: str = "TVX_MODEL_API_KEY"
    credential_id: str = "TVX_MODEL_API_KEY"


@dataclass
class AsrProviderRequestConfig:
    response_format: str = "verbose_json"
    temperature: float = 0.0
    timestamp_granularities: list[str] = field(default_factory=lambda: ["segment"])
    include: list[str] = field(default_factory=list)
    extra_form_fields: dict[str, Any] = field(default_factory=dict)
    extra_json_fields: dict[str, Any] = field(default_factory=dict)
    provider_options: dict[str, Any] = field(default_factory=dict)
    array_format: str = "brackets"  # repeat | brackets
    send_response_format: bool = True
    send_temperature: bool = True
    send_timestamp_granularities: bool = True
    send_language: bool = True
    send_prompt: bool = True
    language_field: str = "language"
    prompt_field: str = "prompt"


@dataclass
class AsrPromptProfile:
    id: str = ""
    name: str = ""
    scope: str = "project"
    version: int = 1
    path: str = ""
    include_previous_text: bool = False
    max_chars: int = 800
    text: str = ""


@dataclass
class AsrPromptConfig:
    enabled: bool = True
    text: str = ""
    include_previous_text: bool = False
    max_chars: int = 800
    active_profile: str = ""
    profiles: list[AsrPromptProfile] = field(default_factory=list)


@dataclass
class AsrProviderConfig:
    name: str
    kind: str = "remote"  # local_inprocess | local_worker | local_server | remote
    protocol: str = "openai_transcriptions"
    base_url: str = "https://api.openai.com/v1"
    endpoint: str = "/v1/audio/transcriptions"
    model: str = "whisper-1"
    auth: AsrAuthConfig = field(default_factory=AsrAuthConfig)
    local: AsrLocalConfig = field(default_factory=AsrLocalConfig)
    runtime: AsrRuntimeConfig = field(default_factory=AsrRuntimeConfig)
    accelerator: AsrAcceleratorConfig = field(default_factory=AsrAcceleratorConfig)
    execution: AsrExecutionConfig = field(default_factory=AsrExecutionConfig)
    chunking: AsrChunkingConfig = field(default_factory=AsrChunkingConfig)
    preprocessing: "AsrPreprocessingConfig" = field(default_factory=lambda: AsrPreprocessingConfig())
    http2: bool = True
    extra_headers: dict[str, str] = field(default_factory=dict)
    request: AsrProviderRequestConfig = field(default_factory=AsrProviderRequestConfig)
    network: NetworkConfig = field(default_factory=NetworkConfig)

    @property
    def env_key(self) -> str:
        return self.auth.env_key

    @property
    def credential_id(self) -> str:
        return self.auth.credential_id

    @property
    def timeout_seconds(self) -> int:
        return self.execution.timeout_seconds

    @property
    def retry(self) -> int:
        return self.execution.retry


@dataclass
class AsrTrimSilenceConfig:
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
    trim_silence: AsrTrimSilenceConfig = field(default_factory=AsrTrimSilenceConfig)


@dataclass
class TranslationBatchingConfig:
    mode: str = "adaptive"  # fixed | adaptive
    min_chunk_lines: int = 20


@dataclass
class TranslationChunkingConfig:
    mode: str = "capacity_aware"
    min_chunk_lines: int = 120
    target_chunk_lines: int = 400
    max_chunk_lines: int = 900
    boundary_window_lines: int = 80
    soft_boundary: bool = True
    target_output_tokens: int = 0
    hard_output_tokens: int = 0
    input_safety_ratio: float = 0.85
    prompt_overhead_tokens: int = 1200


@dataclass
class TranslationExperimentLoggingConfig:
    enabled: bool = False
    save_raw_text: bool = True
    save_metrics: bool = True
    label: str = ""


@dataclass
class TranslationConfig:
    chunk_lines: int = 120
    context_before_lines: int = 80
    context_after_lines: int = 40
    style_preset: str = "subtitle_natural"
    style_prompt: str = DEFAULT_TRANSLATION_STYLE_PROMPT
    system_prompt: str = ""
    refusal_detection: RefusalDetectionConfig = field(default_factory=RefusalDetectionConfig)
    repair: RepairConfig = field(default_factory=RepairConfig)
    asr_uncertainty_hints: AsrUncertaintyHintsConfig = field(default_factory=AsrUncertaintyHintsConfig)
    chunking: TranslationChunkingConfig = field(default_factory=TranslationChunkingConfig)
    batching: TranslationBatchingConfig = field(default_factory=TranslationBatchingConfig)
    experiment_logging: TranslationExperimentLoggingConfig = field(default_factory=TranslationExperimentLoggingConfig)


@dataclass
class AssStyleConfig:
    preset: str = "cinematic"
    play_res_x: int = 1920
    play_res_y: int = 1080
    font_name: str = "Noto Sans SC"
    font_fallbacks: list[str] = field(
        default_factory=lambda: [
            "Microsoft YaHei",
            "Microsoft YaHei UI",
            "Source Han Sans SC",
            "PingFang SC",
            "Hiragino Sans GB",
            "Yu Gothic",
            "Arial Unicode MS",
            "sans-serif",
        ]
    )
    font_size: int = 39
    bold: int = 0
    primary_color: str = "&H00F6F1EA"
    secondary_color: str = "&H000000FF"
    outline_color: str = "&H8A000000"
    back_color: str = "&H82000000"
    outline: float = 1.35
    shadow: float = 0.18
    border_style: int = 1
    margin_l: int = 120
    margin_r: int = 120
    margin_v: int = 76
    safe_margin_x: int = 96
    safe_margin_y: int = 54
    bilingual_order: str = "target_source"
    max_target_lines: int = 2
    max_source_lines: int = 2
    target_max_width: int = 48
    source_max_width: int = 58
    hard_max_width: int = 64
    prefer_single_line: bool = True
    bilingual_gap: int = 12
    line_spacing: float = 1.08
    source_font_name: str = "Yu Gothic"
    source_font_size: int = 25
    source_bold: int = 0
    source_primary_color: str = "&H00D2CBC2"
    source_outline_color: str = "&H96000000"
    source_back_color: str = "&H84000000"
    source_outline: float = 1.05
    source_shadow: float = 0.14
    source_margin_v: int = 128
    font_file: str = ""


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
    merge_short_segments: bool = False
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
    enabled: bool = True
    mode: str = "whole_document"
    max_candidates: int = 120
    system_prompt: str = ""
    pipeline: str = "staged"
    critic_enabled: bool = False


@dataclass
class MemoryInjectConfig:
    enabled: bool = True
    locked: bool = True
    confirmed: bool = True
    proposed: bool = True
    intensity: str = "high"
    max_prompt_tokens: int = 2400
    max_notes_chars_per_entry: int = 60


@dataclass
class MemoryPatchConfig:
    enabled: bool = False
    mode: str = "serial"
    window_chunks: int = 3
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
    enabled: bool = True
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
    cache_dir: Path | None = None
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
    asr_provider: str = "faster_whisper_large_v3"
    asr_audio_track: str = "auto"
    asr_prompt: AsrPromptConfig = field(default_factory=AsrPromptConfig)
    source_mode: str = "auto"
    subtitle_track: str = "auto"


@dataclass
class AppConfig:
    pipeline: PipelineConfig
    providers: dict[str, ProviderConfig]
    routing: RoutingConfig
    network: NetworkConfig = field(default_factory=NetworkConfig)
    routing_profiles: list[RoutingProfile] = field(default_factory=list)
    active_routing_profile: str = ""
    routing_profile_next_seq: int = 1
    asr_providers: dict[str, AsrProviderConfig] = field(default_factory=dict)
    asr_engine_specs: dict[str, AsrEngineSpec] = field(default_factory=dict)
    asr_user_overrides: dict[str, AsrUserOverrides] = field(default_factory=dict)
    asr_capabilities: dict[str, AsrCapabilities] = field(default_factory=dict)
    asr_policy_resolutions: dict[str, AsrPolicyResolution] = field(default_factory=dict)


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
    meta: dict[str, Any] = field(default_factory=dict)


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
    protocol_recovery_hint: str = ""
    adaptive_context_hint: str = ""
    reasoning_effort: str = "auto"
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
