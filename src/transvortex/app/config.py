from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path
from typing import Any

import yaml

from .models import (
    AppConfig,
    AssStyleConfig,
    AuthConfig,
    CapabilityConfig,
    DEFAULT_TRANSLATION_STYLE_PROMPT,
    EndpointConfig,
    MappingConfig,
    ModelListConfig,
    PipelineConfig,
    ProviderConfig,
    ProviderLimits,
    RefusalDetectionConfig,
    RepairConfig,
    RouteTarget,
    RoutingConfig,
    TranslationConfig,
)


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


def _load_dotenv(root_dir: Path) -> None:
    dotenv_file = root_dir / ".env"
    if not dotenv_file.exists():
        return
    for raw in dotenv_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        os.environ.setdefault(key, value)


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
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
    _load_dotenv(root_dir)
    providers_file = resolve_providers_file(root_dir, providers_file)
    pipeline_file = pipeline_file or root_dir / "pipeline.yaml"

    p_yaml = _read_yaml(providers_file)
    pip_yaml = _read_yaml(pipeline_file)

    artifacts_dir = Path(pip_yaml.get("artifacts_dir", "artifacts"))
    asr_raw = pip_yaml.get("asr") or {}
    asr_cloud_raw = asr_raw.get("cloud") or {}
    translation_raw = pip_yaml.get("translation") or {}
    legacy_translation_batch_size = _to_int(pip_yaml.get("translation_batch_size"), 40)
    chunk_lines = _to_int(translation_raw.get("chunk_lines"), legacy_translation_batch_size)
    style_prompt_default = DEFAULT_TRANSLATION_STYLE_PROMPT
    if "style_prompt" in translation_raw:
        style_prompt_default = str(translation_raw.get("style_prompt") or "")
    refusal_raw = translation_raw.get("refusal_detection") or {}
    repair_raw = translation_raw.get("repair") or {}
    translation = TranslationConfig(
        chunk_lines=chunk_lines,
        context_before_lines=_to_int(translation_raw.get("context_before_lines"), 20),
        context_after_lines=_to_int(translation_raw.get("context_after_lines"), 10),
        style_preset=str(translation_raw.get("style_preset", "subtitle_natural")),
        style_prompt=style_prompt_default,
        refusal_detection=RefusalDetectionConfig(
            enabled=_to_bool(refusal_raw.get("enabled"), True),
        ),
        repair=RepairConfig(
            enabled=_to_bool(repair_raw.get("enabled"), True),
            max_attempts=_to_int(repair_raw.get("max_attempts"), 2),
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
    )
    pipeline = PipelineConfig(
        artifacts_dir=(root_dir / artifacts_dir),
        chunk_seconds=_to_int(pip_yaml.get("chunk_seconds"), 60),
        chunk_overlap_seconds=_to_int(pip_yaml.get("chunk_overlap_seconds"), 1),
        translation_batch_size=chunk_lines,
        translation=translation,
        output_format=_to_str(pip_yaml.get("output_format"), "srt"),
        subtitle_ass_style=subtitle_ass_style,
        default_concurrency=_to_int(pip_yaml.get("default_concurrency"), 8),
        timeout_seconds=_to_int(pip_yaml.get("timeout_seconds"), 30),
        retry=_to_int(pip_yaml.get("retry"), 3),
        max_cps=_to_int(pip_yaml.get("max_cps"), 20),
        asr_model_size=str(asr_raw.get("model_size", "small")),
        asr_device=str(asr_raw.get("device", "auto")),
        asr_compute_type=str(asr_raw.get("compute_type", "int8")),
        asr_mode=str(asr_raw.get("mode", "local")),
        asr_provider=str(asr_raw.get("provider", "")),
        asr_provider_model=str(asr_raw.get("model", "")),
        asr_cloud_base_url=str(asr_cloud_raw.get("base_url", "https://api.openai.com")),
        asr_cloud_endpoint=str(asr_cloud_raw.get("endpoint", "/v1/audio/transcriptions")),
        asr_cloud_model=str(asr_cloud_raw.get("model", "whisper-1")),
        asr_cloud_env_key=str(asr_cloud_raw.get("env_key", "TVX_MODEL_API_KEY")),
        asr_cloud_timeout_seconds=_to_int(asr_cloud_raw.get("timeout_seconds"), 120),
    )

    for field_name, env_name in ENV_MAP.items():
        env_v = os.getenv(env_name)
        if env_v is None:
            continue
        setattr(pipeline, field_name, _to_int(env_v, getattr(pipeline, field_name)))
        if field_name == "translation_batch_size":
            pipeline.translation.chunk_lines = pipeline.translation_batch_size

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

    providers: dict[str, ProviderConfig] = {}
    for row in p_yaml.get("providers", []):
        api_type = row["api_type"]
        compat_mode = row.get("compat_mode") or _infer_compat_mode(api_type)
        limits_raw = row.get("limits", {})
        limits = ProviderLimits(
            concurrency=_to_int(limits_raw.get("concurrency"), pipeline.default_concurrency),
            timeout_seconds=_to_int(limits_raw.get("timeout_seconds"), pipeline.timeout_seconds),
            retry=_to_int(limits_raw.get("retry"), pipeline.retry),
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
            supports_system_prompt=bool(capabilities_raw.get("supports_system_prompt", True)),
            supports_temperature=bool(capabilities_raw.get("supports_temperature", True)),
            supports_json_mode=bool(capabilities_raw.get("supports_json_mode", False)),
            max_batch_lines=_to_int(capabilities_raw.get("max_batch_lines"), 50),
        )
        cfg = ProviderConfig(
            name=row["name"],
            api_type=api_type,
            base_url=row["base_url"].rstrip("/"),
            env_key=row["env_key"],
            models=list(row.get("models", [])),
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

    routing_raw = p_yaml.get("routing", {})
    primary_raw = routing_raw.get("primary", {})
    fallback_raw = routing_raw.get("fallback", [])
    routing = RoutingConfig(
        primary=RouteTarget(
            provider=primary_raw.get("provider", ""),
            model=primary_raw.get("model", ""),
        ),
        fallback=[
            RouteTarget(provider=item["provider"], model=item["model"])
            for item in fallback_raw
        ],
    )
    return AppConfig(pipeline=pipeline, providers=providers, routing=routing)


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
