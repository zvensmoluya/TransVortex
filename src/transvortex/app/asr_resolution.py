from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from ..asr_domain import (
    AsrAudioInputCapabilities,
    AsrAvailability,
    AsrCapabilities,
    AsrChunkingOverrides,
    AsrChunkingPolicy,
    AsrDecodingOverrides,
    AsrDecodingPolicy,
    AsrEngineSpec,
    AsrExecutionOverrides,
    AsrExecutionPolicy,
    AsrHintCapabilities,
    AsrPolicy,
    AsrPolicyAdjustment,
    AsrPolicyResolution,
    AsrPreprocessingOverrides,
    AsrPreprocessingPolicy,
    AsrRuntimeCapabilities,
    AsrSilenceOverrides,
    AsrSilencePolicy,
    AsrTimelineCapabilities,
    AsrUserOverrides,
    CapabilityEvidence,
    CapabilityLimit,
    CredentialBinding,
    FasterWhisperWorkerEngineSpec,
    FunAsrServiceEngineSpec,
    HttpEndpointSpec,
    OpenAiTranscriptionEngineSpec,
    OpenRouterAsrEngineSpec,
    ResourceBinding,
    resolve_asr_policy,
)
from ..openrouter_asr import (
    OPENROUTER_ASR_BASE_URL,
    OPENROUTER_ASR_CREDENTIAL_ID,
    OPENROUTER_ASR_DEFAULT_MODEL,
    OPENROUTER_ASR_ENDPOINT,
    OPENROUTER_ASR_ENV_KEY,
    require_openrouter_asr_model_profile,
)
from ..utils import to_plain, utc_now_iso
from .models import (
    AsrAcceleratorConfig,
    AsrAuthConfig,
    AsrChunkingConfig,
    AsrExecutionConfig,
    AsrLocalConfig,
    AsrPreprocessingConfig,
    AsrProviderConfig,
    AsrProviderRequestConfig,
    AsrRuntimeConfig,
    AsrSilenceChunkingConfig,
    AsrTrimSilenceConfig,
    NetworkConfig,
)


ASR_ENGINE_TYPES = {
    "faster_whisper_worker",
    "funasr_service",
    "openai_transcription",
    "openrouter_asr",
}
_SENSITIVE_HEADER_NAMES = {
    "authorization",
    "cookie",
    "proxy-authorization",
    "set-cookie",
    "x-api-key",
    "api-key",
}
_SENSITIVE_HEADER_MARKERS = ("api-key", "apikey", "auth-token", "access-token", "secret", "password")


@dataclass(frozen=True)
class AsrEngineResolution:
    spec: AsrEngineSpec
    overrides: AsrUserOverrides
    capabilities: AsrCapabilities
    policy: AsrPolicyResolution
    runtime: AsrProviderConfig


ASR_INTENT_SCHEMA_VERSION = 1


def _mapping(value: Any, *, context: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be an object")
    return value


def _known_fields(raw: dict[str, Any], allowed: set[str], *, context: str) -> None:
    unknown = sorted(str(key) for key in raw if key not in allowed)
    if unknown:
        raise ValueError(f"unsupported {context} fields: {', '.join(unknown)}")


def _text(value: Any, *, default: str = "") -> str:
    if value is None:
        return default
    return str(value).strip()


def _number(value: Any, *, default: float) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"expected a number, got {value!r}") from exc


def _integer(value: Any, *, default: int) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"expected an integer, got {value!r}") from exc


def _boolean(value: Any, *, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "yes", "1", "on"}:
            return True
        if normalized in {"false", "no", "0", "off"}:
            return False
    raise ValueError(f"expected a boolean, got {value!r}")


def _choice(value: Any, *, allowed: set[str], default: str, context: str) -> str:
    normalized = _text(value, default=default)
    if normalized not in allowed:
        raise ValueError(
            f"{context} must be one of: {', '.join(sorted(allowed))}"
        )
    return normalized


def _exact_fields(raw: dict[str, Any], fields: set[str], *, context: str) -> None:
    _known_fields(raw, fields, context=context)
    missing = sorted(field for field in fields if field not in raw)
    if missing:
        raise ValueError(f"{context} is missing fields: {', '.join(missing)}")


def _optional_number(raw: dict[str, Any], name: str) -> float | None:
    return None if name not in raw or raw[name] is None else _number(raw[name], default=0.0)


def _optional_integer(raw: dict[str, Any], name: str) -> int | None:
    return None if name not in raw or raw[name] is None else _integer(raw[name], default=0)


def _optional_boolean(raw: dict[str, Any], name: str) -> bool | None:
    return None if name not in raw or raw[name] is None else _boolean(raw[name], default=False)


def _parse_resource_binding(raw: Any, *, context: str, default: ResourceBinding) -> ResourceBinding:
    values = _mapping(raw, context=context)
    _known_fields(values, {"source", "id"}, context=context)
    source = _choice(
        values.get("source"),
        allowed={"managed", "registered"},
        default=default.source,
        context=f"{context}.source",
    )
    if source == "registered" and not _text(values.get("id")):
        raise ValueError(f"{context}.id is required for a registered resource")
    resource_id = _text(values.get("id"), default=default.id)
    if not resource_id:
        raise ValueError(f"{context}.id is required")
    return ResourceBinding(source=source, id=resource_id)  # type: ignore[arg-type]


def _default_endpoint(engine_type: str, engine_id: str) -> HttpEndpointSpec:
    if engine_type == "funasr_service":
        return HttpEndpointSpec(
            scope="loopback",
            base_url="http://127.0.0.1:8899",
            path="/v1/audio/transcriptions",
            proxy="direct",
            http2=False,
        )
    if engine_type == "openrouter_asr":
        return HttpEndpointSpec(
            scope="remote",
            base_url=OPENROUTER_ASR_BASE_URL,
            path=OPENROUTER_ASR_ENDPOINT,
            credential=CredentialBinding(
                binding_id=engine_id,
                secret_ref=OPENROUTER_ASR_CREDENTIAL_ID,
            ),
        )
    return HttpEndpointSpec(
        scope="remote",
        base_url="https://api.openai.com/v1",
        path="/v1/audio/transcriptions",
        credential=CredentialBinding(binding_id=engine_id, secret_ref=engine_id),
    )


