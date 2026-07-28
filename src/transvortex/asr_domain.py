from __future__ import annotations

import math
from dataclasses import dataclass, field, replace
from typing import Any, Literal


ASR_CONFIG_SCHEMA_VERSION = 2
ASR_PLAN_SCHEMA_VERSION = 4
ASR_RETRY_SCHEMA_VERSION = 2

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
    segment_id: str
    segment_index: int
    artifact_path: str
    content_sha256: str
    encoded_size_bytes: int
    source_start: float
    source_end: float
    trusted_start: float
    trusted_end: float
    estimated_upload_bytes: int
    cut_reason: str


@dataclass(frozen=True)
class AsrRetryParent:
    segment_id: str
    segment_index: int
    content_sha256: str
    source_start: float
    source_end: float
    trusted_start: float
    trusted_end: float


@dataclass(frozen=True)
class AsrSplitRetryStrategy:
    strategy_id: str
    strategy_version: int
    mode: Literal["fixed"]
    window_seconds: float
    minimum_window_seconds: float
    overlap_seconds: float
    max_upload_mb: float | None


@dataclass(frozen=True)
class AsrRetryDecision:
    decision_id: str
    created_at: str
    base_plan_id: str
    parent: AsrRetryParent
    strategy: AsrSplitRetryStrategy
    retry_schema_version: int = ASR_RETRY_SCHEMA_VERSION


@dataclass(frozen=True)
class ResolvedAsrRetryPlan:
    retry_plan_id: str
    resolved_at: str
    decision_id: str
    windows: tuple[AsrPlanWindow, ...]
    retry_schema_version: int = ASR_RETRY_SCHEMA_VERSION


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


