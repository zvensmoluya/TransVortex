from __future__ import annotations

import json
import re
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError

import yaml

from ..app.config import load_app_config, resolve_providers_file
from ..app.credentials import (
    auth_file_path,
    delete_auth_credential,
    provider_credential_id,
    resolve_provider_credential,
    write_auth_credential,
)
from ..app.models import (
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    ModelListConfig,
    NormalizedRequest,
    ProviderConfig,
    ProviderLimits,
)
from .factory import (
    _build_payload,
    _build_url_and_headers,
    _build_url_and_headers_for_path,
    _extract_text_by_paths,
    _request_json,
    response_shape_summary,
)
from ..utils import to_plain


PROVIDER_TEMPLATES: dict[str, dict[str, Any]] = {
    "openai_chat": {
        "label": "OpenAI-compatible Chat",
        "api_type": "openai-compatible",
        "compat_mode": "openai_chat",
        "base_url": "https://api.openai.com/v1",
        "endpoint": {"path_template": "/chat/completions", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {"style": "openai_chat"},
        "response_mapping": {"text_paths": ["choices[0].message.content"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "openai_responses": {
        "label": "OpenAI Responses",
        "api_type": "openai-compatible",
        "compat_mode": "openai_responses",
        "base_url": "https://api.openai.com/v1",
        "endpoint": {"path_template": "/responses", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {"style": "openai_responses"},
        "response_mapping": {"text_paths": ["output_text", "output[].content[].text"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 65536,
            "recommended_output_tokens": 32768,
            "output_token_param": "",
        },
    },
    "openai_completions": {
        "label": "OpenAI Completions",
        "api_type": "openai-compatible",
        "compat_mode": "openai_completions",
        "base_url": "https://api.openai.com/v1",
        "endpoint": {"path_template": "/completions", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {"style": "openai_completions"},
        "response_mapping": {"text_paths": ["choices[0].text"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": False,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "anthropic_messages": {
        "label": "Anthropic Messages",
        "api_type": "anthropic",
        "compat_mode": "anthropic_messages",
        "base_url": "https://api.anthropic.com/v1",
        "endpoint": {"path_template": "/messages", "method": "POST"},
        "auth": {"type": "header", "header_name": "x-api-key", "prefix": ""},
        "extra_headers": {"anthropic-version": "2023-06-01"},
        "request_mapping": {"style": "anthropic_messages"},
        "response_mapping": {"text_paths": ["content[].text"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "gemini_generate_content": {
        "label": "Gemini GenerateContent",
        "api_type": "gemini-compatible",
        "compat_mode": "gemini_generate_content",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "endpoint": {"path_template": "/models/{model}:generateContent", "method": "POST"},
        "auth": {"type": "query", "query_name": "key", "prefix": ""},
        "request_mapping": {"style": "gemini_generate_content"},
        "response_mapping": {"text_paths": ["candidates[0].content.parts[].text"]},
        "model_list": {
            "path_template": "/models",
            "method": "GET",
            "response_paths": ["models[].name", "data[].id"],
        },
        "capabilities": {
            "supports_system_prompt": False,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "gemini_ai_studio_native": {
        "label": "Gemini AI Studio Native",
        "api_type": "gemini-compatible",
        "compat_mode": "gemini_generate_content",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "endpoint": {"path_template": "/models/{model}:generateContent", "method": "POST"},
        "auth": {"type": "query", "query_name": "key", "prefix": ""},
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {
                "generationConfig": {"topP": 0.95},
                "safetySettings": [],
            },
        },
        "response_mapping": {"text_paths": ["candidates[0].content.parts[].text"]},
        "model_list": {
            "path_template": "/models",
            "method": "GET",
            "response_paths": ["models[].name", "data[].id"],
        },
        "capabilities": {
            "supports_system_prompt": False,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "gemini_openai_compatible": {
        "label": "Gemini OpenAI-compatible",
        "api_type": "openai-compatible",
        "compat_mode": "openai_chat",
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
        "endpoint": {"path_template": "/chat/completions", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {
            "style": "openai_chat",
            "body_overrides": {
                "reasoning_effort": "none",
                "extra_body": {"google": {"thinking_config": {"thinking_budget": 0}}},
            },
        },
        "response_mapping": {"text_paths": ["choices[0].message.content"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "vertex_native": {
        "label": "Vertex AI Native Gemini",
        "api_type": "gemini-compatible",
        "compat_mode": "gemini_generate_content",
        "base_url": "https://aiplatform.googleapis.com/v1",
        "endpoint": {"path_template": "/{model}:generateContent", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {"generationConfig": {"topP": 0.95}},
        },
        "response_mapping": {"text_paths": ["candidates[0].content.parts[].text"]},
        "model_list": {"path_template": "", "method": "GET", "response_paths": []},
        "capabilities": {
            "supports_system_prompt": False,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "vertex_openai_compatible": {
        "label": "Vertex AI OpenAI-compatible",
        "api_type": "openai-compatible",
        "compat_mode": "openai_chat",
        "base_url": "https://aiplatform.googleapis.com/v1/endpoints/openapi",
        "endpoint": {"path_template": "/chat/completions", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {"style": "openai_chat"},
        "response_mapping": {"text_paths": ["choices[0].message.content"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 32768,
            "recommended_output_tokens": 16384,
            "output_token_param": "",
        },
    },
    "custom_json": {
        "label": "Custom JSON",
        "api_type": "custom",
        "compat_mode": "custom_json",
        "base_url": "https://example.com",
        "endpoint": {"path_template": "/", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {
            "style": "custom_json",
            "body_template": {
                "model": "{{model}}",
                "prompt": "{{prompt}}",
            },
        },
        "response_mapping": {"text_paths": ["text", "choices[0].message.content"]},
        "model_list": {"path_template": "", "method": "GET", "response_paths": []},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 1000,
            "max_context_tokens": 0,
            "max_output_tokens": 0,
            "recommended_output_tokens": 0,
            "output_token_param": "",
        },
    },
}


PROTOCOL_TEMPLATE_IDS = [
    "openai_chat",
    "openai_responses",
    "openai_completions",
    "anthropic_messages",
    "gemini_generate_content",
    "gemini_openai_compatible",
    "vertex_native",
    "vertex_openai_compatible",
]


PROVIDER_PRESETS: dict[str, dict[str, Any]] = {
    "openai_official": {
        "label": "OpenAI official",
        "protocol_template_id": "openai_responses",
        **PROVIDER_TEMPLATES["openai_responses"],
    },
    "anthropic_official": {
        "label": "Anthropic official",
        "protocol_template_id": "anthropic_messages",
        **PROVIDER_TEMPLATES["anthropic_messages"],
    },
    "google_ai_studio": {
        "label": "Google AI Studio",
        "protocol_template_id": "gemini_generate_content",
        **PROVIDER_TEMPLATES["gemini_ai_studio_native"],
    },
    "google_vertex_gemini": {
        "label": "Google Vertex AI Gemini",
        "protocol_template_id": "vertex_native",
        **PROVIDER_TEMPLATES["vertex_native"],
    },
    "google_vertex_openai": {
        "label": "Google Vertex AI OpenAI-compatible",
        "protocol_template_id": "vertex_openai_compatible",
        **PROVIDER_TEMPLATES["vertex_openai_compatible"],
    },
}


@dataclass
class ProviderCheck:
    name: str
    status: str
    code: str
    message: str
    hint_zh: str
    details: dict[str, Any]


def provider_templates_payload() -> list[dict[str, Any]]:
    return [
        {"id": key, **to_plain(template)}
        for key, template in sorted(PROVIDER_TEMPLATES.items(), key=lambda item: item[0])
    ]


def protocol_templates_payload() -> list[dict[str, Any]]:
    return [{"id": key, **to_plain(PROVIDER_TEMPLATES[key])} for key in PROTOCOL_TEMPLATE_IDS]


def provider_presets_payload() -> list[dict[str, Any]]:
    return [
        {"id": key, **to_plain(preset)}
        for key, preset in sorted(PROVIDER_PRESETS.items(), key=lambda item: item[0])
    ]


def custom_adapter_template_payload() -> dict[str, Any]:
    return {"id": "custom_json", **to_plain(PROVIDER_TEMPLATES["custom_json"])}


def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _write_yaml(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(
        yaml.safe_dump(payload, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def providers_file_version(path: Path) -> dict[str, int] | None:
    if not path.exists():
        return None
    stat = path.stat()
    return {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size}


def _parse_expected_version(raw: Any) -> dict[str, int] | None:
    raw = _as_dict(raw)
    if not raw:
        return None
    try:
        return {"mtime_ns": int(raw.get("mtime_ns", -1)), "size": int(raw.get("size", -1))}
    except (TypeError, ValueError):
        return {"mtime_ns": -1, "size": -1}


def _check_expected_version(path: Path, expected_version: Any) -> None:
    expected = _parse_expected_version(expected_version)
    if expected is None:
        return
    current = providers_file_version(path)
    if current != expected:
        raise ValueError(
            json_diagnostic(
                code="provider_config_conflict",
                message="provider config changed on disk",
                hint_zh="Provider 配置文件已被其它窗口或进程修改，请刷新后重试。",
                details={"expected": expected, "current": current},
            )
        )


def json_diagnostic(*, code: str, message: str, hint_zh: str, details: dict[str, Any] | None = None) -> str:
    return json.dumps(
        {
            "status": "FAIL",
            "code": code,
            "message": message,
            "hint_zh": hint_zh,
            "details": details or {},
        },
        ensure_ascii=False,
    )


def _slug_env_key(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper()
    return f"TVX_PROVIDER_{slug or 'CUSTOM'}_API_KEY"


def _template_for_compat(compat_mode: str) -> dict[str, Any]:
    return dict(PROVIDER_TEMPLATES.get(compat_mode) or PROVIDER_TEMPLATES["openai_chat"])


def draft_to_provider_config(draft: dict[str, Any]) -> ProviderConfig:
    compat_mode = str(draft.get("compat_mode") or draft.get("compatMode") or "openai_chat")
    template = _template_for_compat(compat_mode)
    name = str(draft.get("name") or "custom_provider").strip()
    api_type = str(draft.get("api_type") or draft.get("apiType") or template["api_type"])
    base_url = str(draft.get("base_url") or draft.get("baseUrl") or template["base_url"]).strip().rstrip("/")
    env_key = str(draft.get("env_key") or draft.get("envKey") or _slug_env_key(name)).strip()
    models = [str(item).strip() for item in _as_list(draft.get("models")) if str(item).strip()]
    if not models:
        models = ["custom-model"]
    auth_raw = _as_dict(draft.get("auth") or template.get("auth"))
    endpoint_raw = _as_dict(draft.get("endpoint") or template.get("endpoint"))
    request_mapping = _as_dict(draft.get("request_mapping") or draft.get("requestMapping") or template.get("request_mapping"))
    response_mapping = _as_dict(draft.get("response_mapping") or draft.get("responseMapping") or template.get("response_mapping"))
    capabilities_raw = _as_dict(draft.get("capabilities") or template.get("capabilities"))
    limits_raw = _as_dict(draft.get("limits"))
    model_list_raw = _as_dict(draft.get("model_list") or draft.get("modelList") or template.get("model_list"))
    return ProviderConfig(
        name=name,
        api_type=api_type,
        compat_mode=compat_mode,
        base_url=base_url,
        env_key=env_key,
        models=models,
        credential_id=str(draft.get("credential_id") or draft.get("credentialId") or name),
        auth=AuthConfig(
            type=str(auth_raw.get("type", "bearer")),
            header_name=str(auth_raw.get("header_name") or auth_raw.get("headerName") or "Authorization"),
            query_name=str(auth_raw.get("query_name") or auth_raw.get("queryName") or "key"),
            prefix=str(auth_raw.get("prefix", "Bearer ")),
        ),
        endpoint=EndpointConfig(
            path_template=str(endpoint_raw.get("path_template") or endpoint_raw.get("pathTemplate") or ""),
            method=str(endpoint_raw.get("method", "POST")).upper(),
        ),
        mapping=MappingConfig(request=request_mapping, response=response_mapping),
        extra_headers={
            str(k): str(v)
            for k, v in _as_dict(draft.get("extra_headers") or draft.get("extraHeaders") or template.get("extra_headers")).items()
        },
        model_list=ModelListConfig(
            path_template=str(model_list_raw.get("path_template") or model_list_raw.get("pathTemplate") or ""),
            method=str(model_list_raw.get("method", "GET")).upper(),
            response_paths=[str(item) for item in _as_list(model_list_raw.get("response_paths") or model_list_raw.get("responsePaths"))],
        ),
        capabilities=CapabilityConfig(
            supports_system_prompt=bool(capabilities_raw.get("supports_system_prompt", capabilities_raw.get("supportsSystemPrompt", True))),
            supports_temperature=bool(capabilities_raw.get("supports_temperature", capabilities_raw.get("supportsTemperature", True))),
            supports_json_mode=bool(capabilities_raw.get("supports_json_mode", capabilities_raw.get("supportsJsonMode", False))),
            max_batch_lines=_to_int(capabilities_raw.get("max_batch_lines", capabilities_raw.get("maxBatchLines")), 50),
            max_context_tokens=_to_int(capabilities_raw.get("max_context_tokens", capabilities_raw.get("maxContextTokens")), 0),
            max_output_tokens=_to_int(capabilities_raw.get("max_output_tokens", capabilities_raw.get("maxOutputTokens")), 0),
            recommended_output_tokens=_to_int(
                capabilities_raw.get("recommended_output_tokens", capabilities_raw.get("recommendedOutputTokens")),
                0,
            ),
            output_token_param=str(capabilities_raw.get("output_token_param", capabilities_raw.get("outputTokenParam", "")) or ""),
        ),
        limits=ProviderLimits(
            concurrency=int(limits_raw.get("concurrency", 8)),
            timeout_seconds=int(limits_raw.get("timeout_seconds", limits_raw.get("timeoutSeconds", 30))),
            retry=int(limits_raw.get("retry", 3)),
        ),
    )


def provider_config_to_yaml_row(config: ProviderConfig) -> dict[str, Any]:
    row: dict[str, Any] = {
        "name": config.name,
        "api_type": config.api_type,
        "compat_mode": config.compat_mode,
        "base_url": config.base_url,
        "env_key": config.env_key,
        "credential_id": provider_credential_id(config),
        "models": config.models,
        "auth": to_plain(config.auth),
        "endpoint": to_plain(config.endpoint),
        "request_mapping": dict(config.mapping.request),
        "response_mapping": dict(config.mapping.response),
        "capabilities": to_plain(config.capabilities),
        "limits": to_plain(config.limits),
    }
    if config.extra_headers:
        row["extra_headers"] = dict(config.extra_headers)
    if config.model_list.path_template:
        row["model_list"] = to_plain(config.model_list)
    return row


def _route_row(raw: Any) -> dict[str, str]:
    raw = _as_dict(raw)
    return {"provider": str(raw.get("provider", "")), "model": str(raw.get("model", ""))}


def _fallback_rows(raw: Any) -> list[dict[str, str]]:
    return [
        _route_row(item)
        for item in _as_list(raw)
        if isinstance(item, dict) and item.get("provider") and item.get("model")
    ]


def _normalize_routing_profile(raw: dict[str, Any], fallback_id: str) -> dict[str, Any]:
    profile_id = str(raw.get("id") or fallback_id).strip() or fallback_id
    name = "" if "name" in raw and raw.get("name") is None else str(raw.get("name", profile_id)).strip()
    return {
        "id": profile_id,
        "name": name,
        "primary": _route_row(raw.get("primary")),
        "fallback": _fallback_rows(raw.get("fallback")),
    }


def _profile_seq_from_id(profile_id: str) -> int:
    match = re.fullmatch(r"route_(\d+)", profile_id)
    return int(match.group(1)) if match else 0


def _fallback_next_profile_seq(profiles: list[dict[str, Any]]) -> int:
    highest = max([_profile_seq_from_id(str(item.get("id", ""))) for item in profiles] + [0])
    return highest + 1


def _normalized_next_profile_seq(raw: Any, profiles: list[dict[str, Any]]) -> int:
    fallback = _fallback_next_profile_seq(profiles)
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = fallback
    return max(value, fallback, 1)


def _existing_routing_profiles(existing: dict[str, Any]) -> list[dict[str, Any]]:
    routing = _as_dict(existing.get("routing"))
    rows = [
        _normalize_routing_profile(item, f"route_{idx}")
        for idx, item in enumerate(_as_list(existing.get("routing_profiles")), start=1)
        if isinstance(item, dict)
    ]
    if rows:
        return rows
    return [
        _normalize_routing_profile(
            {
                "id": "default",
                "name": "Default",
                "primary": routing.get("primary"),
                "fallback": routing.get("fallback"),
            },
            "default",
        )
    ]


def _active_profile_id(existing: dict[str, Any], profiles: list[dict[str, Any]]) -> str:
    routing = _as_dict(existing.get("routing"))
    requested = str(routing.get("active_profile") or "").strip()
    if any(item["id"] == requested for item in profiles):
        return requested
    return profiles[0]["id"] if profiles else "default"


def _providers_by_name(rows: list[Any]) -> dict[str, dict[str, Any]]:
    return {str(item.get("name")): item for item in rows if isinstance(item, dict) and item.get("name")}


def _validate_routing_profiles(
    *,
    profiles: list[dict[str, Any]],
    providers: list[Any],
    active_profile: str,
) -> None:
    if not profiles:
        raise ValueError(
            json_diagnostic(
                code="routing_profile_missing",
                message="at least one route profile is required",
                hint_zh="至少需要一个 Route profile。",
            )
        )
    seen_ids: set[str] = set()
    seen_names: set[str] = set()
    providers_by_name = _providers_by_name(providers)
    for profile in profiles:
        profile_id = str(profile.get("id", "")).strip()
        name = str(profile.get("name", "")).strip()
        if not profile_id:
            raise ValueError(
                json_diagnostic(
                    code="routing_profile_id_missing",
                    message="route profile id is missing",
                    hint_zh="Route profile 缺少 id。",
                    details={"profile": profile},
                )
            )
        if profile_id in seen_ids:
            raise ValueError(
                json_diagnostic(
                    code="routing_profile_id_duplicate",
                    message=f"duplicate route profile id: {profile_id}",
                    hint_zh=f"Route profile id 重复：{profile_id}。",
                    details={"profile_id": profile_id},
                )
            )
        seen_ids.add(profile_id)
        if not name:
            raise ValueError(
                json_diagnostic(
                    code="routing_profile_name_missing",
                    message="route profile name is missing",
                    hint_zh="Route profile 名称不能为空。",
                    details={"profile_id": profile_id},
                )
            )
        name_key = name.casefold()
        if name_key in seen_names:
            raise ValueError(
                json_diagnostic(
                    code="routing_profile_name_duplicate",
                    message=f"duplicate route profile name: {name}",
                    hint_zh=f"Route profile 名称重复：{name}。",
                    details={"profile_name": name},
                )
            )
        seen_names.add(name_key)
        for role, route in [("primary", profile.get("primary"))] + [
            (f"fallback[{idx}]", item) for idx, item in enumerate(_as_list(profile.get("fallback")))
        ]:
            route = _route_row(route)
            provider_name = route["provider"]
            model = route["model"]
            if not provider_name or not model:
                raise ValueError(
                    json_diagnostic(
                        code="routing_route_missing",
                        message="route provider/model is missing",
                        hint_zh="Route profile 中的 provider 和 model 都不能为空。",
                        details={"profile_id": profile_id, "profile_name": name, "route": role},
                    )
                )
            provider = providers_by_name.get(provider_name)
            if provider is None:
                raise ValueError(
                    json_diagnostic(
                        code="routing_provider_missing",
                        message=f"routing provider not found: {provider_name}",
                        hint_zh=f"Route profile 引用了不存在的 provider：{provider_name}。",
                        details={"profile_id": profile_id, "profile_name": name, "route": role, "provider": provider_name},
                    )
                )
            models = [str(item) for item in _as_list(provider.get("models"))]
            if model not in models:
                raise ValueError(
                    json_diagnostic(
                        code="routing_model_missing",
                        message=f"routing model not found: {provider_name}/{model}",
                        hint_zh=f"Route profile 引用了 provider 未配置的模型：{provider_name} / {model}。",
                        details={
                            "profile_id": profile_id,
                            "profile_name": name,
                            "route": role,
                            "provider": provider_name,
                            "model": model,
                            "provider_models": models,
                        },
                    )
                )
    if active_profile not in seen_ids:
        raise ValueError(
            json_diagnostic(
                code="routing_active_profile_missing",
                message=f"active route profile not found: {active_profile}",
                hint_zh="当前 active Route profile 不存在。",
                details={"active_profile": active_profile},
            )
        )


def _provider_references(profiles: list[dict[str, Any]], provider_name: str) -> list[dict[str, Any]]:
    refs: list[dict[str, Any]] = []
    for profile in profiles:
        routes = [("primary", profile.get("primary"))] + [
            (f"fallback[{idx}]", item) for idx, item in enumerate(_as_list(profile.get("fallback")))
        ]
        for route_name, route in routes:
            route = _route_row(route)
            if route["provider"] == provider_name:
                refs.append(
                    {
                        "profile_id": profile.get("id", ""),
                        "profile_name": profile.get("name", ""),
                        "route": route_name,
                        "provider": route["provider"],
                        "model": route["model"],
                    }
                )
    return refs


def _payload_with_routing(
    existing: dict[str, Any],
    *,
    providers: list[Any],
    routing: dict[str, Any],
    profiles: list[dict[str, Any]],
) -> dict[str, Any]:
    payload = dict(existing)
    payload["providers"] = providers
    payload["routing"] = routing
    payload["routing_profiles"] = profiles
    return payload


def _legacy_routing_profile(existing: dict[str, Any]) -> dict[str, Any]:
    routing = _as_dict(existing.get("routing"))
    return _normalize_routing_profile(
        {
            "id": "default",
            "name": "Default",
            "primary": routing.get("primary"),
            "fallback": routing.get("fallback"),
        },
        "default",
    )


def save_provider_config(
    *,
    root_dir: Path,
    provider_draft: dict[str, Any],
    api_key: str | None = None,
    expected_version: dict[str, Any] | None = None,
) -> dict[str, Any]:
    providers_file = root_dir / "providers.local.yaml"
    read_path = providers_file if providers_file.exists() else resolve_providers_file(root_dir)
    _check_expected_version(read_path, expected_version)
    existing = _read_yaml(read_path)
    provider = draft_to_provider_config(provider_draft)
    rows = [row for row in _as_list(existing.get("providers")) if row.get("name") != provider.name]
    rows.append(provider_config_to_yaml_row(provider))
    routing_existing = _as_dict(existing.get("routing"))
    primary = _as_dict(routing_existing.get("primary"))
    if not primary.get("provider"):
        primary = {"provider": provider.name, "model": provider.models[0] if provider.models else ""}
    fallback = _fallback_rows(routing_existing.get("fallback"))
    if _as_list(existing.get("routing_profiles")):
        routing_profiles = _existing_routing_profiles(existing)
    else:
        routing_profiles = [
            _normalize_routing_profile(
                {
                    "id": str(routing_existing.get("active_profile") or "default"),
                    "name": "Default",
                    "primary": primary,
                    "fallback": fallback,
                },
                "default",
            )
        ]
    routing = {
        "active_profile": str(routing_existing.get("active_profile") or routing_profiles[0].get("id") or "default"),
        "next_profile_seq": _normalized_next_profile_seq(routing_existing.get("next_profile_seq"), routing_profiles),
        "primary": primary,
        "fallback": fallback,
    }
    _validate_routing_profiles(profiles=routing_profiles, providers=rows, active_profile=routing["active_profile"])
    _write_yaml(
        providers_file,
        _payload_with_routing(existing, providers=rows, routing=routing, profiles=routing_profiles),
    )
    if api_key:
        write_auth_credential(provider_credential_id(provider), api_key)
    credential = resolve_provider_credential(provider, root_dir=root_dir)
    return {
        "provider": provider.name,
        "providers_file": str(providers_file),
        "providers_file_version": providers_file_version(providers_file),
        "auth_file": str(auth_file_path()),
        "credential_id": provider_credential_id(provider),
        "has_key": credential.found,
        "credential_source": credential.source,
    }


def save_provider_routing(*, root_dir: Path, routing: dict[str, Any]) -> dict[str, Any]:
    providers_file = root_dir / "providers.local.yaml"
    read_path = providers_file if providers_file.exists() else resolve_providers_file(root_dir)
    _check_expected_version(read_path, routing.get("expected_version") or routing.get("expectedVersion"))
    existing = _read_yaml(read_path)
    providers = _as_list(existing.get("providers"))
    routing_existing = _as_dict(existing.get("routing"))
    existing_profiles = _existing_routing_profiles(existing)
    profiles_payload = _as_list(routing.get("profiles"))
    if profiles_payload:
        profiles = [_normalize_routing_profile(item, f"route_{idx}") for idx, item in enumerate(profiles_payload, start=1) if isinstance(item, dict)]
        if not profiles:
            profiles = existing_profiles
        active_profile = str(routing.get("active_profile") or routing.get("activeProfile") or profiles[0]["id"])
        active = next((item for item in profiles if item["id"] == active_profile), profiles[0])
        active_profile = active["id"]
        next_profile_seq = _normalized_next_profile_seq(
            routing.get("next_profile_seq") or routing.get("nextProfileSeq") or routing_existing.get("next_profile_seq"),
            profiles,
        )
    else:
        active = _normalize_routing_profile(
            {
                "id": "default",
                "name": "Default",
                "primary": routing.get("primary"),
                "fallback": routing.get("fallback"),
            },
            "default",
        )
        profiles = [
            _normalize_routing_profile(item, f"route_{idx}")
            for idx, item in enumerate(existing_profiles, start=1)
            if isinstance(item, dict) and str(item.get("id") or "") != "default"
        ]
        profiles.insert(0, active)
        existing_active_profile = _active_profile_id(existing, profiles)
        active_profile = "default" if existing_active_profile == "default" else existing_active_profile
        active = next((item for item in profiles if item["id"] == active_profile), profiles[0])
        next_profile_seq = _normalized_next_profile_seq(routing_existing.get("next_profile_seq"), profiles)
    _validate_routing_profiles(profiles=profiles, providers=providers, active_profile=active_profile)
    payload_routing = {
        "active_profile": active_profile,
        "next_profile_seq": next_profile_seq,
        "primary": active["primary"],
        "fallback": active["fallback"],
    }
    payload = _payload_with_routing(existing, providers=providers, routing=payload_routing, profiles=profiles)
    _write_yaml(providers_file, payload)
    return {
        "providers_file": str(providers_file),
        "routing": payload["routing"],
        "active_routing_profile": active_profile,
        "routing_profile_next_seq": next_profile_seq,
        "routing_profiles": profiles,
        "providers_file_version": providers_file_version(providers_file),
    }


def delete_provider_config(*, root_dir: Path, name: str, expected_version: dict[str, Any] | None = None) -> dict[str, Any]:
    providers_file = root_dir / "providers.local.yaml"
    if not providers_file.exists():
        return {"deleted": False, "providers_file": str(providers_file)}
    _check_expected_version(providers_file, expected_version)
    existing = _read_yaml(providers_file)
    rows = _as_list(existing.get("providers"))
    kept = [row for row in rows if row.get("name") != name]
    if len(kept) == len(rows):
        return {"deleted": False, "providers_file": str(providers_file)}
    profiles = _existing_routing_profiles(existing)
    references = _provider_references(profiles, name)
    if references:
        return {
            "deleted": False,
            "blocked": True,
            "code": "provider_in_use",
            "message": f"provider is used by {len(references)} route references",
            "hint_zh": "这个 provider 正在被 Route profile 使用，请先修改路由后再删除。",
            "references": references,
            "providers_file": str(providers_file),
            "providers_file_version": providers_file_version(providers_file),
        }
    routing = _as_dict(existing.get("routing"))
    primary = _as_dict(routing.get("primary"))
    if primary.get("provider") == name:
        first = kept[0] if kept else {}
        models = _as_list(first.get("models"))
        routing["primary"] = {"provider": first.get("name", ""), "model": models[0] if models else ""}
    routing = routing or {"primary": {"provider": "", "model": ""}, "fallback": []}
    routing["next_profile_seq"] = _normalized_next_profile_seq(routing.get("next_profile_seq"), profiles)
    _write_yaml(providers_file, _payload_with_routing(existing, providers=kept, routing=routing, profiles=profiles))
    return {"deleted": True, "providers_file": str(providers_file), "providers_file_version": providers_file_version(providers_file)}


def _api_key_for(config: ProviderConfig, *, root_dir: Path | None = None, override: str | None = None):
    return resolve_provider_credential(config, root_dir=root_dir, explicit_key=override)


def _is_retryable_provider_error(exc: Exception) -> bool:
    if isinstance(exc, HTTPError):
        return exc.code in {408, 429, 500, 502, 503, 504}
    if isinstance(exc, URLError):
        return True
    return "timed out" in str(exc).lower()


def _network_error_hint(exc: Exception) -> ProviderCheck:
    if isinstance(exc, HTTPError):
        if exc.code in {401, 403}:
            return ProviderCheck(
                name="network",
                status="FAIL",
                code="provider_auth_failed",
                message=f"provider returned HTTP {exc.code}",
                hint_zh="API key 或鉴权方式不正确，请检查 key、auth type 和 base_url。",
                details={"status": exc.code},
            )
        if exc.code == 404:
            return ProviderCheck(
                name="network",
                status="WARN",
                code="provider_endpoint_not_found",
                message="provider endpoint not found",
                hint_zh="当前接口路径没有响应。若是非标准网关，可以手动填写模型并检查 endpoint。",
                details={"status": exc.code},
            )
        if exc.code in {502, 503, 504}:
            return ProviderCheck(
                name="network",
                status="FAIL",
                code="provider_upstream_error",
                message=f"provider upstream returned HTTP {exc.code}",
                hint_zh="Provider 网关或上游服务暂时失败，请稍后重试；如果持续失败，再检查 base_url、模型和服务商状态。",
                details={"status": exc.code},
            )
        if exc.code in {408, 429, 500}:
            return ProviderCheck(
                name="network",
                status="FAIL",
                code="provider_retryable_http_error",
                message=f"provider returned retryable HTTP {exc.code}",
                hint_zh="Provider 暂时不可用或限流，请稍后重试；如果持续失败，再检查模型和账号额度。",
                details={"status": exc.code},
            )
        return ProviderCheck(
            name="network",
            status="FAIL",
            code="provider_http_error",
            message=f"provider returned HTTP {exc.code}",
            hint_zh="Provider 返回了 HTTP 错误，请检查 base_url、模型名和账号权限。",
            details={"status": exc.code},
        )
    if isinstance(exc, URLError):
        return ProviderCheck(
            name="network",
            status="FAIL",
            code="provider_network_error",
            message=str(exc),
            hint_zh="无法连接到 provider，请检查网络、代理和 base_url。",
            details={},
        )
    return ProviderCheck(
        name="network",
        status="FAIL",
        code="provider_unknown_error",
        message=str(exc),
        hint_zh="Provider 测试失败，请查看英文错误详情。",
        details={},
    )


def fetch_provider_models(
    *,
    provider_draft: dict[str, Any],
    api_key: str | None = None,
    root_dir: Path | None = None,
) -> dict[str, Any]:
    provider = draft_to_provider_config(provider_draft)
    credential = _api_key_for(provider, root_dir=root_dir, override=api_key)
    if not credential.found:
        return {
            "status": "FAIL",
            "code": "provider_key_missing",
            "message": f"missing credential for {provider.name}",
            "hint_zh": "请先保存 API key，或设置对应环境变量。",
            "credential_id": credential.credential_id,
            "credential_source": credential.source,
            "env_key": provider.env_key,
            "models": [],
        }
    if not provider.model_list.path_template:
        return {
            "status": "WARN",
            "code": "provider_model_list_unsupported",
            "message": "model list endpoint is not configured",
            "hint_zh": "这个 provider 没有配置模型列表接口，请手动填写模型。",
            "models": [],
        }
    try:
        url, headers = _build_url_and_headers_for_path(provider, credential.key, provider.models[0], provider.model_list.path_template)
        headers.update(provider.extra_headers)
        data = _request_json(url, None, headers, provider.limits.timeout_seconds, provider.model_list.method)
        found: list[str] = []
        for path in provider.model_list.response_paths:
            for raw in _extract_text_by_paths(data, [path]).splitlines():
                model = raw.strip()
                if model and model not in found:
                    found.append(model.removeprefix("models/"))
        status = "PASS" if found else "WARN"
        return {
            "status": status,
            "code": "provider_models_found" if found else "provider_models_empty",
            "message": f"found {len(found)} models" if found else "model list response contained no models",
            "hint_zh": f"已拉取到 {len(found)} 个模型。" if found else "接口返回成功，但没有解析到模型；可以手动填写模型。",
            "credential_source": credential.source,
            "credential_id": credential.credential_id,
            "models": found,
        }
    except Exception as exc:  # noqa: BLE001 - returned as structured diagnostics
        check = _network_error_hint(exc)
        if check.status == "FAIL":
            check.status = "WARN"
        return {**asdict(check), "models": []}


def run_provider_connection_test(
    *,
    provider_draft: dict[str, Any],
    model: str,
    api_key: str | None = None,
    root_dir: Path | None = None,
) -> dict[str, Any]:
    models = [str(item).strip() for item in _as_list(provider_draft.get("models")) if str(item).strip()]
    if model and model not in models:
        models.insert(0, model)
    provider = draft_to_provider_config({**provider_draft, "models": models})
    credential = _api_key_for(provider, root_dir=root_dir, override=api_key)
    checks: list[ProviderCheck] = []
    if not credential.found:
        checks.append(
            ProviderCheck(
                name="api_key",
                status="FAIL",
                code="provider_key_missing",
                message=f"missing credential for {provider.name}",
                hint_zh="请先保存 API key，或设置对应环境变量。",
                details={
                    "env_key": provider.env_key,
                    "credential_id": credential.credential_id,
                    "credential_source": credential.source,
                },
            )
        )
        return {"status": "FAIL", "checks": [asdict(item) for item in checks]}
    attempts = min(max(1, provider.limits.retry), 3)
    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            req = NormalizedRequest(
                model=model,
                lines=["[1] ping"],
                source_lang="en",
                target_lang="zh-CN",
                temperature=0,
            )
            payload = _build_payload(provider, req)
            url, headers = _build_url_and_headers(provider, credential.key, model)
            headers.update(provider.extra_headers)
            if provider.compat_mode == "anthropic_messages":
                headers.setdefault("anthropic-version", "2023-06-01")
            data = _request_json(url, payload, headers, provider.limits.timeout_seconds, provider.endpoint.method)
            text = _extract_text_by_paths(data, provider.mapping.response.get("text_paths", []))
            if text:
                checks.append(
                    ProviderCheck(
                        name="network",
                        status="PASS",
                        code="provider_connection_ok",
                        message="provider returned text",
                        hint_zh="Provider 联网测试通过，模型可以返回文本。",
                        details={
                            "compat_mode": provider.compat_mode,
                            "credential_source": credential.source,
                            "attempts": attempt + 1,
                        },
                    )
                )
            else:
                checks.append(
                    ProviderCheck(
                        name="response_mapping",
                        status="FAIL",
                        code="provider_response_mapping_failed",
                        message="no text extracted from provider response",
                        hint_zh="Provider 有响应，但当前 response mapping 没有解析到文本。",
                        details={
                            "text_paths": provider.mapping.response.get("text_paths", []),
                            "response_shape": response_shape_summary(data),
                            "attempts": attempt + 1,
                        },
                    )
                )
            last_error = None
            break
        except Exception as exc:  # noqa: BLE001 - returned as structured diagnostics
            last_error = exc
            if attempt + 1 >= attempts or not _is_retryable_provider_error(exc):
                break
            time.sleep(min(2**attempt, 2))
    if last_error is not None:
        check = _network_error_hint(last_error)
        check.details = {**check.details, "attempts": attempts}
        checks.append(check)
    status = "FAIL" if any(item.status == "FAIL" for item in checks) else "WARN" if any(item.status == "WARN" for item in checks) else "PASS"
    return {"status": status, "checks": [asdict(item) for item in checks]}


def provider_payload(root_dir: Path) -> dict[str, Any]:
    config = load_app_config(root_dir=root_dir)
    return {
        "providers_file": str(resolve_providers_file(root_dir)),
        "auth_file": str(auth_file_path()),
        "provider_templates": provider_templates_payload(),
        "providers": [
            {
                **{
                    key: value
                    for key, value in to_plain(provider).items()
                    if key != "credential_root_dir"
                },
                "credential_id": provider_credential_id(provider),
                "has_key": resolve_provider_credential(provider, root_dir=root_dir).found,
                "credential_source": resolve_provider_credential(provider, root_dir=root_dir).source,
            }
            for provider in sorted(config.providers.values(), key=lambda item: item.name)
        ],
    }


def save_auth_credential(*, credential_id: str, value: str) -> dict[str, Any]:
    path = write_auth_credential(credential_id, value)
    return {"ok": True, "credential_id": credential_id, "auth_file": str(path)}


def delete_saved_auth_credential(*, credential_id: str) -> dict[str, Any]:
    deleted = delete_auth_credential(credential_id)
    return {"ok": True, "deleted": deleted, "credential_id": credential_id, "auth_file": str(auth_file_path())}