def _parse_endpoint(raw: Any, *, engine_type: str, engine_id: str) -> HttpEndpointSpec:
    default = _default_endpoint(engine_type, engine_id)
    values = _mapping(raw, context="asr_engines[].endpoint")
    _known_fields(
        values,
        {
            "scope",
            "base_url",
            "path",
            "credential",
            "proxy",
            "proxy_port",
            "headers",
            "http2",
        },
        context="asr_engines[].endpoint",
    )
    credential_raw = values.get("credential")
    credential = default.credential
    if credential_raw is not None:
        credential_values = _mapping(credential_raw, context="asr_engines[].endpoint.credential")
        _known_fields(
            credential_values,
            {"binding_id", "secret_ref"},
            context="asr_engines[].endpoint.credential",
        )
        binding_id = _text(
            credential_values.get("binding_id"),
            default=credential.binding_id if credential else engine_id,
        )
        secret_ref = _text(
            credential_values.get("secret_ref"),
            default=credential.secret_ref if credential else binding_id,
        )
        if not binding_id or not secret_ref:
            raise ValueError("ASR endpoint credential binding_id and secret_ref are required")
        credential = CredentialBinding(binding_id=binding_id, secret_ref=secret_ref)

    headers_raw = _mapping(values.get("headers"), context="asr_engines[].endpoint.headers")
    headers = {str(key).strip(): str(value) for key, value in headers_raw.items()}
    if any(not name for name in headers):
        raise ValueError("ASR endpoint header names cannot be empty")
    sensitive = sorted(
        name
        for name in headers
        if name.lower() in _SENSITIVE_HEADER_NAMES
        or any(marker in name.lower() for marker in _SENSITIVE_HEADER_MARKERS)
    )
    if sensitive:
        raise ValueError(
            "ASR endpoint headers cannot contain credentials; use endpoint.credential: "
            + ", ".join(sensitive)
        )
    scope = _choice(
        values.get("scope"),
        allowed={"loopback", "remote"},
        default=default.scope,
        context="ASR endpoint scope",
    )
    proxy = _choice(
        values.get("proxy"),
        allowed={"system", "direct", "local_proxy"},
        default=default.proxy,
        context="ASR endpoint proxy",
    )
    endpoint = HttpEndpointSpec(
        scope=scope,  # type: ignore[arg-type]
        base_url=_text(values.get("base_url"), default=default.base_url).rstrip("/"),
        path=_text(values.get("path"), default=default.path),
        credential=credential,
        proxy=proxy,  # type: ignore[arg-type]
        proxy_port=_integer(values.get("proxy_port"), default=default.proxy_port),
        headers=headers,
        http2=_boolean(values.get("http2"), default=default.http2),
    )
    if not endpoint.base_url or not endpoint.path.startswith("/"):
        raise ValueError("ASR endpoint requires a base_url and an absolute path")
    if endpoint.proxy == "local_proxy" and not 1 <= endpoint.proxy_port <= 65535:
        raise ValueError("ASR endpoint local_proxy requires proxy_port between 1 and 65535")
    if endpoint.scope == "loopback" and endpoint.credential is not None:
        raise ValueError("loopback ASR endpoints do not accept credential bindings")
    if endpoint.scope == "remote" and endpoint.credential is None:
        raise ValueError("remote ASR endpoints require a credential binding")
    return endpoint


def parse_asr_engine_spec(raw: dict[str, Any]) -> AsrEngineSpec:
    _known_fields(
        raw,
        {
            "id",
            "type",
            "runtime",
            "model",
            "accelerator",
            "device",
            "compute_type",
            "endpoint",
            "adapter_version",
            "policy_overrides",
        },
        context="asr_engines[]",
    )
    engine_id = _text(raw.get("id"))
    engine_type = _text(raw.get("type"))
    if not engine_id:
        raise ValueError("asr_engines[].id is required")
    if engine_type not in ASR_ENGINE_TYPES:
        raise ValueError(f"unsupported ASR engine type: {engine_type}")
    adapter_version = _integer(raw.get("adapter_version"), default=1)
    if adapter_version != 1:
        raise ValueError(f"unsupported ASR adapter version: {adapter_version}")

    if engine_type == "faster_whisper_worker":
        runtime = _parse_resource_binding(
            raw.get("runtime"),
            context="asr_engines[].runtime",
            default=ResourceBinding("managed", "managed:faster-whisper"),
        )
        model = _parse_resource_binding(
            raw.get("model"),
            context="asr_engines[].model",
            default=ResourceBinding("managed", "large-v3"),
        )
        accelerator = None
        if raw.get("accelerator") is not None:
            accelerator = _parse_resource_binding(
                raw.get("accelerator"),
                context="asr_engines[].accelerator",
                default=ResourceBinding("managed", "nvidia-cuda12"),
            )
        device = _text(raw.get("device"), default="auto")
        if device not in {"auto", "cpu", "cuda"}:
            raise ValueError("faster_whisper_worker device must be auto, cpu, or cuda")
        return FasterWhisperWorkerEngineSpec(
            id=engine_id,
            runtime_binding=runtime,
            model_binding=model,
            accelerator_binding=accelerator,
            device_preference=device,  # type: ignore[arg-type]
            compute_type_preference=_text(raw.get("compute_type"), default="auto"),
            adapter_version=adapter_version,
        )

    model = _text(raw.get("model"))
    if not model:
        model = OPENROUTER_ASR_DEFAULT_MODEL if engine_type == "openrouter_asr" else "whisper-1"
    endpoint = _parse_endpoint(raw.get("endpoint"), engine_type=engine_type, engine_id=engine_id)
    if engine_type == "funasr_service":
        if endpoint.scope != "loopback":
            raise ValueError("funasr_service requires a loopback endpoint")
        return FunAsrServiceEngineSpec(
            id=engine_id,
            model=model if raw.get("model") is not None else "sensevoice",
            endpoint=endpoint,
            adapter_version=adapter_version,
        )
    if engine_type == "openrouter_asr":
        require_openrouter_asr_model_profile(model)
        return OpenRouterAsrEngineSpec(
            id=engine_id,
            model=model,
            endpoint=endpoint,
            adapter_version=adapter_version,
        )
    return OpenAiTranscriptionEngineSpec(
        id=engine_id,
        model=model,
        endpoint=endpoint,
        adapter_version=adapter_version,
    )


