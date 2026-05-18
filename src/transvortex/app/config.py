from __future__ import annotations

import os
import re
from dataclasses import replace
from pathlib import Path
from typing import Any

import yaml

from .models import (
    AppConfig,
    AsrChunkingConfig,
    AsrCloudConfig,
    AsrCloudTrimSilenceConfig,
    AsrExecutionConfig,
    AsrLocalConfig,
    AsrPreprocessingConfig,
    AsrPromptConfig,
    AsrProviderConfig,
    AsrProviderRequestConfig,
    AsrSilenceChunkingConfig,
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
)
from ..prompts import load_prompt
from .credentials import read_dotenv_values


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


def _resolve_prompt_path(root_dir: Path, raw_path: Any) -> Path | None:
    if raw_path is None:
        return None
    text = str(raw_path).strip()
    if not text:
        return None
    path = Path(text)
    return path if path.is_absolute() else root_dir / path


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
    if compat_mode == "custom_json":
        return ModelListConfig(path_template="", method="GET", response_paths=[])
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


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


def _parse_asr_provider(row: dict[str, Any]) -> AsrProviderConfig:
    name = str(row.get("name") or "").strip()
    if not name:
        raise ValueError("asr_providers[].name is required")
    env_key = _to_str(row.get("env_key"), "TVX_MODEL_API_KEY")
    request_raw = row.get("request") if isinstance(row.get("request"), dict) else {}
    return AsrProviderConfig(
        name=name,
        protocol=_to_str(row.get("protocol"), "openai_transcriptions"),
        base_url=_to_str(row.get("base_url"), "https://api.openai.com").rstrip("/"),
        endpoint=_to_str(row.get("endpoint"), "/v1/audio/transcriptions"),
        model=_to_str(row.get("model"), "whisper-1"),
        env_key=env_key,
        credential_id=_to_str(row.get("credential_id"), env_key),
        timeout_seconds=_to_int(row.get("timeout_seconds"), 300),
        retry=_to_int(row.get("retry"), 2),
        request=AsrProviderRequestConfig(
            response_format=_to_str(request_raw.get("response_format"), "verbose_json"),
            temperature=_to_float(request_raw.get("temperature"), 0.0),
            timestamp_granularities=_to_str_list(request_raw.get("timestamp_granularities"), ["segment"]),
            include=_to_str_list(request_raw.get("include"), []),
            extra_form_fields=dict(request_raw.get("extra_form_fields") or {})
            if isinstance(request_raw.get("extra_form_fields"), dict)
            else {},
            array_format=_to_str(request_raw.get("array_format"), "brackets"),
        ),
    )


