from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any, Literal


ASR_CONFIG_SCHEMA_VERSION = 2
ASR_PLAN_SCHEMA_VERSION = 2

CapabilityKnowledge = Literal[
    "verified",
    "reported",
    "inferred",
    "unknown",
    "not_applicable",
]
AsrEngineKind = Literal[
    "faster_whisper_worker",
    "funasr_service",
    "openai_transcription",
    "openrouter_asr",
]


@dataclass(frozen=True)
class CredentialBinding:
    binding_id: str
    secret_ref: str
    env_fallback: str = ""


@dataclass(frozen=True)
class HttpEndpointSpec:
    scope: Literal["loopback", "remote"]
    base_url: str
    path: str
    credential: CredentialBinding | None = None
    proxy: Literal["system", "direct", "local_proxy"] = "system"
    proxy_port: int = 0
    headers: dict[str, str] = field(default_factory=dict)
    http2: bool = True


@dataclass(frozen=True)
class ResourceBinding:
    source: Literal["managed", "registered"]
    id: str


@dataclass(frozen=True)
class FasterWhisperWorkerEngineSpec:
    id: str
    runtime_binding: ResourceBinding
    model_binding: ResourceBinding
    accelerator_binding: ResourceBinding | None = None
    device_preference: Literal["auto", "cpu", "cuda"] = "auto"
    compute_type_preference: str = "auto"
    adapter_version: int = 1
    kind: Literal["faster_whisper_worker"] = "faster_whisper_worker"


@dataclass(frozen=True)
class FunAsrServiceEngineSpec:
    id: str
    model: str
    endpoint: HttpEndpointSpec
    adapter_version: int = 1
    kind: Literal["funasr_service"] = "funasr_service"


@dataclass(frozen=True)
class OpenAiTranscriptionEngineSpec:
    id: str
    model: str
    endpoint: HttpEndpointSpec
    adapter_version: int = 1
    kind: Literal["openai_transcription"] = "openai_transcription"


@dataclass(frozen=True)
class OpenRouterAsrEngineSpec:
    id: str
    model: str
    endpoint: HttpEndpointSpec
    adapter_version: int = 1
    kind: Literal["openrouter_asr"] = "openrouter_asr"


AsrEngineSpec = (
    FasterWhisperWorkerEngineSpec
    | FunAsrServiceEngineSpec
    | OpenAiTranscriptionEngineSpec
    | OpenRouterAsrEngineSpec
)


@dataclass(frozen=True)
class CapabilityLimit:
    hard_max: float | None = None
    observed_safe_max: float | None = None
    knowledge: CapabilityKnowledge = "unknown"
    source: str = ""
    observed_at: str = ""


@dataclass(frozen=True)
class CapabilityEvidence:
    field: str
    source: str
    value: Any = None
    observed_at: str = ""


@dataclass(frozen=True)
class AsrAvailability:
    state: Literal["ready", "needs_action", "unavailable", "checking", "unknown"] = "unknown"
    reason_code: str = ""
    observed_at: str = ""


@dataclass(frozen=True)
class AsrAudioInputCapabilities:
    formats: tuple[str, ...] = ()
    max_duration_seconds: CapabilityLimit = field(default_factory=CapabilityLimit)
    max_upload_bytes: CapabilityLimit = field(default_factory=CapabilityLimit)
    sample_rates_hz: tuple[int, ...] = ()
    max_channels: int | None = None


@dataclass(frozen=True)
class AsrTimelineCapabilities:
    granularities: tuple[Literal["segment", "word"], ...] = ()
    confidence: bool = False
    speaker_labels: bool = False
    multichannel: bool = False


@dataclass(frozen=True)
class AsrHintCapabilities:
    language: bool = False
    prompt: bool = False
    previous_text: bool = False
    hotwords: bool = False


@dataclass(frozen=True)
class AsrRuntimeCapabilities:
    resolved_device: str = ""
    device_name: str = ""
    supported_compute_types: tuple[str, ...] = ()
    gpu_memory_total_bytes: int | None = None
    gpu_memory_free_bytes: int | None = None
    max_parallelism: CapabilityLimit = field(default_factory=CapabilityLimit)