def parse_asr_user_overrides(raw: Any) -> AsrUserOverrides:
    values = _mapping(raw, context="asr_engines[].policy_overrides")
    _known_fields(
        values,
        {"chunking", "preprocessing", "execution", "decoding"},
        context="asr_engines[].policy_overrides",
    )
    chunking_raw = _mapping(values.get("chunking"), context="ASR chunking overrides")
    preprocessing_raw = _mapping(values.get("preprocessing"), context="ASR preprocessing overrides")
    execution_raw = _mapping(values.get("execution"), context="ASR execution overrides")
    decoding_raw = _mapping(values.get("decoding"), context="ASR decoding overrides")
    silence_raw = _mapping(chunking_raw.get("silence"), context="ASR silence overrides")
    _known_fields(
        chunking_raw,
        {
            "mode",
            "window_target_seconds",
            "window_floor_seconds",
            "overlap_seconds",
            "short_audio_bypass_seconds",
            "upload_soft_limit_bytes",
            "silence",
        },
        context="ASR chunking overrides",
    )
    _known_fields(
        silence_raw,
        {"noise_db", "minimum_seconds", "cut_padding_seconds", "fallback"},
        context="ASR silence overrides",
    )
    _known_fields(
        preprocessing_raw,
        {
            "trim_silence",
            "noise_db",
            "minimum_seconds",
            "preroll_seconds",
            "trim_trailing",
            "postroll_seconds",
            "minimum_upload_seconds",
        },
        context="ASR preprocessing overrides",
    )
    _known_fields(
        execution_raw,
        {
            "concurrency_mode",
            "target_concurrency",
            "minimum_concurrency",
            "maximum_concurrency",
            "max_inflight_audio_bytes",
            "request_deadline_seconds",
            "max_attempts",
            "split_retry",
        },
        context="ASR execution overrides",
    )
    _known_fields(
        decoding_raw,
        {"beam_size", "temperature", "condition_on_previous_text"},
        context="ASR decoding overrides",
    )

    chunking = None
    if chunking_raw:
        silence = None
        if silence_raw:
            silence = AsrSilenceOverrides(
                noise_db=_optional_number(silence_raw, "noise_db"),
                minimum_seconds=_optional_number(silence_raw, "minimum_seconds"),
                cut_padding_seconds=_optional_number(silence_raw, "cut_padding_seconds"),
                fallback=(
                    _choice(
                        silence_raw.get("fallback"),
                        allowed={"hard_cut"},
                        default="hard_cut",
                        context="ASR silence fallback",
                    )
                    if silence_raw.get("fallback") is not None
                    else None
                ),  # type: ignore[arg-type]
            )
        chunking = AsrChunkingOverrides(
            mode=(
                _choice(
                    chunking_raw.get("mode"),
                    allowed={"fixed", "none", "silence"},
                    default="silence",
                    context="ASR chunking mode",
                )
                if chunking_raw.get("mode") is not None
                else None
            ),  # type: ignore[arg-type]
            window_target_seconds=_optional_number(chunking_raw, "window_target_seconds"),
            window_floor_seconds=_optional_number(chunking_raw, "window_floor_seconds"),
            overlap_seconds=_optional_number(chunking_raw, "overlap_seconds"),
            short_audio_bypass_seconds=_optional_number(chunking_raw, "short_audio_bypass_seconds"),
            upload_soft_limit_bytes=_optional_integer(chunking_raw, "upload_soft_limit_bytes"),
            silence=silence,
        )
    preprocessing = None
    if preprocessing_raw:
        preprocessing = AsrPreprocessingOverrides(
            trim_silence=_optional_boolean(preprocessing_raw, "trim_silence"),
            noise_db=_optional_number(preprocessing_raw, "noise_db"),
            minimum_seconds=_optional_number(preprocessing_raw, "minimum_seconds"),
            preroll_seconds=_optional_number(preprocessing_raw, "preroll_seconds"),
            trim_trailing=_optional_boolean(preprocessing_raw, "trim_trailing"),
            postroll_seconds=_optional_number(preprocessing_raw, "postroll_seconds"),
            minimum_upload_seconds=_optional_number(preprocessing_raw, "minimum_upload_seconds"),
        )
    execution = None
    if execution_raw:
        execution = AsrExecutionOverrides(
            concurrency_mode=(
                _choice(
                    execution_raw.get("concurrency_mode"),
                    allowed={"adaptive", "fixed"},
                    default="fixed",
                    context="ASR execution concurrency_mode",
                )
                if execution_raw.get("concurrency_mode") is not None
                else None
            ),  # type: ignore[arg-type]
            target_concurrency=_optional_integer(execution_raw, "target_concurrency"),
            minimum_concurrency=_optional_integer(execution_raw, "minimum_concurrency"),
            maximum_concurrency=_optional_integer(execution_raw, "maximum_concurrency"),
            max_inflight_audio_bytes=_optional_integer(execution_raw, "max_inflight_audio_bytes"),
            request_deadline_seconds=_optional_number(execution_raw, "request_deadline_seconds"),
            max_attempts=_optional_integer(execution_raw, "max_attempts"),
            split_retry=_optional_boolean(execution_raw, "split_retry"),
        )
    decoding = None
    if decoding_raw:
        decoding = AsrDecodingOverrides(
            beam_size=_optional_integer(decoding_raw, "beam_size"),
            temperature=_optional_number(decoding_raw, "temperature"),
            condition_on_previous_text=_optional_boolean(decoding_raw, "condition_on_previous_text"),
        )
    return AsrUserOverrides(
        chunking=chunking,
        preprocessing=preprocessing,
        execution=execution,
        decoding=decoding,
    )