def _finite_policy_number(value: Any, *, field_name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise ValueError(f"asr policy {field_name} must be a finite number")
    return float(value)


def _policy_integer(value: Any, *, field_name: str, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        qualifier = "non-negative" if minimum == 0 else "positive"
        raise ValueError(f"asr policy {field_name} must be a {qualifier} integer")
    return value


def _duration_capability_value(limit: CapabilityLimit, *, field_name: str) -> float | None:
    value = limit.hard_max
    if value is None:
        return None
    parsed = _finite_policy_number(value, field_name=field_name)
    if parsed <= 0:
        raise ValueError(f"asr capability {field_name} must be positive")
    return parsed


def _integer_capability_value(limit: CapabilityLimit, *, field_name: str) -> int | None:
    value = limit.hard_max
    if value is None:
        return None
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or not float(value).is_integer()
        or int(value) < 1
    ):
        raise ValueError(f"asr capability {field_name} must be a positive integer")
    return int(value)


def _validate_asr_policy(policy: AsrPolicy) -> None:
    chunking = policy.chunking
    _finite_policy_number(chunking.window_target_seconds, field_name="chunking.window_target_seconds")
    _finite_policy_number(chunking.window_floor_seconds, field_name="chunking.window_floor_seconds")
    _finite_policy_number(chunking.overlap_seconds, field_name="chunking.overlap_seconds")
    if chunking.window_target_seconds <= 0:
        raise ValueError("asr policy chunking.window_target_seconds must be positive")
    if chunking.window_floor_seconds <= 0 or chunking.window_floor_seconds > chunking.window_target_seconds:
        raise ValueError("asr policy chunking.window_floor_seconds must be within the target window")
    if chunking.overlap_seconds < 0 or chunking.overlap_seconds >= chunking.window_target_seconds:
        raise ValueError("asr policy chunking.overlap_seconds must be smaller than the target window")
    if chunking.upload_soft_limit_bytes is not None:
        _policy_integer(
            chunking.upload_soft_limit_bytes,
            field_name="chunking.upload_soft_limit_bytes",
            minimum=1,
        )
    _finite_policy_number(chunking.silence.noise_db, field_name="chunking.silence.noise_db")
    _finite_policy_number(
        chunking.silence.minimum_seconds,
        field_name="chunking.silence.minimum_seconds",
    )
    _finite_policy_number(
        chunking.silence.cut_padding_seconds,
        field_name="chunking.silence.cut_padding_seconds",
    )
    if chunking.silence.minimum_seconds < 0:
        raise ValueError("asr policy chunking.silence.minimum_seconds cannot be negative")
    if chunking.silence.cut_padding_seconds < 0:
        raise ValueError("asr policy chunking.silence.cut_padding_seconds cannot be negative")
    preprocessing = policy.preprocessing
    for field_name in (
        "noise_db",
        "minimum_seconds",
        "preroll_seconds",
        "postroll_seconds",
        "minimum_upload_seconds",
    ):
        _finite_policy_number(
            getattr(preprocessing, field_name),
            field_name=f"preprocessing.{field_name}",
        )
    if min(
        preprocessing.minimum_seconds,
        preprocessing.preroll_seconds,
        preprocessing.postroll_seconds,
    ) < 0:
        raise ValueError("asr policy preprocessing durations cannot be negative")
    if preprocessing.minimum_upload_seconds <= 0:
        raise ValueError("asr policy preprocessing.minimum_upload_seconds must be positive")
    execution = policy.execution
    _policy_integer(execution.target_concurrency, field_name="execution.target_concurrency", minimum=1)
    _policy_integer(execution.minimum_concurrency, field_name="execution.minimum_concurrency", minimum=1)
    _policy_integer(execution.maximum_concurrency, field_name="execution.maximum_concurrency", minimum=1)
    _policy_integer(
        execution.max_inflight_audio_bytes,
        field_name="execution.max_inflight_audio_bytes",
        minimum=1,
    )
    _finite_policy_number(
        execution.request_deadline_seconds,
        field_name="execution.request_deadline_seconds",
    )
    _policy_integer(execution.max_attempts, field_name="execution.max_attempts", minimum=1)
    if execution.maximum_concurrency < execution.minimum_concurrency:
        raise ValueError("asr policy execution.maximum_concurrency must not be smaller than minimum_concurrency")
    if not execution.minimum_concurrency <= execution.target_concurrency <= execution.maximum_concurrency:
        raise ValueError("asr policy execution.target_concurrency must be within the configured range")
    if execution.request_deadline_seconds <= 0:
        raise ValueError("asr policy execution.request_deadline_seconds must be positive")
    if execution.split_retry and chunking.mode == "none":
        raise ValueError(
            "asr policy execution.split_retry requires fixed or silence chunking"
        )
    _policy_integer(policy.decoding.beam_size, field_name="decoding.beam_size", minimum=1)
    _finite_policy_number(policy.decoding.temperature, field_name="decoding.temperature")
    if policy.decoding.temperature < 0:
        raise ValueError("asr policy decoding.temperature cannot be negative")


def resolve_asr_policy(
    base: AsrPolicy,
    overrides: AsrUserOverrides | None,
    capabilities: AsrCapabilities,
) -> AsrPolicyResolution:
    sources: dict[str, str] = {}
    adjustments: list[AsrPolicyAdjustment] = []

    def record_adjustment(
        field_name: str,
        requested: Any,
        resolved: Any,
        reason: str,
        *,
        source: str = "capability",
    ) -> None:
        if requested == resolved:
            return
        adjustments.append(
            AsrPolicyAdjustment(
                field=field_name,
                requested=requested,
                effective=resolved,
                reason=reason,
            )
        )
        sources[field_name] = source

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

    chunking_overrides = overrides.chunking if overrides is not None else None
    if chunking_overrides is not None:
        target = effective.chunking.window_target_seconds
        floor = effective.chunking.window_floor_seconds
        overlap = effective.chunking.overlap_seconds
        target_is_explicit = chunking_overrides.window_target_seconds is not None
        floor_is_explicit = chunking_overrides.window_floor_seconds is not None
        overlap_is_explicit = chunking_overrides.overlap_seconds is not None
        if target_is_explicit:
            if floor_is_explicit and floor > target:
                raise ValueError(
                    "asr overrides chunking.window_floor_seconds and "
                    "chunking.window_target_seconds conflict"
                )
            if overlap_is_explicit and overlap >= target:
                raise ValueError(
                    "asr overrides chunking.overlap_seconds and "
                    "chunking.window_target_seconds conflict"
                )
            resolved_floor = min(floor, target)
            resolved_overlap = min(overlap, max(target - 0.001, 0.0))
            effective = replace(
                effective,
                chunking=replace(
                    effective.chunking,
                    window_floor_seconds=resolved_floor,
                    overlap_seconds=resolved_overlap,
                ),
            )
            record_adjustment(
                "chunking.window_floor_seconds",
                floor,
                resolved_floor,
                "override_window_range",
                source="derived",
            )
            record_adjustment(
                "chunking.overlap_seconds",
                overlap,
                resolved_overlap,
                "override_window_range",
                source="derived",
            )
        else:
            resolved_target = max(
                target,
                floor if floor_is_explicit else target,
                overlap + 0.001 if overlap_is_explicit else target,
            )
            effective = replace(
                effective,
                chunking=replace(
                    effective.chunking,
                    window_target_seconds=resolved_target,
                ),
            )
            record_adjustment(
                "chunking.window_target_seconds",
                target,
                resolved_target,
                "override_window_range",
                source="derived",
            )

    execution_overrides = overrides.execution if overrides is not None else None
    if execution_overrides is not None:
        minimum = effective.execution.minimum_concurrency
        target = effective.execution.target_concurrency
        maximum = effective.execution.maximum_concurrency
        requested_minimum = minimum
        requested_target = target
        requested_maximum = maximum
        minimum_is_explicit = execution_overrides.minimum_concurrency is not None
        target_is_explicit = execution_overrides.target_concurrency is not None
        maximum_is_explicit = execution_overrides.maximum_concurrency is not None
        if minimum_is_explicit and maximum_is_explicit and minimum > maximum:
            raise ValueError(
                "asr overrides execution.minimum_concurrency and "
                "execution.maximum_concurrency conflict"
            )
        if minimum > maximum:
            if minimum_is_explicit:
                maximum = minimum
            elif maximum_is_explicit:
                minimum = maximum
        if target_is_explicit:
            if minimum_is_explicit and target < minimum:
                raise ValueError(
                    "asr overrides execution.target_concurrency and "
                    "execution.minimum_concurrency conflict"
                )
            if maximum_is_explicit and target > maximum:
                raise ValueError(
                    "asr overrides execution.target_concurrency and "
                    "execution.maximum_concurrency conflict"
                )
            resolved_minimum = min(minimum, target)
            resolved_maximum = max(maximum, target)
            resolved_target = target
        else:
            resolved_minimum = minimum
            resolved_maximum = maximum
            resolved_target = min(max(target, resolved_minimum), resolved_maximum)
        effective = replace(
            effective,
            execution=replace(
                effective.execution,
                minimum_concurrency=resolved_minimum,
                target_concurrency=resolved_target,
                maximum_concurrency=resolved_maximum,
            ),
        )
        for field_name, requested, resolved in (
            ("minimum_concurrency", requested_minimum, resolved_minimum),
            ("target_concurrency", requested_target, resolved_target),
            ("maximum_concurrency", requested_maximum, resolved_maximum),
        ):
            record_adjustment(
                f"execution.{field_name}",
                requested,
                resolved,
                "override_concurrency_range",
                source="derived",
            )

    _validate_asr_policy(effective)

    duration_cap = _duration_capability_value(
        capabilities.audio_input.max_duration_seconds,
        field_name="audio_input.max_duration_seconds.hard_max",
    )
    if duration_cap is not None:
        explicit_duration_fields = (
            ("window_target_seconds", lambda value: value > duration_cap),
            ("window_floor_seconds", lambda value: value > duration_cap),
            ("overlap_seconds", lambda value: value >= duration_cap),
        )
        for field_name, denied in explicit_duration_fields:
            value = getattr(chunking_overrides, field_name, None)
            if value is not None and denied(value):
                raise ValueError(
                    f"asr override chunking.{field_name} exceeds the engine duration capability"
                )
    if duration_cap is not None and effective.chunking.window_target_seconds > duration_cap:
        requested_target = effective.chunking.window_target_seconds
        requested_floor = effective.chunking.window_floor_seconds
        requested_overlap = effective.chunking.overlap_seconds
        floor = min(requested_floor, duration_cap)
        overlap = min(requested_overlap, max(duration_cap - 0.001, 0.0))
        effective = replace(
            effective,
            chunking=replace(
                effective.chunking,
                window_target_seconds=duration_cap,
                window_floor_seconds=floor,
                overlap_seconds=overlap,
            ),
        )
        record_adjustment(
            "chunking.window_target_seconds",
            requested_target,
            duration_cap,
            "engine_duration_limit",
        )
        record_adjustment(
            "chunking.window_floor_seconds",
            requested_floor,
            floor,
            "engine_duration_limit",
        )
        record_adjustment(
            "chunking.overlap_seconds",
            requested_overlap,
            overlap,
            "engine_duration_limit",
        )

    upload_cap = _integer_capability_value(
        capabilities.audio_input.max_upload_bytes,
        field_name="audio_input.max_upload_bytes.hard_max",
    )
    upload_soft_limit = effective.chunking.upload_soft_limit_bytes
    explicit_upload_limit = getattr(chunking_overrides, "upload_soft_limit_bytes", None)
    if upload_cap is not None and explicit_upload_limit is not None and explicit_upload_limit > upload_cap:
        raise ValueError("asr override chunking.upload_soft_limit_bytes exceeds the engine upload capability")
    if upload_cap is not None and (upload_soft_limit is None or upload_soft_limit > upload_cap):
        effective = replace(
            effective,
            chunking=replace(effective.chunking, upload_soft_limit_bytes=upload_cap),
        )
        record_adjustment(
            "chunking.upload_soft_limit_bytes",
            upload_soft_limit,
            upload_cap,
            "engine_upload_limit",
        )

    parallelism_cap = _integer_capability_value(
        capabilities.runtime.max_parallelism,
        field_name="runtime.max_parallelism.hard_max",
    )
    if parallelism_cap is not None:
        for field_name in (
            "minimum_concurrency",
            "target_concurrency",
            "maximum_concurrency",
        ):
            value = getattr(execution_overrides, field_name, None)
            if value is not None and value > parallelism_cap:
                raise ValueError(
                    f"asr override execution.{field_name} exceeds the runtime parallelism capability"
                )
    if parallelism_cap is not None and effective.execution.maximum_concurrency > parallelism_cap:
        requested_minimum = effective.execution.minimum_concurrency
        requested_target = effective.execution.target_concurrency
        requested_maximum = effective.execution.maximum_concurrency
        maximum = parallelism_cap
        minimum = min(requested_minimum, maximum)
        target = max(min(requested_target, maximum), minimum)
        effective = replace(
            effective,
            execution=replace(
                effective.execution,
                minimum_concurrency=minimum,
                target_concurrency=target,
                maximum_concurrency=maximum,
            ),
        )
        record_adjustment(
            "execution.minimum_concurrency",
            requested_minimum,
            minimum,
            "runtime_parallelism_limit",
        )
        record_adjustment(
            "execution.target_concurrency",
            requested_target,
            target,
            "runtime_parallelism_limit",
        )
        record_adjustment(
            "execution.maximum_concurrency",
            requested_maximum,
            maximum,
            "runtime_parallelism_limit",
        )

    decoding_overrides = overrides.decoding if overrides is not None else None
    if (
        decoding_overrides is not None
        and decoding_overrides.condition_on_previous_text is True
        and not capabilities.hints.previous_text
    ):
        raise ValueError(
            "asr override decoding.condition_on_previous_text is not supported by the engine"
        )
    if effective.decoding.condition_on_previous_text and not capabilities.hints.previous_text:
        requested_previous_text = effective.decoding.condition_on_previous_text
        effective = replace(
            effective,
            decoding=replace(
                effective.decoding,
                condition_on_previous_text=False,
            ),
        )
        record_adjustment(
            "decoding.condition_on_previous_text",
            requested_previous_text,
            False,
            "engine_previous_text_unsupported",
        )

    _validate_asr_policy(effective)
    return AsrPolicyResolution(
        policy=effective,
        sources=sources,
        adjustments=tuple(adjustments),
    )