def _legacy_asr_provider_from_cloud(asr_cloud_raw: dict[str, Any]) -> AsrProviderConfig:
    env_key = _to_str(asr_cloud_raw.get("env_key"), "TVX_MODEL_API_KEY")
    return AsrProviderConfig(
        name="openai_whisper_legacy",
        protocol="openai_transcriptions",
        base_url=_to_str(asr_cloud_raw.get("base_url"), "https://api.openai.com").rstrip("/"),
        endpoint=_to_str(asr_cloud_raw.get("endpoint"), "/v1/audio/transcriptions"),
        model=_to_str(asr_cloud_raw.get("model"), "whisper-1"),
        env_key=env_key,
        credential_id=_to_str(asr_cloud_raw.get("credential_id"), env_key),
        timeout_seconds=_to_int(asr_cloud_raw.get("timeout_seconds"), 300),
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

    artifacts_dir = Path(pip_yaml.get("artifacts_dir", "artifacts"))
    asr_raw = pip_yaml.get("asr") or {}
    asr_local_raw = asr_raw.get("local") or {}
    asr_cloud_raw = asr_raw.get("cloud") or {}
    asr_chunking_raw = asr_raw.get("chunking") or {}
    asr_chunking_silence_raw = (
        asr_chunking_raw.get("silence") if isinstance(asr_chunking_raw.get("silence"), dict) else {}
    ) or {}
    asr_execution_raw = asr_raw.get("execution") if isinstance(asr_raw.get("execution"), dict) else {}
    asr_prompt_raw = asr_raw.get("prompt") if isinstance(asr_raw.get("prompt"), dict) else {}
    asr_preprocessing_raw = asr_raw.get("preprocessing") or {}
    cloud_trim_silence_raw = (
        asr_preprocessing_raw.get("cloud_trim_silence") if isinstance(asr_preprocessing_raw, dict) else {}
    ) or {}
    asr_mode = _to_str(asr_raw.get("mode"), "local")
    if asr_mode not in {"local", "cloud"}:
        raise ValueError(f"Unsupported asr.mode: {asr_mode}")
    asr_provider_name = _to_str(asr_raw.get("provider"), "")
    asr_provider_rows = pip_yaml.get("asr_providers")
    asr_providers: dict[str, AsrProviderConfig] = {}
    if isinstance(asr_provider_rows, list):
        for row in asr_provider_rows:
            if isinstance(row, dict):
                provider_cfg = _parse_asr_provider(row)
                asr_providers[provider_cfg.name] = provider_cfg
    if not asr_providers:
        legacy_provider = _legacy_asr_provider_from_cloud(asr_cloud_raw)
        asr_providers[legacy_provider.name] = legacy_provider
        if not asr_provider_name:
            asr_provider_name = legacy_provider.name
    elif not asr_provider_name:
        asr_provider_name = next(iter(asr_providers))
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
    batching_raw = translation_raw.get("batching") or {}
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
        ),
        batching=TranslationBatchingConfig(
            mode=_to_str(batching_raw.get("mode"), "adaptive"),
            min_chunk_lines=_to_int(batching_raw.get("min_chunk_lines"), 20),
            grow_after_successes=_to_int(batching_raw.get("grow_after_successes"), 3),
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
        merge_short_segments=_to_bool(quality_raw.get("merge_short_segments"), True),
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
    memory_patch_enabled = _to_bool(memory_patch_raw.get("enabled"), False)
    memory = MemoryConfig(
        enabled=_to_bool(memory_raw.get("enabled"), True),
        mode=_to_str(memory_raw.get("mode"), "bootstrap_first"),
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
        ),
        chunking=MemoryChunkingConfig(
            min_initial_chunk_lines=_to_int(memory_chunking_raw.get("min_initial_chunk_lines"), 80),
            max_initial_chunks=_to_int(memory_chunking_raw.get("max_initial_chunks"), 24),
        ),
        inject=MemoryInjectConfig(
            locked=_to_bool(memory_inject_raw.get("locked"), True),
            confirmed=_to_bool(memory_inject_raw.get("confirmed"), True),
            proposed=_to_bool(memory_inject_raw.get("proposed"), True),
            strategy=_to_str(memory_inject_raw.get("strategy"), "balanced"),
            max_entries_per_chunk=_to_int(memory_inject_raw.get("max_entries_per_chunk"), 30),
        ),
        patch=MemoryPatchConfig(
            enabled=memory_patch_enabled,
            after_each_window=_to_bool(memory_patch_raw.get("after_each_window"), memory_patch_enabled),
            window_chunks=_to_int(memory_patch_raw.get("window_chunks"), 8),
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
        font_name=_to_str(ass_raw.get("font_name"), "Microsoft YaHei"),
        font_size=_to_int(ass_raw.get("font_size"), 42),
        primary_color=_to_str(ass_raw.get("primary_color"), "&H00FFFFFF"),
        outline_color=_to_str(ass_raw.get("outline_color"), "&H00000000"),
        back_color=_to_str(ass_raw.get("back_color"), "&H64000000"),
        outline=_to_int(ass_raw.get("outline"), 2),
        shadow=_to_int(ass_raw.get("shadow"), 1),
        margin_v=_to_int(ass_raw.get("margin_v"), 48),
        bilingual_order=_to_str(ass_raw.get("bilingual_order"), "target_source"),
        source_font_size=_to_int(ass_raw.get("source_font_size"), 30),
        source_primary_color=_to_str(ass_raw.get("source_primary_color"), "&H00B8B8B8"),
        source_margin_v=_to_int(ass_raw.get("source_margin_v"), 104),
    )
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
        asr_mode=asr_mode,
        asr_provider=asr_provider_name,
        asr_local=AsrLocalConfig(
            model_size=_to_str(asr_local_raw.get("model_size"), "small"),
            device=_to_str(asr_local_raw.get("device"), "auto"),
            compute_type=_to_str(asr_local_raw.get("compute_type"), "int8"),
            max_initial_timestamp=_to_float(asr_local_raw.get("max_initial_timestamp"), 30.0),
        ),
        asr_cloud=AsrCloudConfig(
            base_url=_to_str(asr_cloud_raw.get("base_url"), "https://api.openai.com"),
            endpoint=_to_str(asr_cloud_raw.get("endpoint"), "/v1/audio/transcriptions"),
            model=_to_str(asr_cloud_raw.get("model"), "whisper-1"),
            env_key=_to_str(asr_cloud_raw.get("env_key"), "TVX_MODEL_API_KEY"),
            credential_id=_to_str(asr_cloud_raw.get("credential_id"), _to_str(asr_cloud_raw.get("env_key"), "TVX_MODEL_API_KEY")),
            timeout_seconds=_to_int(asr_cloud_raw.get("timeout_seconds"), 300),
        ),
        asr_chunking=AsrChunkingConfig(
            mode=_to_str(asr_chunking_raw.get("mode"), "silence"),
            window_seconds=_to_int(asr_chunking_raw.get("window_seconds"), 300),
            max_window_seconds=_to_int(asr_chunking_raw.get("max_window_seconds"), 120),
            min_window_seconds=_to_int(asr_chunking_raw.get("min_window_seconds"), 12),
            overlap_seconds=_to_int(asr_chunking_raw.get("overlap_seconds"), 5),
            short_audio_seconds=_to_int(asr_chunking_raw.get("short_audio_seconds"), 300),
            max_upload_mb=_to_float(asr_chunking_raw.get("max_upload_mb"), 24.0),
            silence=AsrSilenceChunkingConfig(
                noise_db=_to_float(asr_chunking_silence_raw.get("noise_db"), -35.0),
                min_silence_seconds=_to_float(asr_chunking_silence_raw.get("min_silence_seconds"), 0.25),
                cut_padding_seconds=_to_float(asr_chunking_silence_raw.get("cut_padding_seconds"), 0.15),
                fallback_mode=_to_str(asr_chunking_silence_raw.get("fallback_mode"), "hard_cut"),
            ),
            fuzzy_dedupe=_to_bool(asr_chunking_raw.get("fuzzy_dedupe"), True),
        ),
        asr_execution=AsrExecutionConfig(
            cloud_concurrency=_to_int(asr_execution_raw.get("cloud_concurrency"), 8),
            adaptive_concurrency=_to_bool(asr_execution_raw.get("adaptive_concurrency"), True),
            min_cloud_concurrency=_to_int(asr_execution_raw.get("min_cloud_concurrency"), 1),
            max_cloud_concurrency=_to_int(asr_execution_raw.get("max_cloud_concurrency"), 8),
            max_inflight_upload_mb=_to_float(asr_execution_raw.get("max_inflight_upload_mb"), 128.0),
        ),
        asr_audio_track=_to_str(asr_raw.get("audio_track"), "auto"),
        asr_preprocessing=AsrPreprocessingConfig(
            cloud_trim_silence=AsrCloudTrimSilenceConfig(
                enabled=_to_bool(cloud_trim_silence_raw.get("enabled"), True),
                backend=_to_str(cloud_trim_silence_raw.get("backend"), "ffmpeg_silencedetect"),
                noise_db=_to_float(cloud_trim_silence_raw.get("noise_db"), -35.0),
                min_silence_seconds=_to_float(cloud_trim_silence_raw.get("min_silence_seconds"), 0.2),
                keep_preroll_seconds=_to_float(cloud_trim_silence_raw.get("keep_preroll_seconds"), 0.25),
                trim_trailing=_to_bool(cloud_trim_silence_raw.get("trim_trailing"), True),
                keep_postroll_seconds=_to_float(cloud_trim_silence_raw.get("keep_postroll_seconds"), 0.1),
                min_upload_seconds=_to_float(cloud_trim_silence_raw.get("min_upload_seconds"), 0.5),
            )
        ),
        asr_prompt=AsrPromptConfig(
            enabled=_to_bool(asr_prompt_raw.get("enabled"), True),
            text=_to_str(asr_prompt_raw.get("text"), ""),
            include_previous_text=_to_bool(asr_prompt_raw.get("include_previous_text"), False),
            max_chars=_to_int(asr_prompt_raw.get("max_chars"), 800),
        ),
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

    for key, value in cli_overrides.items():
        if value is None:
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
        elif key == "translation_asr_uncertainty_hints_enabled":
            pipeline.translation.asr_uncertainty_hints.enabled = _to_bool(
                value,
                pipeline.translation.asr_uncertainty_hints.enabled,
            )
        elif key == "provider_timeout_seconds":
            pipeline.timeout_seconds = _to_int(value, pipeline.timeout_seconds)
        elif key == "provider_retry":
            pipeline.retry = _to_int(value, pipeline.retry)
        elif key == "asr_device":
            pipeline.asr_local.device = _to_str(value, pipeline.asr_local.device)
        elif key == "asr_model_size":
            pipeline.asr_local.model_size = _to_str(value, pipeline.asr_local.model_size)
        elif key == "asr_compute_type":
            pipeline.asr_local.compute_type = _to_str(value, pipeline.asr_local.compute_type)
        elif key == "asr_max_initial_timestamp":
            pipeline.asr_local.max_initial_timestamp = _to_float(value, pipeline.asr_local.max_initial_timestamp)
        elif key == "asr_provider":
            pipeline.asr_provider = _to_str(value, pipeline.asr_provider)
        elif key == "asr_cloud_base_url":
            pipeline.asr_cloud.base_url = _to_str(value, pipeline.asr_cloud.base_url)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].base_url = pipeline.asr_cloud.base_url.rstrip("/")
        elif key == "asr_cloud_endpoint":
            pipeline.asr_cloud.endpoint = _to_str(value, pipeline.asr_cloud.endpoint)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].endpoint = pipeline.asr_cloud.endpoint
        elif key == "asr_cloud_model":
            pipeline.asr_cloud.model = _to_str(value, pipeline.asr_cloud.model)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].model = pipeline.asr_cloud.model
        elif key == "asr_cloud_env_key":
            pipeline.asr_cloud.env_key = _to_str(value, pipeline.asr_cloud.env_key)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].env_key = pipeline.asr_cloud.env_key
        elif key == "asr_cloud_credential_id":
            pipeline.asr_cloud.credential_id = _to_str(value, pipeline.asr_cloud.credential_id)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].credential_id = pipeline.asr_cloud.credential_id
        elif key == "asr_cloud_timeout_seconds":
            pipeline.asr_cloud.timeout_seconds = _to_int(value, pipeline.asr_cloud.timeout_seconds)
            if pipeline.asr_provider in asr_providers:
                asr_providers[pipeline.asr_provider].timeout_seconds = pipeline.asr_cloud.timeout_seconds
        elif key == "asr_chunking_mode":
            pipeline.asr_chunking.mode = _to_str(value, pipeline.asr_chunking.mode)
        elif key == "asr_window_seconds":
            pipeline.asr_chunking.window_seconds = _to_int(value, pipeline.asr_chunking.window_seconds)
            pipeline.asr_chunking.max_window_seconds = pipeline.asr_chunking.window_seconds
        elif key == "asr_overlap_seconds":
            pipeline.asr_chunking.overlap_seconds = _to_int(value, pipeline.asr_chunking.overlap_seconds)
        elif key == "asr_max_upload_mb":
            pipeline.asr_chunking.max_upload_mb = _to_float(value, pipeline.asr_chunking.max_upload_mb)
        elif key == "asr_short_audio_seconds":
            pipeline.asr_chunking.short_audio_seconds = _to_int(value, pipeline.asr_chunking.short_audio_seconds)
        elif key == "asr_fuzzy_dedupe":
            pipeline.asr_chunking.fuzzy_dedupe = _to_bool(value, pipeline.asr_chunking.fuzzy_dedupe)
        elif key == "asr_audio_track":
            pipeline.asr_audio_track = _to_str(value, pipeline.asr_audio_track)
        elif key == "asr_cloud_concurrency":
            pipeline.asr_execution.cloud_concurrency = _to_int(value, pipeline.asr_execution.cloud_concurrency)
            pipeline.asr_execution.max_cloud_concurrency = max(
                pipeline.asr_execution.cloud_concurrency,
                pipeline.asr_execution.max_cloud_concurrency,
            )
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
        elif key == "memory_enabled":
            pipeline.memory.enabled = _to_bool(value, pipeline.memory.enabled)
        elif key == "memory_patch_enabled":
            patch_enabled = _to_bool(value, pipeline.memory.patch.enabled)
            pipeline.memory.patch.enabled = patch_enabled
            pipeline.memory.patch.after_each_window = patch_enabled
        elif key == "memory_patch_window_chunks":
            pipeline.memory.patch.window_chunks = _to_int(value, pipeline.memory.patch.window_chunks)
        elif key == "memory_presets":
            pipeline.memory.presets = _parse_memory_presets(value)
        elif key == "subtitle_ass_style" and isinstance(value, dict):
            for style_key, style_value in value.items():
                if hasattr(pipeline.subtitle_ass_style, style_key):
                    current = getattr(pipeline.subtitle_ass_style, style_key)
                    if isinstance(current, int):
                        setattr(pipeline.subtitle_ass_style, style_key, _to_int(style_value, current))
                    else:
                        setattr(pipeline.subtitle_ass_style, style_key, _to_str(style_value, current))
        elif hasattr(pipeline, key):
            setattr(pipeline, key, value)
            if key == "max_cps":
                pipeline.subtitle.quality.hard_max_cps = _to_int(value, pipeline.subtitle.quality.hard_max_cps)

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
            max_output_tokens=_to_int(capabilities_raw.get("max_output_tokens", capabilities_raw.get("maxOutputTokens")), 0),
            recommended_output_tokens=_to_int(
                capabilities_raw.get("recommended_output_tokens", capabilities_raw.get("recommendedOutputTokens")),
                0,
            ),
            output_token_param=_to_str(capabilities_raw.get("output_token_param", capabilities_raw.get("outputTokenParam")), ""),
        )
        cfg = ProviderConfig(
            name=row["name"],
            api_type=api_type,
            base_url=row["base_url"].rstrip("/"),
            env_key=row["env_key"],
            models=list(row.get("models", [])),
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
) -> AppConfig:
    if not provider_name and not model:
        return config
    primary = replace(
        config.routing.primary,
        provider=provider_name or config.routing.primary.provider,
        model=model or config.routing.primary.model,
    )
    return replace(config, routing=replace(config.routing, primary=primary))