def parse_asr_policy_snapshot(raw: Any) -> AsrPolicy:
    """Parse the complete effective policy stored in a task intent snapshot."""

    values = _mapping(raw, context="task ASR effective policy")
    fields = {"chunking", "preprocessing", "execution", "decoding"}
    _exact_fields(values, fields, context="task ASR effective policy")
    chunking = _mapping(values["chunking"], context="task ASR chunking policy")
    preprocessing = _mapping(
        values["preprocessing"],
        context="task ASR preprocessing policy",
    )
    execution = _mapping(values["execution"], context="task ASR execution policy")
    decoding = _mapping(values["decoding"], context="task ASR decoding policy")
    silence = _mapping(chunking.get("silence"), context="task ASR silence policy")
    _exact_fields(
        chunking,
        {
            "mode",
            "window_target_seconds",
            "window_floor_seconds",
            "overlap_seconds",
            "short_audio_bypass_seconds",
            "upload_soft_limit_bytes",
            "silence",
        },
        context="task ASR chunking policy",
    )
    _exact_fields(
        silence,
        {"noise_db", "minimum_seconds", "cut_padding_seconds", "fallback"},
        context="task ASR silence policy",
    )
    _exact_fields(
        preprocessing,
        {
            "trim_silence",
            "noise_db",
            "minimum_seconds",
            "preroll_seconds",
            "trim_trailing",
            "postroll_seconds",
            "minimum_upload_seconds",
        },
        context="task ASR preprocessing policy",
    )
    _exact_fields(
        execution,
        {
            "concurrency_mode",
            "target_concurrency",
            "minimum_concurrency",
            "maximum_concurrency",
            "max_inflight_audio_bytes",
            "request_deadline_seconds",
            "max_attempts",
            "split_retry",
        },
        context="task ASR execution policy",
    )
    _exact_fields(
        decoding,
        {"beam_size", "temperature", "condition_on_previous_text"},
        context="task ASR decoding policy",
    )
    upload_limit = chunking["upload_soft_limit_bytes"]
    return AsrPolicy(
        chunking=AsrChunkingPolicy(
            mode=_choice(
                chunking["mode"],
                allowed={"fixed", "none", "silence"},
                default="silence",
                context="task ASR chunking mode",
            ),  # type: ignore[arg-type]
            window_target_seconds=_number(chunking["window_target_seconds"], default=0.0),
            window_floor_seconds=_number(chunking["window_floor_seconds"], default=0.0),
            overlap_seconds=_number(chunking["overlap_seconds"], default=0.0),
            short_audio_bypass_seconds=_number(
                chunking["short_audio_bypass_seconds"],
                default=0.0,
            ),
            upload_soft_limit_bytes=(
                None
                if upload_limit is None
                else _integer(upload_limit, default=0)
            ),
            silence=AsrSilencePolicy(
                noise_db=_number(silence["noise_db"], default=-35.0),
                minimum_seconds=_number(silence["minimum_seconds"], default=0.25),
                cut_padding_seconds=_number(
                    silence["cut_padding_seconds"],
                    default=0.15,
                ),
                fallback=_choice(
                    silence["fallback"],
                    allowed={"hard_cut"},
                    default="hard_cut",
                    context="task ASR silence fallback",
                ),  # type: ignore[arg-type]
            ),
        ),
        preprocessing=AsrPreprocessingPolicy(
            trim_silence=_boolean(preprocessing["trim_silence"], default=False),
            noise_db=_number(preprocessing["noise_db"], default=-35.0),
            minimum_seconds=_number(preprocessing["minimum_seconds"], default=0.2),
            preroll_seconds=_number(preprocessing["preroll_seconds"], default=0.25),
            trim_trailing=_boolean(preprocessing["trim_trailing"], default=True),
            postroll_seconds=_number(preprocessing["postroll_seconds"], default=0.1),
            minimum_upload_seconds=_number(
                preprocessing["minimum_upload_seconds"],
                default=0.5,
            ),
        ),
        execution=AsrExecutionPolicy(
            concurrency_mode=_choice(
                execution["concurrency_mode"],
                allowed={"adaptive", "fixed"},
                default="fixed",
                context="task ASR execution concurrency_mode",
            ),  # type: ignore[arg-type]
            target_concurrency=_integer(execution["target_concurrency"], default=1),
            minimum_concurrency=_integer(execution["minimum_concurrency"], default=1),
            maximum_concurrency=_integer(execution["maximum_concurrency"], default=1),
            max_inflight_audio_bytes=_integer(
                execution["max_inflight_audio_bytes"],
                default=1,
            ),
            request_deadline_seconds=_number(
                execution["request_deadline_seconds"],
                default=1.0,
            ),
            max_attempts=_integer(execution["max_attempts"], default=1),
            split_retry=_boolean(execution["split_retry"], default=True),
        ),
        decoding=AsrDecodingPolicy(
            beam_size=_integer(decoding["beam_size"], default=1),
            temperature=_number(decoding["temperature"], default=0.0),
            condition_on_previous_text=_boolean(
                decoding["condition_on_previous_text"],
                default=False,
            ),
        ),
    )


