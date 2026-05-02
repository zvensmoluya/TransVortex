from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml

from .models import (
    AppConfig,
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    PipelineConfig,
    ProviderConfig,
    ProviderLimits,
    RouteTarget,
    RoutingConfig,
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


def _infer_compat_mode(api_type: str) -> str:
    if api_type in {"openai", "openai-compatible"}:
        return "openai_chat"
    if api_type == "anthropic":
        return "anthropic_messages"
    if api_type == "gemini-compatible":
        return "gemini_generate_content"
    raise ValueError(f"Unsupported api_type: {api_type}")


def _default_endpoint_for_mode(compat_mode: str) -> EndpointConfig:
    if compat_mode == "openai_chat":
        return EndpointConfig(path_template="/chat/completions", method="POST")
    if compat_mode == "anthropic_messages":
        return EndpointConfig(path_template="/messages", method="POST")
    if compat_mode == "gemini_generate_content":
        return EndpointConfig(path_template="/models/{model}:generateContent", method="POST")
    raise ValueError(f"Unsupported compat_mode: {compat_mode}")


def _default_auth_for_mode(compat_mode: str) -> AuthConfig:
    if compat_mode == "openai_chat":
        return AuthConfig(type="bearer", header_name="Authorization", prefix="Bearer ")
    if compat_mode == "anthropic_messages":
        return AuthConfig(type="header", header_name="x-api-key", prefix="")
    if compat_mode == "gemini_generate_content":
        return AuthConfig(type="query", query_name="key", prefix="")
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
    pipeline = PipelineConfig(
        artifacts_dir=(root_dir / artifacts_dir),
        chunk_seconds=_to_int(pip_yaml.get("chunk_seconds"), 60),
        chunk_overlap_seconds=_to_int(pip_yaml.get("chunk_overlap_seconds"), 1),
        translation_batch_size=_to_int(pip_yaml.get("translation_batch_size"), 40),
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
        asr_cloud_env_key=str(asr_cloud_raw.get("env_key", "OPENAI_API_KEY")),
        asr_cloud_timeout_seconds=_to_int(asr_cloud_raw.get("timeout_seconds"), 120),
    )

    for field_name, env_name in ENV_MAP.items():
        env_v = os.getenv(env_name)
        if env_v is None:
            continue
        setattr(pipeline, field_name, _to_int(env_v, getattr(pipeline, field_name)))

    for key, value in cli_overrides.items():
        if value is None:
            continue
        if hasattr(pipeline, key):
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
