from __future__ import annotations

import os
import urllib.parse
from dataclasses import asdict, dataclass

from ..app.config import load_app_config
from ..app.models import NormalizedRequest, ProviderConfig
from .factory import _build_payload, _build_url_and_headers, _extract_text_by_paths, response_shape_summary


VALID_API_TYPES = {"openai", "openai-compatible", "anthropic", "gemini-compatible", "custom"}
VALID_COMPAT_MODES = {
    "openai_chat",
    "openai_responses",
    "openai_completions",
    "anthropic_messages",
    "gemini_generate_content",
    "custom_json",
}


@dataclass
class ProbeItem:
    name: str
    status: str
    message: str
    details: dict


def _mock_response_for_compat_mode(compat_mode: str) -> dict:
    if compat_mode == "openai_chat":
        return {"choices": [{"message": {"content": "[1] ok"}}]}
    if compat_mode == "openai_responses":
        return {"output_text": "[1] ok"}
    if compat_mode == "openai_completions":
        return {"choices": [{"text": "[1] ok"}]}
    if compat_mode == "anthropic_messages":
        return {"content": [{"text": "[1] ok"}]}
    if compat_mode == "gemini_generate_content":
        return {"candidates": [{"content": {"parts": [{"text": "[1] ok"}]}}]}
    if compat_mode == "custom_json":
        return {"text": "[1] ok"}
    return {}


def _mask_token(value: str) -> str:
    if len(value) <= 6:
        return "***"
    return f"{value[:3]}***{value[-2:]}"


def _build_auth_preview(config: ProviderConfig, model: str) -> dict:
    url, headers = _build_url_and_headers(config, "DUMMY_API_KEY", model)
    preview_headers = {}
    for key, value in headers.items():
        preview_headers[key] = _mask_token(value)
    parsed = urllib.parse.urlsplit(url)
    query_keys = sorted({key for key, _value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)})
    return {"url": url, "headers": preview_headers, "query_keys": query_keys}


def probe_provider(
    *,
    root_dir,
    providers_file=None,
    provider_name: str | None = None,
    model: str | None = None,
    source_lang: str = "en",
    target_lang: str = "zh-CN",
) -> dict:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file)
    provider_name = provider_name or config.routing.primary.provider
    model = model or config.routing.primary.model
    items: list[ProbeItem] = []

    provider = config.providers.get(provider_name)
    if not provider:
        items.append(
            ProbeItem(
                name="provider_exists",
                status="FAIL",
                message=f"provider not found: {provider_name}",
                details={},
            )
        )
        return {"provider": provider_name, "model": model, "checks": [asdict(i) for i in items]}

    items.append(
        ProbeItem(
            name="provider_exists",
            status="PASS",
            message="provider exists",
            details={"provider": provider_name},
        )
    )

    api_ok = provider.api_type in VALID_API_TYPES
    items.append(
        ProbeItem(
            name="api_type_valid",
            status="PASS" if api_ok else "FAIL",
            message="api_type is valid" if api_ok else f"unsupported api_type: {provider.api_type}",
            details={"api_type": provider.api_type},
        )
    )

    compat_ok = provider.compat_mode in VALID_COMPAT_MODES
    items.append(
        ProbeItem(
            name="compat_mode_valid",
            status="PASS" if compat_ok else "FAIL",
            message="compat_mode is valid" if compat_ok else f"unsupported compat_mode: {provider.compat_mode}",
            details={"compat_mode": provider.compat_mode},
        )
    )

    model_known = model in provider.models
    items.append(
        ProbeItem(
            name="model_in_provider_list",
            status="PASS" if model_known else "WARN",
            message="model exists in provider.models" if model_known else "model not present in provider.models",
            details={"model": model, "provider_models": provider.models},
        )
    )

    env_set = bool(os.getenv(provider.env_key))
    items.append(
        ProbeItem(
            name="env_key_present",
            status="PASS" if env_set else "FAIL",
            message="environment variable is set" if env_set else f"missing environment variable: {provider.env_key}",
            details={"env_key": provider.env_key},
        )
    )

    try:
        auth_preview = _build_auth_preview(provider, model)
        items.append(
            ProbeItem(
                name="url_and_auth_build",
                status="PASS",
                message="url and auth preview generated",
                details=auth_preview,
            )
        )
    except Exception as exc:
        items.append(
            ProbeItem(
                name="url_and_auth_build",
                status="FAIL",
                message=str(exc),
                details={},
            )
        )

    try:
        req = NormalizedRequest(
            model=model,
            lines=["[1] hello"],
            source_lang=source_lang,
            target_lang=target_lang,
        )
        payload = _build_payload(provider, req)
        items.append(
            ProbeItem(
                name="request_payload_build",
                status="PASS",
                message="request payload generated",
                details={
                    "top_level_keys": sorted(payload.keys()),
                    "query_params": sorted((provider.mapping.request.get("query_params") or {}).keys()),
                },
            )
        )
    except Exception as exc:
        items.append(
            ProbeItem(
                name="request_payload_build",
                status="FAIL",
                message=str(exc),
                details={},
            )
        )

    try:
        sample = _mock_response_for_compat_mode(provider.compat_mode)
        text_paths = provider.mapping.response.get("text_paths", [])
        text = _extract_text_by_paths(sample, text_paths)
        if text:
            items.append(
                ProbeItem(
                    name="response_mapping_extract",
                    status="PASS",
                    message="response mapping extracted text from sample",
                    details={"text_paths": text_paths},
                )
            )
        else:
            items.append(
                ProbeItem(
                    name="response_mapping_extract",
                    status="FAIL",
                    message="response mapping did not extract text from sample",
                    details={"text_paths": text_paths, "sample_shape": response_shape_summary(sample)},
                )
            )
    except Exception as exc:
        items.append(
            ProbeItem(
                name="response_mapping_extract",
                status="FAIL",
                message=str(exc),
                details={},
            )
        )

    return {"provider": provider_name, "model": model, "checks": [asdict(i) for i in items]}


def probe_exit_code(probe_report: dict, strict: bool) -> int:
    checks = probe_report.get("checks", [])
    has_fail = any(row.get("status") == "FAIL" for row in checks)
    if strict and has_fail:
        return 1
    return 0