def recommended_asr_policy(spec: AsrEngineSpec) -> AsrPolicy:
    if isinstance(spec, FasterWhisperWorkerEngineSpec):
        return AsrPolicy(
            chunking=AsrChunkingPolicy(
                mode="silence",
                window_target_seconds=120.0,
                window_floor_seconds=12.0,
                overlap_seconds=5.0,
                short_audio_bypass_seconds=300.0,
                upload_soft_limit_bytes=None,
            ),
            preprocessing=AsrPreprocessingPolicy(trim_silence=False),
            execution=AsrExecutionPolicy(
                concurrency_mode="fixed",
                target_concurrency=1,
                minimum_concurrency=1,
                maximum_concurrency=1,
                request_deadline_seconds=300.0,
                max_attempts=1,
            ),
        )
    if isinstance(spec, FunAsrServiceEngineSpec):
        return AsrPolicy(
            chunking=AsrChunkingPolicy(
                mode="fixed",
                window_target_seconds=120.0,
                window_floor_seconds=1.0,
                overlap_seconds=0.0,
                short_audio_bypass_seconds=120.0,
                upload_soft_limit_bytes=64 * 1024 * 1024,
            ),
            preprocessing=AsrPreprocessingPolicy(trim_silence=False),
            execution=AsrExecutionPolicy(
                concurrency_mode="fixed",
                target_concurrency=1,
                minimum_concurrency=1,
                maximum_concurrency=1,
                request_deadline_seconds=300.0,
                max_attempts=1,
            ),
        )
    if isinstance(spec, OpenRouterAsrEngineSpec):
        profile = require_openrouter_asr_model_profile(spec.model)
        return AsrPolicy(
            chunking=AsrChunkingPolicy(
                mode="silence",
                window_target_seconds=profile.max_window_seconds,
                window_floor_seconds=profile.min_window_seconds,
                overlap_seconds=profile.overlap_seconds,
                short_audio_bypass_seconds=profile.max_window_seconds,
                upload_soft_limit_bytes=24 * 1024 * 1024,
            ),
            preprocessing=AsrPreprocessingPolicy(trim_silence=True),
            execution=AsrExecutionPolicy(
                concurrency_mode="adaptive",
                target_concurrency=4,
                minimum_concurrency=1,
                maximum_concurrency=4,
                max_inflight_audio_bytes=64 * 1024 * 1024,
                request_deadline_seconds=120.0,
                max_attempts=2,
            ),
        )
    return AsrPolicy(
        chunking=AsrChunkingPolicy(
            mode="silence",
            window_target_seconds=120.0,
            window_floor_seconds=12.0,
            overlap_seconds=5.0,
            short_audio_bypass_seconds=300.0,
            upload_soft_limit_bytes=24 * 1024 * 1024,
        ),
        preprocessing=AsrPreprocessingPolicy(trim_silence=True),
        execution=AsrExecutionPolicy(
            concurrency_mode="adaptive",
            target_concurrency=8,
            minimum_concurrency=1,
            maximum_concurrency=8,
            max_inflight_audio_bytes=128 * 1024 * 1024,
            request_deadline_seconds=300.0,
            max_attempts=2,
        ),
    )


def declared_asr_capabilities(spec: AsrEngineSpec) -> AsrCapabilities:
    common_input = AsrAudioInputCapabilities(
        formats=("wav",),
        max_duration_seconds=CapabilityLimit(knowledge="unknown", source="adapter_contract"),
        max_upload_bytes=CapabilityLimit(knowledge="unknown", source="adapter_contract"),
        sample_rates_hz=(16000,),
        max_channels=1,
    )
    if isinstance(spec, FasterWhisperWorkerEngineSpec):
        return AsrCapabilities(
            audio_input=AsrAudioInputCapabilities(
                formats=("wav",),
                max_duration_seconds=CapabilityLimit(
                    knowledge="not_applicable",
                    source="local_worker",
                ),
                max_upload_bytes=CapabilityLimit(
                    knowledge="not_applicable",
                    source="local_worker",
                ),
                sample_rates_hz=(16000,),
                max_channels=1,
            ),
            timeline=AsrTimelineCapabilities(granularities=("segment",), confidence=True),
            hints=AsrHintCapabilities(
                language=True,
                prompt=True,
                previous_text=True,
                hotwords=True,
            ),
            runtime=AsrRuntimeCapabilities(
                max_parallelism=CapabilityLimit(
                    hard_max=1,
                    observed_safe_max=1,
                    knowledge="verified",
                    source="stdio_worker_contract",
                )
            ),
            evidence=(
                CapabilityEvidence(
                    field="runtime.max_parallelism",
                    source="stdio_worker_contract",
                    value=1,
                ),
            ),
        )
    if isinstance(spec, FunAsrServiceEngineSpec):
        return AsrCapabilities(
            audio_input=common_input,
            timeline=AsrTimelineCapabilities(granularities=("segment",)),
            hints=AsrHintCapabilities(language=True),
            runtime=AsrRuntimeCapabilities(
                max_parallelism=CapabilityLimit(knowledge="unknown", source="service_probe")
            ),
        )
    if isinstance(spec, OpenRouterAsrEngineSpec):
        profile = require_openrouter_asr_model_profile(spec.model)
        granularity = "word" if profile.timeline_mode == "words_required" else "segment"
        return AsrCapabilities(
            audio_input=common_input,
            timeline=AsrTimelineCapabilities(
                granularities=(granularity,),  # type: ignore[arg-type]
                speaker_labels="speaker_diarization" in profile.native_capabilities,
                multichannel="multichannel" in profile.native_capabilities,
            ),
            hints=AsrHintCapabilities(
                language=True,
                prompt=profile.prompt_mode != "unsupported",
            ),
            runtime=AsrRuntimeCapabilities(
                max_parallelism=CapabilityLimit(knowledge="unknown", source="service_probe")
            ),
        )
    return AsrCapabilities(
        audio_input=common_input,
        timeline=AsrTimelineCapabilities(granularities=("segment",)),
        hints=AsrHintCapabilities(language=True, prompt=True),
        runtime=AsrRuntimeCapabilities(
            max_parallelism=CapabilityLimit(knowledge="unknown", source="service_probe")
        ),
    )


def observe_asr_capabilities(
    spec: AsrEngineSpec,
    declared: AsrCapabilities,
    runtime: AsrProviderConfig,
    *,
    root_dir: Path,
) -> AsrCapabilities:
    """Merge current readiness and verified local runtime facts into declared capabilities."""

    from .asr_runtime import asr_active_execution_snapshot, asr_provider_readiness

    observed_at = utc_now_iso()
    readiness = asr_provider_readiness(runtime, root_dir=root_dir)
    raw_state = _text(readiness.get("state"), default="unknown")
    state = raw_state if raw_state in {"ready", "needs_action", "unavailable", "checking"} else "unknown"
    availability = AsrAvailability(
        state=state,  # type: ignore[arg-type]
        reason_code=_text(readiness.get("code")),
        observed_at=observed_at,
    )
    evidence = list(declared.evidence)
    evidence.append(
        CapabilityEvidence(
            field="availability",
            source="runtime_readiness",
            value={"state": state, "reason_code": availability.reason_code},
            observed_at=observed_at,
        )
    )
    runtime_capabilities = declared.runtime
    if isinstance(spec, FasterWhisperWorkerEngineSpec):
        execution = asr_active_execution_snapshot(runtime, root_dir=root_dir)
        accelerator = _mapping(execution.get("accelerator"), context="ASR execution accelerator")
        cuda = _mapping(accelerator.get("cuda"), context="ASR execution CUDA")
        compute_types = tuple(
            str(item).strip()
            for item in cuda.get("compute_types") or []
            if str(item).strip()
        )
        runtime_capabilities = replace(
            runtime_capabilities,
            resolved_device=_text(execution.get("resolved_device")),
            supported_compute_types=compute_types,
        )
        evidence.append(
            CapabilityEvidence(
                field="runtime.resolved_device",
                source="runtime_probe",
                value=runtime_capabilities.resolved_device,
                observed_at=observed_at,
            )
        )
    return replace(
        declared,
        availability=availability,
        runtime=runtime_capabilities,
        evidence=tuple(evidence),
    )