@dataclass(frozen=True)
class AsrCapabilities:
    availability: AsrAvailability = field(default_factory=AsrAvailability)
    audio_input: AsrAudioInputCapabilities = field(default_factory=AsrAudioInputCapabilities)
    timeline: AsrTimelineCapabilities = field(default_factory=AsrTimelineCapabilities)
    hints: AsrHintCapabilities = field(default_factory=AsrHintCapabilities)
    runtime: AsrRuntimeCapabilities = field(default_factory=AsrRuntimeCapabilities)
    evidence: tuple[CapabilityEvidence, ...] = ()


@dataclass(frozen=True)
class AsrSilencePolicy:
    noise_db: float = -35.0
    minimum_seconds: float = 0.25
    cut_padding_seconds: float = 0.15
    fallback: Literal["hard_cut"] = "hard_cut"


@dataclass(frozen=True)
class AsrChunkingPolicy:
    mode: Literal["fixed", "none", "silence"] = "silence"
    window_target_seconds: float = 300.0
    window_floor_seconds: float = 12.0
    overlap_seconds: float = 5.0
    short_audio_bypass_seconds: float = 300.0
    upload_soft_limit_bytes: int | None = 24 * 1024 * 1024
    silence: AsrSilencePolicy = field(default_factory=AsrSilencePolicy)


@dataclass(frozen=True)
class AsrPreprocessingPolicy:
    trim_silence: bool = False
    noise_db: float = -35.0
    minimum_seconds: float = 0.2
    preroll_seconds: float = 0.25
    trim_trailing: bool = True
    postroll_seconds: float = 0.1
    minimum_upload_seconds: float = 0.5


@dataclass(frozen=True)
class AsrExecutionPolicy:
    concurrency_mode: Literal["fixed", "adaptive"] = "fixed"
    target_concurrency: int = 1
    minimum_concurrency: int = 1
    maximum_concurrency: int = 1
    max_inflight_audio_bytes: int = 128 * 1024 * 1024
    request_deadline_seconds: float = 300.0
    max_attempts: int = 2
    split_retry: bool = True


@dataclass(frozen=True)
class AsrDecodingPolicy:
    beam_size: int = 5
    temperature: float = 0.0
    condition_on_previous_text: bool = False


@dataclass(frozen=True)
class AsrPolicy:
    chunking: AsrChunkingPolicy = field(default_factory=AsrChunkingPolicy)
    preprocessing: AsrPreprocessingPolicy = field(default_factory=AsrPreprocessingPolicy)
    execution: AsrExecutionPolicy = field(default_factory=AsrExecutionPolicy)
    decoding: AsrDecodingPolicy = field(default_factory=AsrDecodingPolicy)


@dataclass(frozen=True)
class AsrSilenceOverrides:
    noise_db: float | None = None
    minimum_seconds: float | None = None
    cut_padding_seconds: float | None = None
    fallback: Literal["hard_cut"] | None = None


@dataclass(frozen=True)
class AsrChunkingOverrides:
    mode: Literal["fixed", "none", "silence"] | None = None
    window_target_seconds: float | None = None
    window_floor_seconds: float | None = None
    overlap_seconds: float | None = None
    short_audio_bypass_seconds: float | None = None
    upload_soft_limit_bytes: int | None = None
    silence: AsrSilenceOverrides | None = None


@dataclass(frozen=True)
class AsrPreprocessingOverrides:
    trim_silence: bool | None = None
    noise_db: float | None = None
    minimum_seconds: float | None = None
    preroll_seconds: float | None = None
    trim_trailing: bool | None = None
    postroll_seconds: float | None = None
    minimum_upload_seconds: float | None = None


@dataclass(frozen=True)
class AsrExecutionOverrides:
    concurrency_mode: Literal["fixed", "adaptive"] | None = None
    target_concurrency: int | None = None
    minimum_concurrency: int | None = None
    maximum_concurrency: int | None = None
    max_inflight_audio_bytes: int | None = None
    request_deadline_seconds: float | None = None
    max_attempts: int | None = None
    split_retry: bool | None = None


@dataclass(frozen=True)
class AsrDecodingOverrides:
    beam_size: int | None = None
    temperature: float | None = None
    condition_on_previous_text: bool | None = None


@dataclass(frozen=True)
class AsrUserOverrides:
    chunking: AsrChunkingOverrides | None = None
    preprocessing: AsrPreprocessingOverrides | None = None
    execution: AsrExecutionOverrides | None = None
    decoding: AsrDecodingOverrides | None = None


@dataclass(frozen=True)
class AsrPolicyAdjustment:
    field: str
    requested: Any
    effective: Any
    reason: str


