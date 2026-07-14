from __future__ import annotations

import os
import re
from dataclasses import replace
from pathlib import Path
from typing import Any

import yaml

from .models import (
    AppConfig,
    AsrAuthConfig,
    AsrChunkingConfig,
    AsrExecutionConfig,
    AsrLocalConfig,
    AsrPreprocessingConfig,
    AsrPromptConfig,
    AsrPromptProfile,
    AsrProviderConfig,
    AsrProviderRequestConfig,
    AsrSilenceChunkingConfig,
    AsrTrimSilenceConfig,
    AsrUncertaintyHintsConfig,
    AssStyleConfig,
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    MemoryBootstrapConfig,
    MemoryConfig,
    MemoryConsistencyCheckConfig,
    MemoryChunkingConfig,
    MemoryInjectConfig,
    MemoryMergeConfig,
    MemoryPatchConfig,
    MemoryPresetRef,
    ModelConfig,
    ModelListConfig,
    PipelineConfig,
    ProviderConfig,
    ProviderLimits,
    RefusalDetectionConfig,
    RepairConfig,
    RoutingProfile,
    RouteTarget,
    RoutingConfig,
    SubtitleCompressionConfig,
    SubtitleConfig,
    SubtitleQualityConfig,
    SubtitleReflowConfig,
    TranslationBatchingConfig,
    TranslationChunkingConfig,
    TranslationConfig,
    TranslationExperimentLoggingConfig,
)
from ..prompts import load_prompt
from ..providers.model_catalog import model_catalog_runtime_config
from .credentials import read_dotenv_values


ARTIFACTS_DIR_ENV = "TRANSVORTEX_ARTIFACTS_DIR"
MEMORY_INJECT_INTENSITIES = {"low", "auto", "high", "max"}
MEMORY_PATCH_MODES = {"serial"}
LEGACY_MEMORY_INJECT_FIELDS = {
    "strategy",
    "max_entries_per_chunk",
    "max_proposed_entries",
    "max_context_only_entries",
}
ASR_PROMPT_ALLOWED_FIELDS = {
    "enabled",
    "active_profile",
    "profiles",
    "include_previous_text",
    "max_chars",
}

ENV_MAP = {
    "chunk_seconds": "TVX_CHUNK_SECONDS",
    "chunk_overlap_seconds": "TVX_CHUNK_OVERLAP_SECONDS",
    "translation_batch_size": "TVX_TRANSLATION_BATCH_SIZE",
    "default_concurrency": "TVX_DEFAULT_CONCURRENCY",
    "timeout_seconds": "TVX_TIMEOUT_SECONDS",
    "retry": "TVX_RETRY",
    "max_cps": "TVX_MAX_CPS",
}