def _capability_limit_from_plain(raw: Any) -> CapabilityLimit:
    values = _mapping(raw, context="ASR capability limit")
    return CapabilityLimit(
        hard_max=_optional_number(values, "hard_max"),
        observed_safe_max=_optional_number(values, "observed_safe_max"),
        knowledge=_choice(
            values.get("knowledge"),
            allowed={"verified", "reported", "inferred", "unknown", "not_applicable"},
            default="unknown",
            context="ASR capability knowledge",
        ),  # type: ignore[arg-type]
        source=_text(values.get("source")),
        observed_at=_text(values.get("observed_at")),
    )


def parse_asr_capabilities_snapshot(raw: Any) -> AsrCapabilities:
    values = _mapping(raw, context="ASR capabilities snapshot")
    availability = _mapping(values.get("availability"), context="ASR availability snapshot")
    audio = _mapping(values.get("audio_input"), context="ASR audio capabilities snapshot")
    timeline = _mapping(values.get("timeline"), context="ASR timeline capabilities snapshot")
    hints = _mapping(values.get("hints"), context="ASR hint capabilities snapshot")
    runtime = _mapping(values.get("runtime"), context="ASR runtime capabilities snapshot")
    evidence: list[CapabilityEvidence] = []
    for item in values.get("evidence") or []:
        if isinstance(item, dict):
            evidence.append(
                CapabilityEvidence(
                    field=_text(item.get("field")),
                    source=_text(item.get("source")),
                    value=item.get("value"),
                    observed_at=_text(item.get("observed_at")),
                )
            )
    return AsrCapabilities(
        availability=AsrAvailability(
            state=_choice(
                availability.get("state"),
                allowed={"ready", "needs_action", "unavailable", "checking", "unknown"},
                default="unknown",
                context="ASR availability state",
            ),  # type: ignore[arg-type]
            reason_code=_text(availability.get("reason_code")),
            observed_at=_text(availability.get("observed_at")),
        ),
        audio_input=AsrAudioInputCapabilities(
            formats=tuple(str(item) for item in audio.get("formats") or []),
            max_duration_seconds=_capability_limit_from_plain(audio.get("max_duration_seconds")),
            max_upload_bytes=_capability_limit_from_plain(audio.get("max_upload_bytes")),
            sample_rates_hz=tuple(int(item) for item in audio.get("sample_rates_hz") or []),
            max_channels=_optional_integer(audio, "max_channels"),
        ),
        timeline=AsrTimelineCapabilities(
            granularities=tuple(
                _choice(
                    item,
                    allowed={"segment", "word"},
                    default="segment",
                    context="ASR timeline granularity",
                )
                for item in timeline.get("granularities") or []
            ),  # type: ignore[arg-type]
            confidence=_boolean(timeline.get("confidence"), default=False),
            speaker_labels=_boolean(timeline.get("speaker_labels"), default=False),
            multichannel=_boolean(timeline.get("multichannel"), default=False),
        ),
        hints=AsrHintCapabilities(
            language=_boolean(hints.get("language"), default=False),
            prompt=_boolean(hints.get("prompt"), default=False),
            previous_text=_boolean(hints.get("previous_text"), default=False),
            hotwords=_boolean(hints.get("hotwords"), default=False),
        ),
        runtime=AsrRuntimeCapabilities(
            resolved_device=_text(runtime.get("resolved_device")),
            device_name=_text(runtime.get("device_name")),
            supported_compute_types=tuple(
                str(item) for item in runtime.get("supported_compute_types") or []
            ),
            gpu_memory_total_bytes=_optional_integer(runtime, "gpu_memory_total_bytes"),
            gpu_memory_free_bytes=_optional_integer(runtime, "gpu_memory_free_bytes"),
            max_parallelism=_capability_limit_from_plain(runtime.get("max_parallelism")),
        ),
        evidence=tuple(evidence),
    )


def _network_from_endpoint(endpoint: HttpEndpointSpec) -> NetworkConfig:
    return NetworkConfig(mode=endpoint.proxy, proxy_port=endpoint.proxy_port)


def _registered_model_values(root_dir: Path, binding: ResourceBinding) -> tuple[str, str]:
    from .asr_runtime import registered_external_model

    record = registered_external_model(root_dir=root_dir, registration_id=binding.id)
    if record is None:
        raise ValueError(f"registered ASR model is missing or stale: {binding.id}")
    model_id = _text(record.get("model_id"))
    model_path = _text(record.get("model_path"))
    if not model_id or not model_path:
        raise ValueError(f"registered ASR model is incomplete: {binding.id}")
    return model_id, model_path