@dataclass(frozen=True)
class AsrPolicyResolution:
    policy: AsrPolicy
    sources: dict[str, str] = field(default_factory=dict)
    adjustments: tuple[AsrPolicyAdjustment, ...] = ()


@dataclass(frozen=True)
class AudioStreamFacts:
    index: int
    codec: str
    sample_rate_hz: int | None = None
    channels: int | None = None
    bitrate: int | None = None
    language_tag: str = ""


@dataclass(frozen=True)
class CanonicalAudioFacts:
    codec: str = "pcm_s16le"
    sample_rate_hz: int = 16000
    channels: int = 1
    bytes_per_second: int = 32000


@dataclass(frozen=True)
class SilenceAnalysisFacts:
    artifact_ref: str = ""
    fingerprint: str = ""
    range_count: int = 0


@dataclass(frozen=True)
class AudioFacts:
    content_fingerprint: str
    duration_seconds: float
    encoded_size_bytes: int | None
    selected_stream: AudioStreamFacts
    canonical_audio: CanonicalAudioFacts = field(default_factory=CanonicalAudioFacts)
    silence_analysis: SilenceAnalysisFacts = field(default_factory=SilenceAnalysisFacts)


@dataclass(frozen=True)
class AsrPlanWindow:
    id: int
    source_start: float
    source_end: float
    trusted_start: float
    trusted_end: float
    estimated_upload_bytes: int
    cut_reason: str


@dataclass(frozen=True)
class AsrExecutionPlan:
    actual_concurrency: int
    request_deadline_seconds: float
    max_attempts: int
    split_retry: bool


@dataclass(frozen=True)
class AsrTimelinePlan:
    input_granularity: Literal["segment", "word"]
    strategy_id: str
    strategy_version: int


@dataclass(frozen=True)
class ResolvedAsrPlan:
    plan_id: str
    resolved_at: str
    engine: AsrEngineSpec
    capabilities: AsrCapabilities
    effective_policy: AsrPolicy
    policy_sources: dict[str, str]
    audio_facts: AudioFacts
    windows: tuple[AsrPlanWindow, ...]
    execution: AsrExecutionPlan
    timeline: AsrTimelinePlan
    adjustments: tuple[AsrPolicyAdjustment, ...] = ()
    plan_schema_version: int = ASR_PLAN_SCHEMA_VERSION


def _replace_present(instance: Any, values: Any, prefix: str, sources: dict[str, str]) -> Any:
    if values is None:
        return instance
    updates: dict[str, Any] = {}
    for name in instance.__dataclass_fields__:
        value = getattr(values, name, None)
        if value is None:
            continue
        current = getattr(instance, name)
        if hasattr(current, "__dataclass_fields__") and hasattr(value, "__dataclass_fields__"):
            updates[name] = _replace_present(current, value, f"{prefix}.{name}", sources)
        else:
            updates[name] = value
            sources[f"{prefix}.{name}"] = "override"
    return replace(instance, **updates)


def _validate_asr_policy(policy: AsrPolicy) -> None:
    chunking = policy.chunking
    if chunking.window_target_seconds <= 0:
        raise ValueError("asr policy chunking.window_target_seconds must be positive")
    if chunking.window_floor_seconds <= 0 or chunking.window_floor_seconds > chunking.window_target_seconds:
        raise ValueError("asr policy chunking.window_floor_seconds must be within the target window")
    if chunking.overlap_seconds < 0 or chunking.overlap_seconds >= chunking.window_target_seconds:
        raise ValueError("asr policy chunking.overlap_seconds must be smaller than the target window")
    if chunking.upload_soft_limit_bytes is not None and chunking.upload_soft_limit_bytes <= 0:
        raise ValueError("asr policy chunking.upload_soft_limit_bytes must be positive")
    if chunking.silence.minimum_seconds < 0:
        raise ValueError("asr policy chunking.silence.minimum_seconds cannot be negative")
    execution = policy.execution
    if execution.minimum_concurrency < 1:
        raise ValueError("asr policy execution.minimum_concurrency must be positive")
    if execution.maximum_concurrency < execution.minimum_concurrency:
        raise ValueError("asr policy execution.maximum_concurrency must not be smaller than minimum_concurrency")
    if not execution.minimum_concurrency <= execution.target_concurrency <= execution.maximum_concurrency:
        raise ValueError("asr policy execution.target_concurrency must be within the configured range")
    if execution.max_inflight_audio_bytes <= 0:
        raise ValueError("asr policy execution.max_inflight_audio_bytes must be positive")
    if execution.request_deadline_seconds <= 0:
        raise ValueError("asr policy execution.request_deadline_seconds must be positive")
    if execution.max_attempts < 1:
        raise ValueError("asr policy execution.max_attempts must be positive")
    if policy.decoding.beam_size < 1:
        raise ValueError("asr policy decoding.beam_size must be positive")
    if policy.decoding.temperature < 0:
        raise ValueError("asr policy decoding.temperature cannot be negative")