def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _to_float(value: Any, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _to_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _to_str(value: Any, default: str) -> str:
    if value is None:
        return default
    return str(value)


def _to_str_list(value: Any, default: list[str] | None = None) -> list[str]:
    if value is None:
        return list(default or [])
    if isinstance(value, list):
        return [str(item) for item in value if item is not None]
    if isinstance(value, tuple):
        return [str(item) for item in value if item is not None]
    return [str(value)]


def _parse_memory_presets(raw: Any) -> list[MemoryPresetRef]:
    if not isinstance(raw, list):
        return []
    out: list[MemoryPresetRef] = []
    seen: set[str] = set()
    for item in raw:
        if isinstance(item, str):
            ref_id = item.strip()
            override = ""
        elif isinstance(item, dict):
            ref_id = str(item.get("id") or "").strip()
            override = str(item.get("override_status") or "").strip()
        else:
            continue
        if not ref_id or ref_id in seen:
            continue
        seen.add(ref_id)
        out.append(MemoryPresetRef(id=ref_id, override_status=override))
    return out


def _reject_legacy_memory_fields(memory_raw: dict[str, Any], memory_patch_raw: dict[str, Any]) -> None:
    if "workflow" in memory_raw:
        raise ValueError(
            "memory.workflow is no longer supported; use memory.enabled plus "
            "memory.bootstrap.enabled, memory.inject.enabled, and memory.patch.enabled"
        )
    if "mode" in memory_raw:
        raise ValueError(
            "memory.mode is no longer supported; use memory.enabled plus "
            "memory.bootstrap.enabled, memory.inject.enabled, and memory.patch.enabled"
        )
    if "after_each_window" in memory_patch_raw:
        raise ValueError("memory.patch.after_each_window is no longer supported; use memory.patch.enabled and memory.patch.window_chunks")


def _memory_inject_intensity(memory_inject_raw: dict[str, Any]) -> str:
    legacy_fields = sorted(field for field in LEGACY_MEMORY_INJECT_FIELDS if field in memory_inject_raw)
    if legacy_fields:
        raise ValueError(
            "Unsupported legacy memory.inject fields: "
            + ", ".join(legacy_fields)
            + "; use memory.inject.intensity and memory.inject.max_prompt_tokens"
        )
    intensity = _to_str(memory_inject_raw.get("intensity"), "high").strip().lower()
    if intensity not in MEMORY_INJECT_INTENSITIES:
        raise ValueError(
            "Unsupported memory.inject.intensity: "
            f"{intensity}; expected one of: {', '.join(sorted(MEMORY_INJECT_INTENSITIES))}"
        )
    return intensity


def _resolve_prompt_path(root_dir: Path, raw_path: Any) -> Path | None:
    if raw_path is None:
        return None
    text = str(raw_path).strip()
    if not text:
        return None
    path = Path(text)
    return path if path.is_absolute() else root_dir / path


def _safe_read_text(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def _parse_asr_prompt_profiles(root_dir: Path, raw_profiles: Any) -> list[AsrPromptProfile]:
    if not isinstance(raw_profiles, list):
        return []
    profiles: list[AsrPromptProfile] = []
    seen: set[str] = set()
    for item in raw_profiles:
        if not isinstance(item, dict):
            continue
        profile_id = _to_str(item.get("id"), "").strip()
        if not profile_id or profile_id in seen:
            continue
        seen.add(profile_id)
        raw_path = _to_str(item.get("path"), "").strip()
        prompt_path = _resolve_prompt_path(root_dir, raw_path)
        prompt_root = (root_dir / "prompts" / "asr").resolve()
        if prompt_path is not None and prompt_root not in prompt_path.resolve().parents:
            prompt_path = None
        profiles.append(
            AsrPromptProfile(
                id=profile_id,
                name=_to_str(item.get("name"), profile_id),
                scope=_to_str(item.get("scope"), "project"),
                version=_to_int(item.get("version"), 1),
                path=raw_path,
                include_previous_text=_to_bool(item.get("include_previous_text"), False),
                max_chars=_to_int(item.get("max_chars"), 800),
                text=_safe_read_text(prompt_path) if prompt_path is not None else _to_str(item.get("text"), ""),
            )
        )
    return profiles


def _resolve_asr_prompt_config(root_dir: Path, asr_prompt_raw: dict[str, Any]) -> AsrPromptConfig:
    unsupported = sorted(set(asr_prompt_raw) - ASR_PROMPT_ALLOWED_FIELDS)
    if unsupported:
        raise ValueError(f"Unsupported asr.prompt field(s): {', '.join(unsupported)}")
    profiles = _parse_asr_prompt_profiles(root_dir, asr_prompt_raw.get("profiles"))
    active_profile = _to_str(asr_prompt_raw.get("active_profile"), "")
    selected = next((item for item in profiles if item.id == active_profile), None)
    text = ""
    include_previous = _to_bool(asr_prompt_raw.get("include_previous_text"), False)
    max_chars = _to_int(asr_prompt_raw.get("max_chars"), 800)
    if selected is not None:
        text = selected.text
        include_previous = selected.include_previous_text
        max_chars = selected.max_chars
    return AsrPromptConfig(
        enabled=_to_bool(asr_prompt_raw.get("enabled"), True),
        text=text,
        include_previous_text=include_previous,
        max_chars=max_chars,
        active_profile=active_profile,
        profiles=profiles,
    )


def _infer_compat_mode(api_type: str) -> str:
    if api_type in {"openai", "openai-compatible"}:
        return "openai_chat"
    if api_type == "anthropic":
        return "anthropic_messages"
    if api_type == "gemini-compatible":
        return "gemini_generate_content"
    if api_type == "custom":
        return "custom_json"
    raise ValueError(f"Unsupported api_type: {api_type}")


def _default_base_url_for_mode(compat_mode: str) -> str:
    if compat_mode in {"openai_chat", "openai_responses", "openai_completions"}:
        return "https://api.openai.com/v1"
    if compat_mode == "anthropic_messages":
        return "https://api.anthropic.com/v1"
    if compat_mode == "gemini_generate_content":
        return "https://generativelanguage.googleapis.com/v1beta"
    if compat_mode == "vertex_express":
        return "https://aiplatform.googleapis.com/v1"
    if compat_mode == "custom_json":
        return "https://example.com"
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_endpoint_for_mode(compat_mode: str) -> EndpointConfig:
    if compat_mode == "openai_chat":
        return EndpointConfig(path_template="/chat/completions", method="POST")
    if compat_mode == "openai_responses":
        return EndpointConfig(path_template="/responses", method="POST")
    if compat_mode == "openai_completions":
        return EndpointConfig(path_template="/completions", method="POST")
    if compat_mode == "anthropic_messages":
        return EndpointConfig(path_template="/messages", method="POST")
    if compat_mode == "gemini_generate_content":
        return EndpointConfig(path_template="/models/{model}:generateContent", method="POST")
    if compat_mode == "vertex_express":
        return EndpointConfig(path_template="/publishers/google/models/{model}:generateContent", method="POST")
    if compat_mode == "custom_json":
        return EndpointConfig(path_template="/", method="POST")
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_auth_for_mode(compat_mode: str) -> AuthConfig:
    if compat_mode in {"openai_chat", "openai_responses", "openai_completions"}:
        return AuthConfig(type="bearer", header_name="Authorization", prefix="Bearer ")
    if compat_mode == "anthropic_messages":
        return AuthConfig(type="header", header_name="x-api-key", prefix="")
    if compat_mode == "gemini_generate_content":
        return AuthConfig(type="query", query_name="key", prefix="")
    if compat_mode == "vertex_express":
        return AuthConfig(type="query", query_name="key", prefix="")
    if compat_mode == "custom_json":
        return AuthConfig(type="bearer", header_name="Authorization", prefix="Bearer ")
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_mapping_for_mode(compat_mode: str) -> MappingConfig:
    if compat_mode == "openai_chat":
        return MappingConfig(
            request={"style": "openai_chat"},
            response={
                "text_paths": [
                    "choices[0].message.content",
                ]
            },
        )
    if compat_mode == "openai_responses":
        return MappingConfig(
            request={"style": "openai_responses"},
            response={
                "text_paths": [
                    "output_text",
                    "output[].content[].text",
                ]
            },
        )
    if compat_mode == "openai_completions":
        return MappingConfig(
            request={"style": "openai_completions"},
            response={
                "text_paths": [
                    "choices[0].text",
                ]
            },
        )
    if compat_mode == "anthropic_messages":
        return MappingConfig(
            request={"style": "anthropic_messages"},
            response={
                "text_paths": [
                    "content[].text",
                ]
            },
        )
    if compat_mode == "gemini_generate_content":
        return MappingConfig(
            request={"style": "gemini_generate_content"},
            response={
                "text_paths": [
                    "candidates[0].content.parts[].text",
                ]
            },
        )
    if compat_mode == "vertex_express":
        return MappingConfig(
            request={"style": "gemini_generate_content"},
            response={
                "text_paths": [
                    "candidates[0].content.parts[].text",
                ]
            },
        )
    if compat_mode == "custom_json":
        return MappingConfig(
            request={
                "style": "custom_json",
                "body_template": {
                    "model": "{{model}}",
                    "prompt": "{{prompt}}",
                },
            },
            response={"text_paths": ["text", "choices[0].message.content"]},
        )
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_model_list_for_mode(compat_mode: str) -> ModelListConfig:
    if compat_mode in {"openai_chat", "openai_responses", "openai_completions"}:
        return ModelListConfig(path_template="/models", method="GET", response_paths=["data[].id"])
    if compat_mode == "anthropic_messages":
        return ModelListConfig(path_template="/models", method="GET", response_paths=["data[].id"])
    if compat_mode == "gemini_generate_content":
        return ModelListConfig(path_template="/models", method="GET", response_paths=["models[].name", "data[].id"])
    if compat_mode == "vertex_express":
        return ModelListConfig(path_template="", method="GET", response_paths=[])
    if compat_mode == "custom_json":
        return ModelListConfig(path_template="", method="GET", response_paths=[])
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_reasoning_effort_param(compat_mode: str) -> str:
    if compat_mode == "openai_responses":
        return "reasoning.effort"
    if compat_mode == "openai_chat":
        return "reasoning_effort"
    return ""


def _default_reasoning_efforts(compat_mode: str) -> list[str]:
    if compat_mode in {"openai_chat", "openai_responses"}:
        return ["minimal", "low", "medium", "high"]
    return []


def _parse_model_configs(value: Any) -> dict[str, ModelConfig]:
    if not isinstance(value, dict):
        return {}
    parsed: dict[str, ModelConfig] = {}
    for raw_name, raw_config in value.items():
        name = str(raw_name or "").strip()
        if not name or not isinstance(raw_config, dict):
            continue
        reasoning = raw_config.get("reasoning") if isinstance(raw_config.get("reasoning"), dict) else {}
        parsed[name] = ModelConfig(
            max_batch_lines=max(0, _to_int(raw_config.get("max_batch_lines", raw_config.get("maxBatchLines")), 0)),
            max_context_tokens=max(
                0,
                _to_int(raw_config.get("max_context_tokens", raw_config.get("maxContextTokens")), 0),
            ),
            max_input_tokens=max(
                0,
                _to_int(raw_config.get("max_input_tokens", raw_config.get("maxInputTokens")), 0),
            ),
            max_output_tokens=max(
                0,
                _to_int(raw_config.get("max_output_tokens", raw_config.get("maxOutputTokens")), 0),
            ),
            recommended_output_tokens=max(
                0,
                _to_int(
                    raw_config.get("recommended_output_tokens", raw_config.get("recommendedOutputTokens")),
                    0,
                ),
            ),
            reasoning_effort=_to_str(
                raw_config.get(
                    "reasoning_effort",
                    raw_config.get("reasoningEffort", reasoning.get("effort")),
                ),
                "",
            ).strip(),
        )
    return parsed


VERTEX_EXPRESS_DEFAULT_MODELS = [
    "gemini-3.5-flash",
    "gemini-3.1-pro-preview",
    "gemini-3.1-flash-lite-preview",
    "gemini-2.5-flash",
    "gemini-2.5-pro",
    "gemini-2.5-flash-lite",
    "gemini-2.5-flash-lite-preview-09-2025",
]


def _default_models_for_mode(compat_mode: str) -> list[str]:
    if compat_mode == "vertex_express":
        return list(VERTEX_EXPRESS_DEFAULT_MODELS)
    return []


def _merge_dict(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    merged.update(override or {})
    return merged


def _route_target(raw: dict[str, Any] | None) -> RouteTarget:
    raw = raw or {}
    return RouteTarget(provider=str(raw.get("provider", "")), model=str(raw.get("model", "")))


def _route_fallback(raw: Any) -> list[RouteTarget]:
    if not isinstance(raw, list):
        return []
    return [_route_target(item) for item in raw if isinstance(item, dict)]


def _routing_profile_from_row(row: dict[str, Any], fallback_id: str) -> RoutingProfile:
    profile_id = str(row.get("id") or fallback_id).strip() or fallback_id
    profile_name = "" if "name" in row and row.get("name") is None else str(row.get("name", profile_id)).strip()
    return RoutingProfile(
        id=profile_id,
        name=profile_name,
        primary=_route_target(row.get("primary") if isinstance(row.get("primary"), dict) else {}),
        fallback=_route_fallback(row.get("fallback")),
    )


def _profile_seq_from_id(profile_id: str) -> int:
    match = re.fullmatch(r"route_(\d+)", profile_id)
    return int(match.group(1)) if match else 0


def _resolve_routing_profiles(p_yaml: dict[str, Any]) -> tuple[RoutingConfig, list[RoutingProfile], str, int]:
    routing_raw = p_yaml.get("routing") or {}
    if not isinstance(routing_raw, dict):
        routing_raw = {}
    raw_profiles = p_yaml.get("routing_profiles")
    profiles: list[RoutingProfile] = []
    if isinstance(raw_profiles, list):
        for idx, item in enumerate(raw_profiles, start=1):
            if isinstance(item, dict):
                profiles.append(_routing_profile_from_row(item, f"route_{idx}"))
    if not profiles:
        profiles = [
            RoutingProfile(
                id="default",
                name="Default",
                primary=_route_target(routing_raw.get("primary") if isinstance(routing_raw.get("primary"), dict) else {}),
                fallback=_route_fallback(routing_raw.get("fallback")),
            )
        ]
    active_profile = str(routing_raw.get("active_profile") or "").strip()
    active = next((item for item in profiles if item.id == active_profile), None)
    if active is None:
        active = profiles[0]
        active_profile = active.id
    highest_profile_seq = max([_profile_seq_from_id(item.id) for item in profiles] + [0])
    try:
        next_profile_seq = int(routing_raw.get("next_profile_seq", highest_profile_seq + 1))
    except (TypeError, ValueError):
        next_profile_seq = highest_profile_seq + 1
    next_profile_seq = max(next_profile_seq, highest_profile_seq + 1, 1)
    return RoutingConfig(primary=active.primary, fallback=list(active.fallback)), profiles, active_profile, next_profile_seq


ASR_PROVIDER_KINDS = {"local_inprocess", "local_server", "remote"}
ASR_PROVIDER_PROTOCOLS = {"faster_whisper", "openai_transcriptions", "funasr_openai"}
ASR_AUTH_TYPES = {"none", "bearer"}
LEGACY_ASR_FIELDS = {
    "mode",
    "local",
    "cloud",
    "chunking",
    "execution",
    "preprocessing",
}


def _reject_legacy_asr_fields(asr_raw: dict[str, Any]) -> None:
    legacy = sorted(field for field in LEGACY_ASR_FIELDS if field in asr_raw)
    if legacy:
        raise ValueError(
            "Unsupported legacy ASR field(s): "
            + ", ".join(legacy)
            + "; use asr.provider plus asr_providers[].kind/protocol/local/execution/chunking/preprocessing"
        )


def _default_asr_chunking(kind: str, protocol: str = "") -> AsrChunkingConfig:
    if protocol == "funasr_openai":
        return AsrChunkingConfig(
            mode="none",
            window_seconds=3600,
            max_window_seconds=3600,
            min_window_seconds=1,
            overlap_seconds=0,
            short_audio_seconds=3600,
            max_upload_mb=2048.0,
            fuzzy_dedupe=False,
        )
    if kind == "local_server":
        return AsrChunkingConfig(
            mode="silence",
            window_seconds=600,
            max_window_seconds=600,
            min_window_seconds=12,
            overlap_seconds=0,
            short_audio_seconds=600,
            max_upload_mb=256.0,
            fuzzy_dedupe=False,
        )
    return AsrChunkingConfig()


def _default_asr_execution(kind: str) -> AsrExecutionConfig:
    if kind == "remote":
        return AsrExecutionConfig(
            concurrency=8,
            adaptive_concurrency=True,
            min_concurrency=1,
            max_concurrency=8,
            max_inflight_upload_mb=128.0,
            timeout_seconds=300,
            retry=2,
        )
    if kind == "local_server":
        return AsrExecutionConfig(concurrency=1, retry=1, timeout_seconds=300)
    return AsrExecutionConfig(concurrency=1, retry=1, timeout_seconds=300)


def _default_asr_preprocessing(kind: str) -> AsrPreprocessingConfig:
    return AsrPreprocessingConfig(
        trim_silence=AsrTrimSilenceConfig(enabled=(kind == "remote"))
    )


def _parse_asr_auth(raw: Any, *, kind: str) -> AsrAuthConfig:
    auth_raw = raw if isinstance(raw, dict) else {}
    default_type = "bearer" if kind == "remote" else "none"
    auth_type = _to_str(auth_raw.get("type"), default_type).strip().lower()
    if auth_type not in ASR_AUTH_TYPES:
        raise ValueError(f"Unsupported ASR auth.type: {auth_type}")
    env_key = _to_str(auth_raw.get("env_key"), "TVX_MODEL_API_KEY")
    credential_id = _to_str(auth_raw.get("credential_id"), env_key)
    if auth_type == "none":
        env_key = ""
        credential_id = ""
    return AsrAuthConfig(type=auth_type, env_key=env_key, credential_id=credential_id)


def _parse_asr_local(raw: Any, *, model: str) -> AsrLocalConfig:
    local_raw = raw if isinstance(raw, dict) else {}
    return AsrLocalConfig(
        model_size=_to_str(local_raw.get("model_size"), model),
        device=_to_str(local_raw.get("device"), "cuda"),
        compute_type=_to_str(local_raw.get("compute_type"), "int8_float16"),
        max_initial_timestamp=_to_float(local_raw.get("max_initial_timestamp"), 30.0),
        beam_size=_to_int(local_raw.get("beam_size"), 5),
        temperature=_to_float(local_raw.get("temperature"), 0.0),
        condition_on_previous_text=_to_bool(local_raw.get("condition_on_previous_text"), False),
        hotwords=_to_str(local_raw.get("hotwords"), ""),
    )


def _parse_asr_chunking(raw: Any, *, default: AsrChunkingConfig) -> AsrChunkingConfig:
    chunking_raw = raw if isinstance(raw, dict) else {}
    silence_raw = chunking_raw.get("silence") if isinstance(chunking_raw.get("silence"), dict) else {}
    return AsrChunkingConfig(
        mode=_to_str(chunking_raw.get("mode"), default.mode),
        window_seconds=_to_int(chunking_raw.get("window_seconds"), default.window_seconds),
        max_window_seconds=_to_int(chunking_raw.get("max_window_seconds"), default.max_window_seconds),
        min_window_seconds=_to_int(chunking_raw.get("min_window_seconds"), default.min_window_seconds),
        overlap_seconds=_to_int(chunking_raw.get("overlap_seconds"), default.overlap_seconds),
        short_audio_seconds=_to_int(chunking_raw.get("short_audio_seconds"), default.short_audio_seconds),
        max_upload_mb=_to_float(chunking_raw.get("max_upload_mb"), default.max_upload_mb),
        silence=AsrSilenceChunkingConfig(
            noise_db=_to_float(silence_raw.get("noise_db"), default.silence.noise_db),
            min_silence_seconds=_to_float(
                silence_raw.get("min_silence_seconds"),
                default.silence.min_silence_seconds,
            ),
            cut_padding_seconds=_to_float(
                silence_raw.get("cut_padding_seconds"),
                default.silence.cut_padding_seconds,
            ),
            fallback_mode=_to_str(silence_raw.get("fallback_mode"), default.silence.fallback_mode),
        ),
        fuzzy_dedupe=_to_bool(chunking_raw.get("fuzzy_dedupe"), default.fuzzy_dedupe),
    )


def _parse_asr_execution(raw: Any, *, default: AsrExecutionConfig) -> AsrExecutionConfig:
    execution_raw = raw if isinstance(raw, dict) else {}
    concurrency = _to_int(execution_raw.get("concurrency"), default.concurrency)
    return AsrExecutionConfig(
        concurrency=concurrency,
        adaptive_concurrency=_to_bool(execution_raw.get("adaptive_concurrency"), default.adaptive_concurrency),
        min_concurrency=_to_int(execution_raw.get("min_concurrency"), min(default.min_concurrency, concurrency)),
        max_concurrency=_to_int(execution_raw.get("max_concurrency"), max(default.max_concurrency, concurrency)),
        max_inflight_upload_mb=_to_float(
            execution_raw.get("max_inflight_upload_mb"),
            default.max_inflight_upload_mb,
        ),
        timeout_seconds=_to_int(execution_raw.get("timeout_seconds"), default.timeout_seconds),
        retry=_to_int(execution_raw.get("retry"), default.retry),
    )


def _parse_asr_preprocessing(raw: Any, *, default: AsrPreprocessingConfig) -> AsrPreprocessingConfig:
    preprocessing_raw = raw if isinstance(raw, dict) else {}
    trim_raw = preprocessing_raw.get("trim_silence") if isinstance(preprocessing_raw.get("trim_silence"), dict) else {}
    return AsrPreprocessingConfig(
        trim_silence=AsrTrimSilenceConfig(
            enabled=_to_bool(trim_raw.get("enabled"), default.trim_silence.enabled),
            backend=_to_str(trim_raw.get("backend"), default.trim_silence.backend),
            noise_db=_to_float(trim_raw.get("noise_db"), default.trim_silence.noise_db),
            min_silence_seconds=_to_float(
                trim_raw.get("min_silence_seconds"),
                default.trim_silence.min_silence_seconds,
            ),
            keep_preroll_seconds=_to_float(
                trim_raw.get("keep_preroll_seconds"),
                default.trim_silence.keep_preroll_seconds,
            ),
            trim_trailing=_to_bool(trim_raw.get("trim_trailing"), default.trim_silence.trim_trailing),
            keep_postroll_seconds=_to_float(
                trim_raw.get("keep_postroll_seconds"),
                default.trim_silence.keep_postroll_seconds,
            ),
            min_upload_seconds=_to_float(
                trim_raw.get("min_upload_seconds"),
                default.trim_silence.min_upload_seconds,
            ),
        )
    )


def _default_asr_request_for_protocol(protocol: str) -> AsrProviderRequestConfig:
    if protocol == "funasr_openai":
        return AsrProviderRequestConfig(
            timestamp_granularities=[],
            array_format="repeat",
            send_response_format=True,
            send_temperature=False,
            send_timestamp_granularities=False,
            send_language=True,
            send_prompt=False,
        )
    return AsrProviderRequestConfig()


def _parse_asr_provider(row: dict[str, Any]) -> AsrProviderConfig:
    name = str(row.get("name") or "").strip()
    if not name:
        raise ValueError("asr_providers[].name is required")
    kind = _to_str(row.get("kind"), "remote").strip().lower()
    if kind not in ASR_PROVIDER_KINDS:
        raise ValueError(f"Unsupported ASR provider kind: {kind}")
    protocol = _to_str(
        row.get("protocol"),
        "faster_whisper" if kind == "local_inprocess" else "openai_transcriptions",
    ).strip().lower()
    if protocol not in ASR_PROVIDER_PROTOCOLS:
        raise ValueError(f"Unsupported ASR protocol: {protocol}")
    if kind == "local_inprocess" and protocol != "faster_whisper":
        raise ValueError("ASR provider kind local_inprocess requires protocol faster_whisper")
    if kind in {"local_server", "remote"} and protocol not in {"openai_transcriptions", "funasr_openai"}:
        raise ValueError(f"ASR provider kind {kind} requires protocol openai_transcriptions or funasr_openai")
    if protocol == "funasr_openai" and kind != "local_server":
        raise ValueError("ASR protocol funasr_openai requires kind local_server")
    model = _to_str(row.get("model"), "large-v3" if protocol == "faster_whisper" else "whisper-1")
    request_raw = row.get("request") if isinstance(row.get("request"), dict) else {}
    default_execution = _default_asr_execution(kind)
    default_chunking = _default_asr_chunking(kind, protocol)
    default_preprocessing = _default_asr_preprocessing(kind)
    default_request = _default_asr_request_for_protocol(protocol)
    return AsrProviderConfig(
        name=name,
        kind=kind,
        protocol=protocol,
        base_url=_to_str(row.get("base_url"), "https://api.openai.com").rstrip("/"),
        endpoint=_to_str(row.get("endpoint"), "/v1/audio/transcriptions"),
        model=model,
        auth=_parse_asr_auth(row.get("auth"), kind=kind),
        local=_parse_asr_local(row.get("local"), model=model),
        execution=_parse_asr_execution(row.get("execution"), default=default_execution),
        chunking=_parse_asr_chunking(row.get("chunking"), default=default_chunking),
        preprocessing=_parse_asr_preprocessing(row.get("preprocessing"), default=default_preprocessing),
        http2=_to_bool(row.get("http2"), kind == "remote"),
        request=AsrProviderRequestConfig(
            response_format=_to_str(request_raw.get("response_format"), default_request.response_format),
            temperature=_to_float(request_raw.get("temperature"), default_request.temperature),
            timestamp_granularities=_to_str_list(
                request_raw.get("timestamp_granularities"),
                default_request.timestamp_granularities,
            ),
            include=_to_str_list(request_raw.get("include"), default_request.include),
            extra_form_fields=dict(request_raw.get("extra_form_fields") or {})
            if isinstance(request_raw.get("extra_form_fields"), dict)
            else {},
            array_format=_to_str(request_raw.get("array_format"), default_request.array_format),
            send_response_format=_to_bool(
                request_raw.get("send_response_format"),
                default_request.send_response_format,
            ),
            send_temperature=_to_bool(request_raw.get("send_temperature"), default_request.send_temperature),
            send_timestamp_granularities=_to_bool(
                request_raw.get("send_timestamp_granularities"),
                default_request.send_timestamp_granularities,
            ),
            send_language=_to_bool(request_raw.get("send_language"), default_request.send_language),
            send_prompt=_to_bool(request_raw.get("send_prompt"), default_request.send_prompt),
            language_field=_to_str(request_raw.get("language_field"), default_request.language_field),
            prompt_field=_to_str(request_raw.get("prompt_field"), default_request.prompt_field),
        ),
    )


def resolve_providers_file(root_dir: Path, providers_file: Path | None = None) -> Path:
    if providers_file is not None:
        return providers_file
    candidates = [
        root_dir / "providers.local.yaml",
        root_dir / "providers.yaml",
        root_dir / "providers.example.yaml",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return root_dir / "providers.yaml"


def load_app_config(
    *,
    root_dir: Path,
    providers_file: Path | None = None,
    pipeline_file: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> AppConfig:
    cli_overrides = cli_overrides or {}
    providers_file = resolve_providers_file(root_dir, providers_file)
    pipeline_file = pipeline_file or root_dir / "pipeline.yaml"

    p_yaml = _read_yaml(providers_file)
    pip_yaml = _read_yaml(pipeline_file)
    dotenv_values = read_dotenv_values(root_dir)
    prompts_raw = pip_yaml.get("prompts") or {}

    artifacts_value = os.getenv(ARTIFACTS_DIR_ENV, "").strip() or pip_yaml.get(
        "artifacts_dir", "artifacts"
    )
    artifacts_dir = Path(str(artifacts_value or "artifacts")).expanduser()
    asr_raw = pip_yaml.get("asr") or {}
    if not isinstance(asr_raw, dict):
        asr_raw = {}
    _reject_legacy_asr_fields(asr_raw)
    asr_prompt_raw = asr_raw.get("prompt") if isinstance(asr_raw.get("prompt"), dict) else {}
    asr_provider_name = _to_str(asr_raw.get("provider"), "faster_whisper_large_v3")
    asr_provider_rows = pip_yaml.get("asr_providers")
    asr_providers: dict[str, AsrProviderConfig] = {}
    if isinstance(asr_provider_rows, list):
        for row in asr_provider_rows:
            if isinstance(row, dict):
                provider_cfg = _parse_asr_provider(row)
                asr_providers[provider_cfg.name] = provider_cfg
    if not asr_providers:
        default_provider = _parse_asr_provider(
            {
                "name": "faster_whisper_large_v3",
                "kind": "local_inprocess",
                "protocol": "faster_whisper",
                "model": "large-v3",
            }
        )
        asr_providers[default_provider.name] = default_provider
    if asr_provider_name not in asr_providers:
        raise ValueError(f"ASR provider not found: {asr_provider_name}")
    translation_raw = pip_yaml.get("translation") or {}
    legacy_translation_batch_size = _to_int(pip_yaml.get("translation_batch_size"), 120)
    chunk_lines = _to_int(translation_raw.get("chunk_lines"), legacy_translation_batch_size)
    translation_system_prompt = load_prompt(
        "translation_system",
        root_dir=root_dir,
        override_path=_resolve_prompt_path(root_dir, prompts_raw.get("translation_system")),
    )
    style_prompt_default = load_prompt(
        "translation_style_zh-CN",
        root_dir=root_dir,
        override_path=_resolve_prompt_path(root_dir, prompts_raw.get("translation_style")),
    )
    if "style_prompt" in translation_raw:
        style_prompt_default = str(translation_raw.get("style_prompt") or "")
    refusal_raw = translation_raw.get("refusal_detection") or {}
    repair_raw = translation_raw.get("repair") or {}
    asr_uncertainty_raw = translation_raw.get("asr_uncertainty_hints") or {}
    translation_chunking_raw = translation_raw.get("chunking") or {}
    if "memory_entry_tokens" in translation_chunking_raw:
        raise ValueError(
            "translation.chunking.memory_entry_tokens is no longer supported; "
            "use memory.inject.max_prompt_tokens"
        )
    batching_raw = translation_raw.get("batching") or {}
    if "grow_after_successes" in batching_raw:
        raise ValueError(
            "translation.batching.grow_after_successes is no longer supported; "
            "adaptive batching now only splits the current chunk on hard capacity errors"
        )
    experiment_logging_raw = translation_raw.get("experiment_logging") or {}
    translation = TranslationConfig(
        chunk_lines=chunk_lines,
        context_before_lines=_to_int(translation_raw.get("context_before_lines"), 80),
        context_after_lines=_to_int(translation_raw.get("context_after_lines"), 40),
        style_preset=str(translation_raw.get("style_preset", "subtitle_natural")),
        style_prompt=style_prompt_default,
        system_prompt=translation_system_prompt,
        refusal_detection=RefusalDetectionConfig(
            enabled=_to_bool(refusal_raw.get("enabled"), True),
        ),
        repair=RepairConfig(
            enabled=_to_bool(repair_raw.get("enabled"), True),
            max_attempts=_to_int(repair_raw.get("max_attempts"), 2),
        ),
        asr_uncertainty_hints=AsrUncertaintyHintsConfig(
            enabled=_to_bool(asr_uncertainty_raw.get("enabled"), False),
        ),
        chunking=TranslationChunkingConfig(
            mode=_to_str(translation_chunking_raw.get("mode"), "capacity_aware"),
            min_chunk_lines=_to_int(translation_chunking_raw.get("min_chunk_lines"), 120),
            target_chunk_lines=_to_int(translation_chunking_raw.get("target_chunk_lines"), 400),
            max_chunk_lines=_to_int(translation_chunking_raw.get("max_chunk_lines"), 900),
            boundary_window_lines=_to_int(translation_chunking_raw.get("boundary_window_lines"), 80),
            soft_boundary=_to_bool(translation_chunking_raw.get("soft_boundary"), True),
            target_output_tokens=_to_int(translation_chunking_raw.get("target_output_tokens"), 0),
            hard_output_tokens=_to_int(translation_chunking_raw.get("hard_output_tokens"), 0),
            input_safety_ratio=_to_float(translation_chunking_raw.get("input_safety_ratio"), 0.85),
            prompt_overhead_tokens=_to_int(translation_chunking_raw.get("prompt_overhead_tokens"), 1200),
        ),
        batching=TranslationBatchingConfig(
            mode=_to_str(batching_raw.get("mode"), "adaptive"),
            min_chunk_lines=_to_int(batching_raw.get("min_chunk_lines"), 20),
        ),
        experiment_logging=TranslationExperimentLoggingConfig(
            enabled=_to_bool(experiment_logging_raw.get("enabled"), False),
            save_raw_text=_to_bool(experiment_logging_raw.get("save_raw_text"), True),
            save_metrics=_to_bool(experiment_logging_raw.get("save_metrics"), True),
            label=_to_str(experiment_logging_raw.get("label"), ""),
        ),
    )
    subtitle_raw = pip_yaml.get("subtitle") or {}
    quality_raw = subtitle_raw.get("quality") or {}
    legacy_max_cps = _to_int(pip_yaml.get("max_cps"), 20)
    quality = SubtitleQualityConfig(
        enabled=_to_bool(quality_raw.get("enabled"), True),
        mode=_to_str(quality_raw.get("mode"), "balanced"),
        target_cps=_to_int(quality_raw.get("target_cps"), 17),
        hard_max_cps=_to_int(quality_raw.get("hard_max_cps"), legacy_max_cps),
        max_line_width=_to_int(quality_raw.get("max_line_width"), 42),
        max_lines=_to_int(quality_raw.get("max_lines"), 2),
        min_duration_seconds=_to_float(quality_raw.get("min_duration_seconds"), 0.8),
        max_duration_seconds=_to_float(quality_raw.get("max_duration_seconds"), 6.0),
        min_gap_seconds=_to_float(quality_raw.get("min_gap_seconds"), 0.04),
        merge_short_segments=_to_bool(quality_raw.get("merge_short_segments"), False),
        adjust_timing=_to_bool(quality_raw.get("adjust_timing"), True),
    )
    compression_raw = subtitle_raw.get("compression") or {}
    reflow_raw = subtitle_raw.get("reflow") or {}
    subtitle = SubtitleConfig(
        quality=quality,
        compression=SubtitleCompressionConfig(
            enabled=_to_bool(compression_raw.get("enabled"), False),
            max_attempts=_to_int(compression_raw.get("max_attempts"), 1),
        ),
        reflow=SubtitleReflowConfig(
            enabled=_to_bool(reflow_raw.get("enabled"), False),
            trigger=_to_str(reflow_raw.get("trigger"), "fail_only"),
            batch_windows=_to_int(reflow_raw.get("batch_windows"), 10),
            max_windows=_to_int(reflow_raw.get("max_windows"), 30),
            max_window_segments=_to_int(reflow_raw.get("max_window_segments"), 10),
            context_before_segments=_to_int(reflow_raw.get("context_before_segments"), 8),
            context_after_segments=_to_int(reflow_raw.get("context_after_segments"), 8),
            max_input_chars=_to_int(reflow_raw.get("max_input_chars"), 60000),
            max_output_replacements=_to_int(reflow_raw.get("max_output_replacements"), 80),
            memory=_to_bool(reflow_raw.get("memory"), True),
            max_attempts=_to_int(reflow_raw.get("max_attempts"), 2),
            allow_merge=_to_bool(reflow_raw.get("allow_merge"), True),
            allow_drop=_to_bool(reflow_raw.get("allow_drop"), False),
        ),
    )
    memory_raw = pip_yaml.get("memory") or {}
    memory_bootstrap_raw = memory_raw.get("bootstrap") or {}
    memory_chunking_raw = memory_raw.get("chunking") or {}
    memory_inject_raw = memory_raw.get("inject") or {}
    memory_patch_raw = memory_raw.get("patch") or {}
    memory_merge_raw = memory_raw.get("merge") or {}
    memory_check_raw = memory_raw.get("consistency_check") or {}
    memory_presets = _parse_memory_presets(memory_raw.get("presets"))
    _reject_legacy_memory_fields(memory_raw, memory_patch_raw)
    memory_inject_format = _to_str(memory_inject_raw.get("format"), "v2").strip().lower()
    if memory_inject_format != "v2":
        raise ValueError(f"Unsupported memory.inject.format: {memory_inject_format}; only v2 is supported")
    if "enforcement_policy" in memory_check_raw and not _to_bool(memory_check_raw.get("enforcement_policy"), True):
        raise ValueError(
            "memory.consistency_check.enforcement_policy=false is no longer supported; "
            "set memory.consistency_check.enabled=false to disable consistency checks"
        )
    memory_inject_enabled = _to_bool(memory_inject_raw.get("enabled"), True)
    memory_patch_enabled = _to_bool(memory_patch_raw.get("enabled"), False)
    memory_patch_mode = _to_str(memory_patch_raw.get("mode"), "serial").strip().lower()
    if memory_patch_mode not in MEMORY_PATCH_MODES:
        raise ValueError(f"Unsupported memory.patch.mode: {memory_patch_mode}; expected one of: {', '.join(sorted(MEMORY_PATCH_MODES))}")
    memory = MemoryConfig(
        enabled=_to_bool(memory_raw.get("enabled"), True),
        presets=memory_presets,
        bootstrap=MemoryBootstrapConfig(
            enabled=_to_bool(memory_bootstrap_raw.get("enabled"), True),
            mode=_to_str(memory_bootstrap_raw.get("mode"), "whole_document"),
            max_candidates=_to_int(memory_bootstrap_raw.get("max_candidates"), 120),
            system_prompt=load_prompt(
                "memory_bootstrap_system",
                root_dir=root_dir,
                override_path=_resolve_prompt_path(root_dir, prompts_raw.get("memory_bootstrap_system")),
            ),
            pipeline=_to_str(memory_bootstrap_raw.get("pipeline"), "staged"),
            critic_enabled=_to_bool(memory_bootstrap_raw.get("critic_enabled"), False),
        ),
        chunking=MemoryChunkingConfig(
            min_initial_chunk_lines=_to_int(memory_chunking_raw.get("min_initial_chunk_lines"), 80),
            max_initial_chunks=_to_int(memory_chunking_raw.get("max_initial_chunks"), 24),
        ),
        inject=MemoryInjectConfig(
            enabled=memory_inject_enabled,
            locked=_to_bool(memory_inject_raw.get("locked"), True),
            confirmed=_to_bool(memory_inject_raw.get("confirmed"), True),
            proposed=_to_bool(memory_inject_raw.get("proposed"), True),
            intensity=_memory_inject_intensity(memory_inject_raw),
            max_prompt_tokens=_to_int(memory_inject_raw.get("max_prompt_tokens"), 2400),
            max_notes_chars_per_entry=_to_int(memory_inject_raw.get("max_notes_chars_per_entry"), 60),
        ),
        patch=MemoryPatchConfig(
            enabled=memory_patch_enabled,
            mode=memory_patch_mode,
            window_chunks=_to_int(memory_patch_raw.get("window_chunks"), 3),
            system_prompt=load_prompt(
                "memory_patch_system",
                root_dir=root_dir,
                override_path=_resolve_prompt_path(root_dir, prompts_raw.get("memory_patch_system")),
            ),
        ),
        merge=MemoryMergeConfig(
            auto_confirm_high_confidence=_to_bool(memory_merge_raw.get("auto_confirm_high_confidence"), False),
            conflict_policy=_to_str(memory_merge_raw.get("conflict_policy"), "record"),
        ),
        consistency_check=MemoryConsistencyCheckConfig(
            enabled=_to_bool(memory_check_raw.get("enabled"), True),
        ),
    )
    ass_raw = pip_yaml.get("subtitle_ass_style") or {}
    subtitle_ass_style = AssStyleConfig(
        preset=_to_str(ass_raw.get("preset"), "cinematic"),
        play_res_x=_to_int(ass_raw.get("play_res_x"), 1920),
        play_res_y=_to_int(ass_raw.get("play_res_y"), 1080),
        font_name=_to_str(ass_raw.get("font_name"), "Noto Sans SC"),
        font_fallbacks=_to_str_list(
            ass_raw.get("font_fallbacks"),
            ["Microsoft YaHei", "Microsoft YaHei UI", "Source Han Sans SC", "PingFang SC", "Hiragino Sans GB", "Yu Gothic", "Arial Unicode MS", "sans-serif"],
        ),
        font_size=_to_int(ass_raw.get("font_size"), 39),
        bold=_to_int(ass_raw.get("bold"), 0),
        primary_color=_to_str(ass_raw.get("primary_color"), "&H00F6F1EA"),
        secondary_color=_to_str(ass_raw.get("secondary_color"), "&H000000FF"),
        outline_color=_to_str(ass_raw.get("outline_color"), "&H8A000000"),
        back_color=_to_str(ass_raw.get("back_color"), "&H82000000"),
        outline=_to_float(ass_raw.get("outline"), 1.35),
        shadow=_to_float(ass_raw.get("shadow"), 0.18),
        border_style=_to_int(ass_raw.get("border_style"), 1),
        margin_l=_to_int(ass_raw.get("margin_l"), 120),
        margin_r=_to_int(ass_raw.get("margin_r"), 120),
        margin_v=_to_int(ass_raw.get("margin_v"), 76),
        safe_margin_x=_to_int(ass_raw.get("safe_margin_x"), 96),
        safe_margin_y=_to_int(ass_raw.get("safe_margin_y"), 54),
        bilingual_order=_to_str(ass_raw.get("bilingual_order"), "target_source"),
        max_target_lines=_to_int(ass_raw.get("max_target_lines"), 2),
        max_source_lines=_to_int(ass_raw.get("max_source_lines"), 2),
        target_max_width=_to_int(ass_raw.get("target_max_width"), 48),
        source_max_width=_to_int(ass_raw.get("source_max_width"), 58),
        hard_max_width=_to_int(ass_raw.get("hard_max_width"), 64),
        prefer_single_line=_to_bool(ass_raw.get("prefer_single_line"), True),
        bilingual_gap=_to_int(ass_raw.get("bilingual_gap"), 12),
        line_spacing=_to_float(ass_raw.get("line_spacing"), 1.08),
        source_font_name=_to_str(ass_raw.get("source_font_name"), "Yu Gothic"),
        source_font_size=_to_int(ass_raw.get("source_font_size"), 25),
        source_bold=_to_int(ass_raw.get("source_bold"), 0),
        source_primary_color=_to_str(ass_raw.get("source_primary_color"), "&H00D2CBC2"),
        source_outline_color=_to_str(ass_raw.get("source_outline_color"), "&H96000000"),
        source_back_color=_to_str(ass_raw.get("source_back_color"), "&H84000000"),
        source_outline=_to_float(ass_raw.get("source_outline"), 1.05),
        source_shadow=_to_float(ass_raw.get("source_shadow"), 0.14),
        source_margin_v=_to_int(ass_raw.get("source_margin_v"), 128),
        font_file=_to_str(ass_raw.get("font_file"), ""),
    )
    setattr(subtitle_ass_style, "_explicit_fields", set(ass_raw.keys()))
    pipeline = PipelineConfig(
        artifacts_dir=(root_dir / artifacts_dir),
        chunk_seconds=_to_int(pip_yaml.get("chunk_seconds"), 60),
        chunk_overlap_seconds=_to_int(pip_yaml.get("chunk_overlap_seconds"), 1),
        translation_batch_size=chunk_lines,
        translation=translation,
        subtitle=subtitle,
        memory=memory,
        output_format=_to_str(pip_yaml.get("output_format"), "srt"),
        subtitle_ass_style=subtitle_ass_style,
        default_concurrency=_to_int(pip_yaml.get("default_concurrency"), 8),
        timeout_seconds=_to_int(pip_yaml.get("timeout_seconds"), 30),
        retry=_to_int(pip_yaml.get("retry"), 3),
        max_cps=_to_int(pip_yaml.get("max_cps"), 20),
        asr_provider=asr_provider_name,
        asr_audio_track=_to_str(asr_raw.get("audio_track"), "auto"),
        asr_prompt=_resolve_asr_prompt_config(root_dir, asr_prompt_raw),
        source_mode=_to_str(pip_yaml.get("source_mode"), "auto"),
        subtitle_track=_to_str(pip_yaml.get("subtitle_track"), "auto"),
    )

    for field_name, env_name in ENV_MAP.items():
        env_v = dotenv_values.get(env_name)
        if env_name in os.environ:
            env_v = os.environ[env_name]
        if env_v is None:
            continue
        setattr(pipeline, field_name, _to_int(env_v, getattr(pipeline, field_name)))
        if field_name == "translation_batch_size":
            pipeline.translation.chunk_lines = pipeline.translation_batch_size
        elif field_name == "max_cps":
            pipeline.subtitle.quality.hard_max_cps = pipeline.max_cps

    memory_override_keys = {
        "memory_enabled",
        "memory_bootstrap_enabled",
        "memory_inject_enabled",
        "memory_patch_enabled",
        "memory_intensity",
        "memory_patch_window_chunks",
        "memory_presets",
    }
    memory_overrides: dict[str, Any] = {}

    for key, value in cli_overrides.items():
        if value is None:
            continue
        if key in memory_override_keys:
            memory_overrides[key] = value
            continue
        if key == "translation_batch_size":
            pipeline.translation_batch_size = _to_int(value, pipeline.translation_batch_size)
            pipeline.translation.chunk_lines = pipeline.translation_batch_size
        elif key == "translation_style_preset":
            pipeline.translation.style_preset = _to_str(value, pipeline.translation.style_preset)
        elif key == "translation_style_prompt":
            pipeline.translation.style_prompt = _to_str(value, pipeline.translation.style_prompt)
        elif key == "translation_chunk_lines":
            pipeline.translation.chunk_lines = _to_int(value, pipeline.translation.chunk_lines)
            pipeline.translation_batch_size = pipeline.translation.chunk_lines
        elif key == "translation_context_before_lines":
            pipeline.translation.context_before_lines = _to_int(value, pipeline.translation.context_before_lines)
        elif key == "translation_context_after_lines":
            pipeline.translation.context_after_lines = _to_int(value, pipeline.translation.context_after_lines)
        elif key == "translation_repair_enabled":
            pipeline.translation.repair.enabled = _to_bool(value, pipeline.translation.repair.enabled)
        elif key == "translation_batching_mode":
            pipeline.translation.batching.mode = _to_str(value, pipeline.translation.batching.mode)
        elif key == "translation_min_chunk_lines":
            pipeline.translation.batching.min_chunk_lines = _to_int(value, pipeline.translation.batching.min_chunk_lines)
        elif key == "translation_chunking_mode":
            pipeline.translation.chunking.mode = _to_str(value, pipeline.translation.chunking.mode)
        elif key == "translation_asr_uncertainty_hints_enabled":
            pipeline.translation.asr_uncertainty_hints.enabled = _to_bool(
                value,
                pipeline.translation.asr_uncertainty_hints.enabled,
            )
        elif key == "translation_experiment_logging_enabled":
            pipeline.translation.experiment_logging.enabled = _to_bool(
                value,
                pipeline.translation.experiment_logging.enabled,
            )
        elif key == "translation_experiment_label":
            pipeline.translation.experiment_logging.label = _to_str(value, pipeline.translation.experiment_logging.label)
        elif key == "provider_timeout_seconds":
            pipeline.timeout_seconds = _to_int(value, pipeline.timeout_seconds)
        elif key == "provider_retry":
            pipeline.retry = _to_int(value, pipeline.retry)
        elif key == "asr_provider":
            provider_name = _to_str(value, pipeline.asr_provider)
            if provider_name not in asr_providers:
                raise ValueError(f"ASR provider not found: {provider_name}")
            pipeline.asr_provider = provider_name
        elif key == "asr_model":
            provider = asr_providers[pipeline.asr_provider]
            provider.model = _to_str(value, provider.model)
            if provider.protocol == "faster_whisper":
                provider.local.model_size = provider.model
        elif key == "asr_audio_track":
            pipeline.asr_audio_track = _to_str(value, pipeline.asr_audio_track)
        elif key == "asr_prompt_profile":
            profile_id = _to_str(value, pipeline.asr_prompt.active_profile)
            pipeline.asr_prompt.active_profile = profile_id
            selected_profile = next((item for item in pipeline.asr_prompt.profiles if item.id == profile_id), None)
            if selected_profile is not None:
                pipeline.asr_prompt.text = selected_profile.text
                pipeline.asr_prompt.include_previous_text = selected_profile.include_previous_text
                pipeline.asr_prompt.max_chars = selected_profile.max_chars
        elif key == "asr_prompt_text":
            pipeline.asr_prompt.text = _to_str(value, pipeline.asr_prompt.text)
        elif key == "asr_prompt_enabled":
            pipeline.asr_prompt.enabled = _to_bool(value, pipeline.asr_prompt.enabled)
        elif key == "asr_prompt_include_previous_text":
            pipeline.asr_prompt.include_previous_text = _to_bool(value, pipeline.asr_prompt.include_previous_text)
        elif key == "asr_prompt_max_chars":
            pipeline.asr_prompt.max_chars = _to_int(value, pipeline.asr_prompt.max_chars)
        elif key == "source_mode":
            pipeline.source_mode = _to_str(value, pipeline.source_mode)
        elif key == "subtitle_track":
            pipeline.subtitle_track = _to_str(value, pipeline.subtitle_track)
        elif key == "subtitle_quality_mode":
            pipeline.subtitle.quality.mode = _to_str(value, pipeline.subtitle.quality.mode)
            pipeline.subtitle.quality.enabled = pipeline.subtitle.quality.mode != "off"
        elif key == "subtitle_compression_enabled":
            pipeline.subtitle.compression.enabled = _to_bool(value, pipeline.subtitle.compression.enabled)
        elif key == "subtitle_reflow_enabled":
            pipeline.subtitle.reflow.enabled = _to_bool(value, pipeline.subtitle.reflow.enabled)
        elif key == "subtitle_ass_style" and isinstance(value, dict):
            explicit_fields = set(getattr(pipeline.subtitle_ass_style, "_explicit_fields", set()) or set())
            for style_key, style_value in value.items():
                if hasattr(pipeline.subtitle_ass_style, style_key):
                    current = getattr(pipeline.subtitle_ass_style, style_key)
                    if isinstance(current, bool):
                        setattr(pipeline.subtitle_ass_style, style_key, _to_bool(style_value, current))
                    elif isinstance(current, int):
                        setattr(pipeline.subtitle_ass_style, style_key, _to_int(style_value, current))
                    elif isinstance(current, float):
                        setattr(pipeline.subtitle_ass_style, style_key, _to_float(style_value, current))
                    elif isinstance(current, list):
                        setattr(pipeline.subtitle_ass_style, style_key, _to_str_list(style_value, current))
                    else:
                        setattr(pipeline.subtitle_ass_style, style_key, _to_str(style_value, current))
                    explicit_fields.add(style_key)
            setattr(pipeline.subtitle_ass_style, "_explicit_fields", explicit_fields)
        elif hasattr(pipeline, key):
            setattr(pipeline, key, value)
            if key == "max_cps":
                pipeline.subtitle.quality.hard_max_cps = _to_int(value, pipeline.subtitle.quality.hard_max_cps)

    if "memory_enabled" in memory_overrides:
        pipeline.memory.enabled = _to_bool(memory_overrides["memory_enabled"], pipeline.memory.enabled)
    if "memory_bootstrap_enabled" in memory_overrides:
        pipeline.memory.bootstrap.enabled = _to_bool(
            memory_overrides["memory_bootstrap_enabled"],
            pipeline.memory.bootstrap.enabled,
        )
    if "memory_inject_enabled" in memory_overrides:
        pipeline.memory.inject.enabled = _to_bool(
            memory_overrides["memory_inject_enabled"],
            pipeline.memory.inject.enabled,
        )
    if "memory_patch_enabled" in memory_overrides:
        pipeline.memory.patch.enabled = _to_bool(
            memory_overrides["memory_patch_enabled"],
            pipeline.memory.patch.enabled,
        )
    if "memory_intensity" in memory_overrides:
        intensity = _to_str(memory_overrides["memory_intensity"], pipeline.memory.inject.intensity).strip().lower()
        if intensity not in MEMORY_INJECT_INTENSITIES:
            raise ValueError(
                f"Unsupported memory_intensity override: {intensity}; "
                f"expected one of: {', '.join(sorted(MEMORY_INJECT_INTENSITIES))}"
            )
        pipeline.memory.inject.intensity = intensity
    if "memory_patch_window_chunks" in memory_overrides:
        pipeline.memory.patch.window_chunks = _to_int(
            memory_overrides["memory_patch_window_chunks"],
            pipeline.memory.patch.window_chunks,
        )
    if "memory_presets" in memory_overrides:
        pipeline.memory.presets = _parse_memory_presets(memory_overrides["memory_presets"])
    providers: dict[str, ProviderConfig] = {}
    for row in p_yaml.get("providers", []):
        api_type = row["api_type"]
        compat_mode = row.get("compat_mode") or _infer_compat_mode(api_type)
        limits_raw = row.get("limits", {})
        timeout_seconds = _to_int(
            cli_overrides.get("provider_timeout_seconds", limits_raw.get("timeout_seconds")),
            pipeline.timeout_seconds,
        )
        limits = ProviderLimits(
            concurrency=_to_int(limits_raw.get("concurrency"), pipeline.default_concurrency),
            timeout_seconds=timeout_seconds,
            retry=_to_int(cli_overrides.get("provider_retry", limits_raw.get("retry")), pipeline.retry),
            connect_timeout_seconds=_to_float(
                cli_overrides.get("provider_connect_timeout_seconds", limits_raw.get("connect_timeout_seconds")),
                min(10.0, float(timeout_seconds)),
            ),
            read_timeout_seconds=_to_float(
                cli_overrides.get("provider_read_timeout_seconds", limits_raw.get("read_timeout_seconds")),
                float(timeout_seconds),
            ),
            write_timeout_seconds=_to_float(
                limits_raw.get("write_timeout_seconds"),
                float(timeout_seconds),
            ),
            pool_timeout_seconds=_to_float(
                limits_raw.get("pool_timeout_seconds"),
                5.0,
            ),
            max_connections=_to_int(limits_raw.get("max_connections"), 20),
            max_keepalive_connections=_to_int(limits_raw.get("max_keepalive_connections"), 10),
            http2=_to_bool(cli_overrides.get("provider_http2", limits_raw.get("http2")), True),
            streaming_enabled=_to_bool(
                cli_overrides.get("provider_streaming_enabled", limits_raw.get("streaming_enabled")),
                True,
            ),
        )
        endpoint_default = _default_endpoint_for_mode(compat_mode)
        endpoint_raw = row.get("endpoint", {})
        endpoint = EndpointConfig(
            path_template=str(endpoint_raw.get("path_template", endpoint_default.path_template)),
            method=str(endpoint_raw.get("method", endpoint_default.method)).upper(),
        )
        auth_default = _default_auth_for_mode(compat_mode)
        auth_raw = row.get("auth", {})
        auth = AuthConfig(
            type=str(auth_raw.get("type", auth_default.type)),
            header_name=str(auth_raw.get("header_name", auth_default.header_name)),
            query_name=str(auth_raw.get("query_name", auth_default.query_name)),
            prefix=str(auth_raw.get("prefix", auth_default.prefix)),
        )
        mapping_default = _default_mapping_for_mode(compat_mode)
        mapping = MappingConfig(
            request=_merge_dict(mapping_default.request, row.get("request_mapping", {})),
            response=_merge_dict(mapping_default.response, row.get("response_mapping", {})),
        )
        model_list_default = _default_model_list_for_mode(compat_mode)
        model_list_raw = row.get("model_list", {})
        model_list = ModelListConfig(
            path_template=str(model_list_raw.get("path_template", model_list_default.path_template)),
            method=str(model_list_raw.get("method", model_list_default.method)).upper(),
            response_paths=list(model_list_raw.get("response_paths", model_list_default.response_paths)),
        )
        capabilities_raw = row.get("capabilities", {})
        capabilities = CapabilityConfig(
            supports_system_prompt=bool(capabilities_raw.get("supports_system_prompt", capabilities_raw.get("supportsSystemPrompt", True))),
            supports_temperature=bool(capabilities_raw.get("supports_temperature", capabilities_raw.get("supportsTemperature", True))),
            supports_json_mode=bool(capabilities_raw.get("supports_json_mode", capabilities_raw.get("supportsJsonMode", False))),
            max_batch_lines=_to_int(capabilities_raw.get("max_batch_lines", capabilities_raw.get("maxBatchLines")), 200),
            max_context_tokens=_to_int(capabilities_raw.get("max_context_tokens", capabilities_raw.get("maxContextTokens")), 0),
            max_input_tokens=_to_int(
                capabilities_raw.get("max_input_tokens", capabilities_raw.get("maxInputTokens")),
                0,
            ),
            max_output_tokens=_to_int(capabilities_raw.get("max_output_tokens", capabilities_raw.get("maxOutputTokens")), 0),
            recommended_output_tokens=_to_int(
                capabilities_raw.get("recommended_output_tokens", capabilities_raw.get("recommendedOutputTokens")),
                0,
            ),
            output_token_param=_to_str(capabilities_raw.get("output_token_param", capabilities_raw.get("outputTokenParam")), ""),
            reasoning_effort_param=_to_str(
                capabilities_raw.get("reasoning_effort_param", capabilities_raw.get("reasoningEffortParam")),
                _default_reasoning_effort_param(compat_mode),
            ),
            reasoning_efforts=[
                str(item).strip()
                for item in _to_str_list(
                    capabilities_raw.get("reasoning_efforts", capabilities_raw.get("reasoningEfforts"))
                )
                if str(item).strip()
            ]
            or _default_reasoning_efforts(compat_mode),
        )
        models = [str(item).strip() for item in _to_str_list(row.get("models")) if str(item).strip()]
        if not models:
            models = _default_models_for_mode(compat_mode)
        catalog_model_configs = {
            model: ModelConfig(**catalog_config)
            for model in models
            if (catalog_config := model_catalog_runtime_config(model))
        }
        cfg = ProviderConfig(
            name=row["name"],
            api_type=api_type,
            base_url=_to_str(row.get("base_url"), _default_base_url_for_mode(compat_mode)).rstrip("/"),
            env_key=row["env_key"],
            models=models,
            model_configs=_parse_model_configs(row.get("model_configs", row.get("modelConfigs"))),
            catalog_model_configs=catalog_model_configs,
            credential_id=str(row.get("credential_id", row["name"])),
            credential_root_dir=root_dir,
            compat_mode=compat_mode,
            auth=auth,
            endpoint=endpoint,
            mapping=mapping,
            extra_headers={str(k): str(v) for k, v in (row.get("extra_headers") or {}).items()},
            model_list=model_list,
            capabilities=capabilities,
            limits=limits,
        )
        providers[cfg.name] = cfg

    routing, routing_profiles, active_routing_profile, routing_profile_next_seq = _resolve_routing_profiles(p_yaml)
    return AppConfig(
        pipeline=pipeline,
        providers=providers,
        routing=routing,
        routing_profiles=routing_profiles,
        active_routing_profile=active_routing_profile,
        routing_profile_next_seq=routing_profile_next_seq,
        asr_providers=asr_providers,
    )


def apply_route_overrides(
    config: AppConfig,
    *,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | RoutingConfig | None = None,
) -> AppConfig:
    if routing is not None:
        if isinstance(routing, RoutingConfig):
            next_routing = routing
        elif isinstance(routing, dict):
            next_routing = RoutingConfig(
                primary=_route_target(routing.get("primary") if isinstance(routing.get("primary"), dict) else {}),
                fallback=_route_fallback(routing.get("fallback")),
            )
        else:
            raise ValueError("routing override must be an object")
        return replace(config, routing=next_routing)
    if not provider_name and not model:
        return config
    primary = replace(
        config.routing.primary,
        provider=provider_name or config.routing.primary.provider,
        model=model or config.routing.primary.model,
    )
    return replace(config, routing=replace(config.routing, primary=primary))
