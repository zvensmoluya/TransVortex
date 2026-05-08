from __future__ import annotations

import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError

import yaml

from .config import load_app_config, resolve_providers_file
from .models import (
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    ModelListConfig,
    NormalizedRequest,
    ProviderConfig,
    ProviderLimits,
)
from .providers.factory import (
    _build_payload,
    _build_url_and_headers,
    _build_url_and_headers_for_path,
    _extract_text_by_paths,
    _request_json,
)
from .utils import to_plain


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
            "max_batch_lines": 50,
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
            "max_batch_lines": 50,
        },
    },
    "openai_completions": {
        "label": "OpenAI Completions",
        "api_type": "openai-compatible",
        "compat_mode": "openai_completions",
        "base_url": "https://api.openai.com/v1",
        "endpoint": {"path_template": "/completions", "method": "POST"},
        "auth": {"type": "bearer", "header_name": "Authorization", "prefix": "Bearer "},
        "request_mapping": {"style": "openai_completions", "max_tokens": 4096},
        "response_mapping": {"text_paths": ["choices[0].text"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": False,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 50,
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
        "request_mapping": {"style": "anthropic_messages", "max_tokens": 4096},
        "response_mapping": {"text_paths": ["content[].text"]},
        "model_list": {"path_template": "/models", "method": "GET", "response_paths": ["data[].id"]},
        "capabilities": {
            "supports_system_prompt": True,
            "supports_temperature": True,
            "supports_json_mode": False,
            "max_batch_lines": 50,
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
            "max_batch_lines": 50,
        },
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


def _slug_env_key(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper()
    return f"TVX_PROVIDER_{slug or 'CUSTOM'}_API_KEY"


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


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
            max_batch_lines=int(capabilities_raw.get("max_batch_lines", capabilities_raw.get("maxBatchLines", 50))),
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


def write_env_secret(root_dir: Path, env_key: str, value: str) -> None:
    env_key = env_key.strip()
    if not env_key:
        raise ValueError("env_key is required")
    dotenv_path = root_dir / ".env"
    entries: dict[str, str] = {}
    if dotenv_path.exists():
        for line in dotenv_path.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.strip().startswith("#") or "=" not in line:
                continue
            key, existing = line.split("=", 1)
            entries[key.strip()] = existing.strip()
    entries[env_key] = value
    body = "".join(f"{key}={entries[key]}\n" for key in sorted(entries))
    dotenv_path.write_text(body, encoding="utf-8")
    os.environ[env_key] = value


def save_provider_config(
    *,
    root_dir: Path,
    provider_draft: dict[str, Any],
    api_key: str | None = None,
) -> dict[str, Any]:
    providers_file = root_dir / "providers.local.yaml"
    existing = _read_yaml(providers_file if providers_file.exists() else resolve_providers_file(root_dir))
    provider = draft_to_provider_config(provider_draft)
    rows = [row for row in _as_list(existing.get("providers")) if row.get("name") != provider.name]
    rows.append(provider_config_to_yaml_row(provider))
    primary = _as_dict(_as_dict(existing.get("routing")).get("primary"))
    if not primary.get("provider"):
        primary = {"provider": provider.name, "model": provider.models[0] if provider.models else ""}
    routing = {
        "primary": primary,
        "fallback": _as_list(_as_dict(existing.get("routing")).get("fallback")),
    }
    _write_yaml(providers_file, {"providers": rows, "routing": routing})
    if api_key:
        write_env_secret(root_dir, provider.env_key, api_key)
    return {
        "provider": provider.name,
        "providers_file": str(providers_file),
        "has_key": bool(os.getenv(provider.env_key)),
    }


def delete_provider_config(*, root_dir: Path, name: str) -> dict[str, Any]:
    providers_file = root_dir / "providers.local.yaml"
    if not providers_file.exists():
        return {"deleted": False, "providers_file": str(providers_file)}
    existing = _read_yaml(providers_file)
    rows = _as_list(existing.get("providers"))
    kept = [row for row in rows if row.get("name") != name]
    if len(kept) == len(rows):
        return {"deleted": False, "providers_file": str(providers_file)}
    routing = _as_dict(existing.get("routing"))
    primary = _as_dict(routing.get("primary"))
    if primary.get("provider") == name:
        first = kept[0] if kept else {}
        models = _as_list(first.get("models"))
        routing["primary"] = {"provider": first.get("name", ""), "model": models[0] if models else ""}
    _write_yaml(providers_file, {"providers": kept, "routing": routing or {"primary": {"provider": "", "model": ""}, "fallback": []}})
    return {"deleted": True, "providers_file": str(providers_file)}


def _api_key_for(config: ProviderConfig, override: str | None = None) -> str:
    if override:
        return override
    return os.getenv(config.env_key, "")


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
) -> dict[str, Any]:
    provider = draft_to_provider_config(provider_draft)
    key = _api_key_for(provider, api_key)
    if not key:
        return {
            "status": "FAIL",
            "code": "provider_key_missing",
            "message": f"missing environment variable: {provider.env_key}",
            "hint_zh": "请先填写并保存 API key，或确认对应环境变量已设置。",
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
        url, headers = _build_url_and_headers_for_path(provider, key, provider.models[0], provider.model_list.path_template)
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
) -> dict[str, Any]:
    models = [str(item).strip() for item in _as_list(provider_draft.get("models")) if str(item).strip()]
    if model and model not in models:
        models.insert(0, model)
    provider = draft_to_provider_config({**provider_draft, "models": models})
    key = _api_key_for(provider, api_key)
    checks: list[ProviderCheck] = []
    if not key:
        checks.append(
            ProviderCheck(
                name="api_key",
                status="FAIL",
                code="provider_key_missing",
                message=f"missing environment variable: {provider.env_key}",
                hint_zh="请先填写并保存 API key，或确认对应环境变量已设置。",
                details={"env_key": provider.env_key},
            )
        )
        return {"status": "FAIL", "checks": [asdict(item) for item in checks]}
    try:
        req = NormalizedRequest(
            model=model,
            lines=["[1] ping"],
            source_lang="en",
            target_lang="zh-CN",
            temperature=0,
        )
        payload = _build_payload(provider, req)
        url, headers = _build_url_and_headers(provider, key, model)
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
                    details={"compat_mode": provider.compat_mode},
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
                    details={"text_paths": provider.mapping.response.get("text_paths", [])},
                )
            )
    except Exception as exc:  # noqa: BLE001 - returned as structured diagnostics
        checks.append(_network_error_hint(exc))
    status = "FAIL" if any(item.status == "FAIL" for item in checks) else "WARN" if any(item.status == "WARN" for item in checks) else "PASS"
    return {"status": status, "checks": [asdict(item) for item in checks]}


def provider_payload(root_dir: Path) -> dict[str, Any]:
    config = load_app_config(root_dir=root_dir)
    return {
        "providers_file": str(resolve_providers_file(root_dir)),
        "provider_templates": provider_templates_payload(),
        "providers": [
            {
                **to_plain(provider),
                "has_key": bool(os.getenv(provider.env_key)),
            }
            for provider in sorted(config.providers.values(), key=lambda item: item.name)
        ],
    }