def resolve_asr_policy(
    base: AsrPolicy,
    overrides: AsrUserOverrides | None,
    capabilities: AsrCapabilities,
) -> AsrPolicyResolution:
    sources: dict[str, str] = {}
    effective = base
    if overrides is not None:
        effective = replace(
            effective,
            chunking=_replace_present(effective.chunking, overrides.chunking, "chunking", sources),
            preprocessing=_replace_present(
                effective.preprocessing,
                overrides.preprocessing,
                "preprocessing",
                sources,
            ),
            execution=_replace_present(effective.execution, overrides.execution, "execution", sources),
            decoding=_replace_present(effective.decoding, overrides.decoding, "decoding", sources),
        )
    _validate_asr_policy(effective)

    adjustments: list[AsrPolicyAdjustment] = []
    duration_cap = capabilities.audio_input.max_duration_seconds.hard_max
    if duration_cap is not None and effective.chunking.window_target_seconds > duration_cap:
        if overrides and overrides.chunking and overrides.chunking.window_target_seconds is not None:
            raise ValueError("asr override chunking.window_target_seconds exceeds the engine capability")
        requested = effective.chunking.window_target_seconds
        floor = min(effective.chunking.window_floor_seconds, duration_cap)
        overlap = min(effective.chunking.overlap_seconds, max(duration_cap - 0.1, 0.0))
        effective = replace(
            effective,
            chunking=replace(
                effective.chunking,
                window_target_seconds=duration_cap,
                window_floor_seconds=floor,
                overlap_seconds=overlap,
            ),
        )
        adjustments.append(
            AsrPolicyAdjustment(
                field="chunking.window_target_seconds",
                requested=requested,
                effective=duration_cap,
                reason="engine_duration_limit",
            )
        )
        sources["chunking.window_target_seconds"] = "capability"

    upload_cap = capabilities.audio_input.max_upload_bytes.hard_max
    upload_soft_limit = effective.chunking.upload_soft_limit_bytes
    if upload_cap is not None and (upload_soft_limit is None or upload_soft_limit > upload_cap):
        if overrides and overrides.chunking and overrides.chunking.upload_soft_limit_bytes is not None:
            raise ValueError("asr override chunking.upload_soft_limit_bytes exceeds the engine capability")
        effective_upload_cap = int(upload_cap)
        effective = replace(
            effective,
            chunking=replace(effective.chunking, upload_soft_limit_bytes=effective_upload_cap),
        )
        adjustments.append(
            AsrPolicyAdjustment(
                field="chunking.upload_soft_limit_bytes",
                requested=upload_soft_limit,
                effective=effective_upload_cap,
                reason="engine_upload_limit",
            )
        )
        sources["chunking.upload_soft_limit_bytes"] = "capability"

    parallelism_cap = capabilities.runtime.max_parallelism.hard_max
    if parallelism_cap is not None and effective.execution.maximum_concurrency > parallelism_cap:
        if overrides and overrides.execution and (
            overrides.execution.maximum_concurrency is not None
            or overrides.execution.target_concurrency is not None
        ):
            raise ValueError("asr execution override exceeds the runtime parallelism capability")
        requested = effective.execution.maximum_concurrency
        maximum = max(int(parallelism_cap), 1)
        minimum = min(effective.execution.minimum_concurrency, maximum)
        target = min(effective.execution.target_concurrency, maximum)
        effective = replace(
            effective,
            execution=replace(
                effective.execution,
                minimum_concurrency=minimum,
                target_concurrency=max(target, minimum),
                maximum_concurrency=maximum,
            ),
        )
        adjustments.append(
            AsrPolicyAdjustment(
                field="execution.maximum_concurrency",
                requested=requested,
                effective=maximum,
                reason="runtime_parallelism_limit",
            )
        )
        sources["execution.maximum_concurrency"] = "capability"

    _validate_asr_policy(effective)
    return AsrPolicyResolution(
        policy=effective,
        sources=sources,
        adjustments=tuple(adjustments),
    )