def _runtime_provider_from_resolution(
    spec: AsrEngineSpec,
    policy: AsrPolicy,
    *,
    root_dir: Path,
) -> AsrProviderConfig:
    chunking = policy.chunking
    execution = policy.execution
    preprocessing = policy.preprocessing
    runtime_chunking = AsrChunkingConfig(
        mode=chunking.mode,
        window_seconds=int(chunking.window_target_seconds),
        max_window_seconds=int(chunking.window_target_seconds),
        min_window_seconds=int(chunking.window_floor_seconds),
        overlap_seconds=int(chunking.overlap_seconds),
        short_audio_seconds=int(chunking.short_audio_bypass_seconds),
        # The legacy adapter requires a numeric value. A large sentinel keeps
        # an explicit domain-level `None` from silently becoming a 24 MiB cap.
        max_upload_mb=(
            chunking.upload_soft_limit_bytes / (1024 * 1024)
            if chunking.upload_soft_limit_bytes is not None
            else 2048.0
        ),
        silence=AsrSilenceChunkingConfig(
            noise_db=chunking.silence.noise_db,
            min_silence_seconds=chunking.silence.minimum_seconds,
            cut_padding_seconds=chunking.silence.cut_padding_seconds,
            fallback_mode=chunking.silence.fallback,
        ),
        fuzzy_dedupe=chunking.overlap_seconds > 0,
    )
    runtime_execution = AsrExecutionConfig(
        concurrency=execution.target_concurrency,
        adaptive_concurrency=execution.concurrency_mode == "adaptive",
        min_concurrency=execution.minimum_concurrency,
        max_concurrency=execution.maximum_concurrency,
        max_inflight_upload_mb=execution.max_inflight_audio_bytes / (1024 * 1024),
        timeout_seconds=int(execution.request_deadline_seconds),
        retry=execution.max_attempts,
    )
    runtime_preprocessing = AsrPreprocessingConfig(
        trim_silence=AsrTrimSilenceConfig(
            enabled=preprocessing.trim_silence,
            noise_db=preprocessing.noise_db,
            min_silence_seconds=preprocessing.minimum_seconds,
            keep_preroll_seconds=preprocessing.preroll_seconds,
            trim_trailing=preprocessing.trim_trailing,
            keep_postroll_seconds=preprocessing.postroll_seconds,
            min_upload_seconds=preprocessing.minimum_upload_seconds,
        )
    )
    if isinstance(spec, FasterWhisperWorkerEngineSpec):
        model_id = spec.model_binding.id
        model_path = ""
        if spec.model_binding.source == "registered":
            model_id, model_path = _registered_model_values(root_dir, spec.model_binding)
        accelerator = spec.accelerator_binding
        return AsrProviderConfig(
            name=spec.id,
            kind="local_worker",
            protocol="faster_whisper",
            model=model_id,
            auth=AsrAuthConfig(type="none", env_key="", credential_id=""),
            runtime=AsrRuntimeConfig(
                source="managed" if spec.runtime_binding.source == "managed" else "external",
                id=spec.runtime_binding.id,
            ),
            accelerator=AsrAcceleratorConfig(
                source=(
                    "managed"
                    if accelerator is None or accelerator.source == "managed"
                    else "external"
                ),
                id=accelerator.id if accelerator is not None else "nvidia-cuda12",
            ),
            local=AsrLocalConfig(
                model_size=model_id,
                model_source="managed" if spec.model_binding.source == "managed" else "external",
                model_path=model_path,
                managed_model_size=model_id if spec.model_binding.source == "managed" else "",
                external_model_id=model_id if spec.model_binding.source == "registered" else "",
                external_model_path=model_path,
                device=spec.device_preference,
                compute_type=spec.compute_type_preference,
                beam_size=policy.decoding.beam_size,
                temperature=policy.decoding.temperature,
                condition_on_previous_text=policy.decoding.condition_on_previous_text,
            ),
            execution=runtime_execution,
            chunking=runtime_chunking,
            preprocessing=runtime_preprocessing,
            http2=False,
            network=NetworkConfig(mode="direct"),
        )

    endpoint = spec.endpoint
    credential = endpoint.credential
    auth = AsrAuthConfig(
        type="none" if credential is None else "bearer",
        env_key=(
            OPENROUTER_ASR_ENV_KEY
            if isinstance(spec, OpenRouterAsrEngineSpec)
            else "OPENAI_API_KEY"
            if isinstance(spec, OpenAiTranscriptionEngineSpec)
            else ""
        ),
        credential_id=credential.secret_ref if credential else "",
    )
    request = AsrProviderRequestConfig(
        response_format="verbose_json",
        temperature=policy.decoding.temperature,
        timestamp_granularities=["segment"],
        array_format="brackets",
        send_temperature=True,
        send_timestamp_granularities=True,
        send_language=True,
        send_prompt=True,
    )
    kind = "remote"
    protocol = "openai_transcriptions"
    if isinstance(spec, FunAsrServiceEngineSpec):
        kind = "local_server"
        protocol = "funasr_openai"
        runtime_chunking.fuzzy_dedupe = False
        request.array_format = "repeat"
        request.send_temperature = False
        request.send_timestamp_granularities = False
        request.send_prompt = False
    elif isinstance(spec, OpenRouterAsrEngineSpec):
        protocol = "openrouter_stt"
        profile = require_openrouter_asr_model_profile(spec.model)
        request.timestamp_granularities = list(profile.timestamp_granularities)
        request.array_format = "repeat"
        request.send_prompt = profile.prompt_mode != "unsupported"
    return AsrProviderConfig(
        name=spec.id,
        kind=kind,
        protocol=protocol,
        base_url=endpoint.base_url,
        endpoint=endpoint.path,
        model=spec.model,
        auth=auth,
        execution=runtime_execution,
        chunking=runtime_chunking,
        preprocessing=runtime_preprocessing,
        http2=endpoint.http2,
        extra_headers=dict(endpoint.headers),
        request=request,
        network=_network_from_endpoint(endpoint),
    )


def resolve_asr_engine(raw: dict[str, Any], *, root_dir: Path) -> AsrEngineResolution:
    spec = parse_asr_engine_spec(raw)
    overrides = parse_asr_user_overrides(raw.get("policy_overrides"))
    capabilities = declared_asr_capabilities(spec)
    policy = resolve_asr_policy(recommended_asr_policy(spec), overrides, capabilities)
    runtime = _runtime_provider_from_resolution(spec, policy.policy, root_dir=root_dir)
    return AsrEngineResolution(
        spec=spec,
        overrides=overrides,
        capabilities=capabilities,
        policy=policy,
        runtime=runtime,
    )


