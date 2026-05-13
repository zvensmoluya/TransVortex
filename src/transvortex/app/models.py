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
    max_batch_lines: int = 50


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


DEFAULT_TRANSLATION_STYLE_PROMPT = FALLBACK_TRANSLATION_STYLE_PROMPT


@dataclass
class RefusalDetectionConfig:
    enabled: bool = True


@dataclass
class RepairConfig:
    enabled: bool = True
    max_attempts: int = 2


@dataclass
class TranslationConfig:
    chunk_lines: int = 40
    context_before_lines: int = 20
    context_after_lines: int = 10
    style_preset: str = "subtitle_natural"
    style_prompt: str = DEFAULT_TRANSLATION_STYLE_PROMPT
    system_prompt: str = ""
    refusal_detection: RefusalDetectionConfig = field(default_factory=RefusalDetectionConfig)
    repair: RepairConfig = field(default_factory=RepairConfig)


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
class SubtitleConfig:
    quality: SubtitleQualityConfig = field(default_factory=SubtitleQualityConfig)
    compression: SubtitleCompressionConfig = field(default_factory=SubtitleCompressionConfig)


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
    system_prompt: str = ""


@dataclass
class MemoryMergeConfig:
    auto_confirm_high_confidence: bool = False
    conflict_policy: str = "record"


@dataclass
class MemoryConsistencyCheckConfig:
    enabled: bool = True


@dataclass
class MemoryConfig:
    enabled: bool = False
    mode: str = "balanced"
    bootstrap: MemoryBootstrapConfig = field(default_factory=MemoryBootstrapConfig)
    inject: MemoryInjectConfig = field(default_factory=MemoryInjectConfig)
    patch: MemoryPatchConfig = field(default_factory=MemoryPatchConfig)
    merge: MemoryMergeConfig = field(default_factory=MemoryMergeConfig)
    consistency_check: MemoryConsistencyCheckConfig = field(default_factory=MemoryConsistencyCheckConfig)


@dataclass
class PipelineConfig:
    artifacts_dir: Path
    chunk_seconds: int = 60
    chunk_overlap_seconds: int = 1
    translation_batch_size: int = 40
    translation: TranslationConfig = field(default_factory=TranslationConfig)
    subtitle: SubtitleConfig = field(default_factory=SubtitleConfig)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    output_format: str = "srt"
    subtitle_ass_style: AssStyleConfig = field(default_factory=AssStyleConfig)
    default_concurrency: int = 8
    timeout_seconds: int = 30
    retry: int = 3
    max_cps: int = 20
    asr_model_size: str = "small"
    asr_device: str = "auto"
    asr_compute_type: str = "int8"
    asr_mode: str = "local"
    asr_provider: str = ""
    asr_provider_model: str = ""
    asr_cloud_base_url: str = "https://api.openai.com"
    asr_cloud_endpoint: str = "/v1/audio/transcriptions"
    asr_cloud_model: str = "whisper-1"
    asr_cloud_env_key: str = "TVX_MODEL_API_KEY"
    asr_cloud_timeout_seconds: int = 120


@dataclass
class AppConfig:
    pipeline: PipelineConfig
    providers: dict[str, ProviderConfig]
    routing: RoutingConfig


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


@dataclass
class NormalizedRequest:
    model: str
    lines: list[str]
    source_lang: str
    target_lang: str
    context_before: list[str] = field(default_factory=list)
    context_after: list[str] = field(default_factory=list)
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