def default_asr_engine_rows() -> list[dict[str, Any]]:
    return [
        {
            "id": "faster_whisper_large_v3",
            "type": "faster_whisper_worker",
            "runtime": {"source": "managed", "id": "managed:faster-whisper"},
            "model": {"source": "managed", "id": "large-v3"},
            "accelerator": {"source": "managed", "id": "nvidia-cuda12"},
            "device": "auto",
            "compute_type": "auto",
        }
    ]


def _drop_none(value: Any) -> Any:
    if isinstance(value, dict):
        compact: dict[str, Any] = {}
        for key, item in value.items():
            if item is None:
                continue
            normalized = _drop_none(item)
            if normalized not in ({}, []):
                compact[key] = normalized
        return compact
    if isinstance(value, list):
        return [_drop_none(item) for item in value]
    return value


def asr_engine_to_yaml_row(spec: AsrEngineSpec, overrides: AsrUserOverrides) -> dict[str, Any]:
    row = to_plain(spec)
    row["type"] = row.pop("kind")
    row.pop("adapter_version", None)
    if isinstance(spec, FasterWhisperWorkerEngineSpec):
        row["runtime"] = row.pop("runtime_binding")
        row["model"] = row.pop("model_binding")
        row["accelerator"] = row.pop("accelerator_binding")
        row["device"] = row.pop("device_preference")
        row["compute_type"] = row.pop("compute_type_preference")
    else:
        default_endpoint = _default_endpoint(spec.kind, spec.id)
        endpoint: dict[str, Any] = {}
        for name in (
            "scope",
            "base_url",
            "path",
            "proxy",
            "proxy_port",
            "headers",
            "http2",
        ):
            value = getattr(spec.endpoint, name)
            if value != getattr(default_endpoint, name):
                endpoint[name] = value
        if spec.endpoint.credential != default_endpoint.credential:
            endpoint["credential"] = to_plain(spec.endpoint.credential)
        row["endpoint"] = endpoint or None
    compact_overrides = _drop_none(to_plain(overrides))
    if compact_overrides:
        row["policy_overrides"] = compact_overrides
    return _drop_none(row)


def build_active_asr_intent_snapshot(config: Any, *, root_dir: Path) -> dict[str, Any]:
    engine_id = str(config.pipeline.asr_provider or "").strip()
    spec = config.asr_engine_specs.get(engine_id)
    overrides = config.asr_user_overrides.get(engine_id)
    runtime = config.asr_providers.get(engine_id)
    declared = config.asr_capabilities.get(engine_id)
    if spec is None or overrides is None or runtime is None or declared is None:
        return {}
    capabilities = observe_asr_capabilities(
        spec,
        declared,
        runtime,
        root_dir=root_dir,
    )
    policy_resolution = resolve_asr_policy(
        recommended_asr_policy(spec),
        overrides,
        capabilities,
    )
    runtime = _runtime_provider_from_resolution(
        spec,
        policy_resolution.policy,
        root_dir=root_dir,
    )
    config.asr_capabilities[engine_id] = capabilities
    config.asr_policy_resolutions[engine_id] = policy_resolution
    config.asr_providers[engine_id] = runtime
    return {
        "intent_schema_version": ASR_INTENT_SCHEMA_VERSION,
        "captured_at": utc_now_iso(),
        "engine_id": engine_id,
        "engine": asr_engine_to_yaml_row(spec, overrides),
        "capabilities": to_plain(capabilities),
        "effective_policy": to_plain(policy_resolution.policy),
        "policy_sources": dict(policy_resolution.sources),
        "adjustments": to_plain(policy_resolution.adjustments),
    }


def restore_asr_intent_snapshot(
    config: Any,
    raw: Any,
    *,
    root_dir: Path,
) -> AsrEngineResolution | None:
    snapshot = _mapping(raw, context="task ASR intent")
    if not snapshot:
        return None
    version = _integer(snapshot.get("intent_schema_version"), default=0)
    if version != ASR_INTENT_SCHEMA_VERSION:
        raise ValueError(f"unsupported task ASR intent schema version: {version}")
    engine_row = dict(_mapping(snapshot.get("engine"), context="task ASR engine"))
    engine_id = _text(snapshot.get("engine_id"))
    if not engine_id or _text(engine_row.get("id")) != engine_id:
        raise ValueError("task ASR intent engine id is inconsistent")

    spec = parse_asr_engine_spec(engine_row)
    original_overrides = parse_asr_user_overrides(engine_row.get("policy_overrides"))
    capabilities = parse_asr_capabilities_snapshot(snapshot.get("capabilities"))
    effective_policy_raw = _mapping(snapshot.get("effective_policy"), context="task ASR policy")
    if not effective_policy_raw:
        raise ValueError("task ASR intent is missing its effective policy")
    frozen_policy = parse_asr_policy_snapshot(effective_policy_raw)
    validated_policy = resolve_asr_policy(frozen_policy, None, capabilities)
    if validated_policy.policy != frozen_policy or validated_policy.adjustments:
        raise ValueError("task ASR effective policy is inconsistent with captured capabilities")
    adjustments: list[AsrPolicyAdjustment] = []
    for item in snapshot.get("adjustments") or []:
        if isinstance(item, dict):
            adjustments.append(
                AsrPolicyAdjustment(
                    field=_text(item.get("field")),
                    requested=item.get("requested"),
                    effective=item.get("effective"),
                    reason=_text(item.get("reason")),
                )
            )
    policy_resolution = AsrPolicyResolution(
        policy=frozen_policy,
        sources={str(key): str(value) for key, value in _mapping(
            snapshot.get("policy_sources"),
            context="task ASR policy sources",
        ).items()},
        adjustments=tuple(adjustments),
    )
    runtime = _runtime_provider_from_resolution(spec, frozen_policy, root_dir=root_dir)
    resolution = AsrEngineResolution(
        spec=spec,
        overrides=original_overrides,
        capabilities=capabilities,
        policy=policy_resolution,
        runtime=runtime,
    )
    config.pipeline.asr_provider = engine_id
    config.asr_engine_specs[engine_id] = spec
    config.asr_user_overrides[engine_id] = original_overrides
    config.asr_capabilities[engine_id] = capabilities
    config.asr_policy_resolutions[engine_id] = policy_resolution
    config.asr_providers[engine_id] = runtime
    return resolution
