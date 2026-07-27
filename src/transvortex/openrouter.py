from __future__ import annotations

import math
import re
from typing import Any

import httpx

from .http import (
    DEFAULT_JSON_HEADERS,
    HttpTransportError,
    merge_default_headers,
    request_json_with_retry,
    response_retry_after_seconds,
)


OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
OPENROUTER_ENV_KEY = "OPENROUTER_API_KEY"
OPENROUTER_CURRENT_KEY_URL = f"{OPENROUTER_BASE_URL}/key"


_CURRENT_KEY_USD_FIELDS = {
    "usage": "usage_usd",
    "usage_daily": "usage_daily_usd",
    "usage_weekly": "usage_weekly_usd",
    "usage_monthly": "usage_monthly_usd",
    "byok_usage": "byok_usage_usd",
    "byok_usage_daily": "byok_usage_daily_usd",
    "byok_usage_weekly": "byok_usage_weekly_usd",
    "byok_usage_monthly": "byok_usage_monthly_usd",
    "limit": "limit_usd",
    "limit_remaining": "limit_remaining_usd",
}


_ERROR_TYPE_BY_STATUS = {
    400: "invalid_request",
    401: "authentication",
    402: "payment_required",
    403: "permission_denied",
    404: "not_found",
    408: "timeout",
    412: "precondition_failed",
    413: "payload_too_large",
    422: "unprocessable",
    429: "rate_limit_exceeded",
    500: "server",
    502: "provider_unavailable",
    503: "provider_overloaded",
    504: "timeout",
    524: "timeout",
    529: "provider_overloaded",
}

_TRANSPORT_TYPE_BY_OPENROUTER_TYPE = {
    "authentication": "auth_error",
    "permission_denied": "auth_error",
    "payment_required": "payment_required",
    "rate_limit_exceeded": "rate_limit",
    "provider_overloaded": "service_unavailable",
    "provider_unavailable": "bad_gateway",
    "timeout": "provider_timeout",
    "server": "provider_server_error",
    "unmapped": "provider_server_error",
    "invalid_request": "invalid_request",
    "invalid_prompt": "invalid_request",
    "not_found": "not_found",
    "precondition_failed": "invalid_request",
    "payload_too_large": "payload_too_large",
    "unprocessable": "unprocessable",
    "content_policy_violation": "content_policy_violation",
    "refusal": "content_policy_violation",
}


class OpenRouterTransportError(HttpTransportError):
    def __init__(
        self,
        error_type: str,
        message: str,
        *,
        status_code: int | None,
        openrouter_error_type: str,
        provider_code: str = "",
        generation_id: str = "",
        retry_after_seconds: float | None = None,
    ) -> None:
        super().__init__(
            error_type,
            message,
            status_code=status_code,
            retry_after_seconds=retry_after_seconds,
        )
        self.openrouter_error_type = openrouter_error_type
        self.provider_code = provider_code
        self.generation_id = generation_id


def request_openrouter_json_with_retry(
    method: str,
    url: str,
    **kwargs: Any,
) -> tuple[Any, dict[str, Any]]:
    if "status_error_factory" in kwargs or "payload_error_factory" in kwargs:
        raise TypeError("OpenRouter request error factories are managed internally")
    return request_json_with_retry(
        method,
        url,
        status_error_factory=_openrouter_status_error,
        payload_error_factory=_openrouter_payload_error,
        **kwargs,
    )


def fetch_openrouter_current_key_usage(
    api_key: str,
    *,
    timeout: float = 30.0,
    http2: bool = True,
    retry: int = 1,
    network: Any | None = None,
    client: httpx.Client | None = None,
) -> dict[str, Any]:
    """Read spend metadata for the authenticated ordinary OpenRouter API key.

    The upstream payload contains key identity and ownership fields.  Rebuild a
    stable allowlisted response here instead of returning that payload through
    the Local Service boundary.
    """

    normalized_key = str(api_key or "").strip()
    if not normalized_key:
        raise ValueError("OpenRouter API key is required")
    payload, _transport_meta = request_openrouter_json_with_retry(
        "GET",
        OPENROUTER_CURRENT_KEY_URL,
        headers=merge_default_headers(
            {"Authorization": f"Bearer {normalized_key}"},
            **DEFAULT_JSON_HEADERS,
        ),
        timeout=timeout,
        http2=http2,
        retry=retry,
        client=client,
        context="OpenRouter current key usage",
        trust_env=True,
        network=network,
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), dict):
        raise HttpTransportError(
            "bad_schema",
            "bad_schema: unexpected OpenRouter current key response",
        )
    return _safe_current_key_usage(payload["data"])


def _safe_current_key_usage(data: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {"currency": "USD"}
    for upstream_name, stable_name in _CURRENT_KEY_USD_FIELDS.items():
        result[stable_name] = _safe_usd_value(data.get(upstream_name))
    limit_reset = data.get("limit_reset")
    result["limit_reset"] = (
        limit_reset
        if isinstance(limit_reset, str) and limit_reset in {"daily", "weekly", "monthly"}
        else None
    )
    result["is_free_tier"] = (
        data.get("is_free_tier")
        if isinstance(data.get("is_free_tier"), bool)
        else None
    )
    result["expires_at"] = _safe_iso_timestamp(data.get("expires_at"))
    return result


def _safe_usd_value(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    normalized = float(value)
    return normalized if math.isfinite(normalized) else None


def _safe_iso_timestamp(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    if not normalized or len(normalized) > 80:
        return None
    if not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
        normalized,
    ):
        return None
    return normalized


def _openrouter_status_error(
    response: httpx.Response,
    context: str,
) -> HttpTransportError | None:
    if response.status_code < 400:
        return None
    return _build_openrouter_error(
        _response_payload(response),
        status_code=response.status_code,
        context=context,
        generation_id=str(response.headers.get("x-generation-id") or "").strip(),
        retry_after_seconds=response_retry_after_seconds(response),
    )


def _openrouter_payload_error(
    payload: Any,
    response: httpx.Response,
    context: str,
) -> HttpTransportError | None:
    if not isinstance(payload, dict) or not isinstance(payload.get("error"), dict):
        return None
    status_code = _payload_status_code(payload)
    return _build_openrouter_error(
        payload,
        status_code=status_code,
        context=context,
        generation_id=str(response.headers.get("x-generation-id") or "").strip(),
        retry_after_seconds=response_retry_after_seconds(response),
    )


def _build_openrouter_error(
    payload: dict[str, Any],
    *,
    status_code: int | None,
    context: str,
    generation_id: str,
    retry_after_seconds: float | None,
) -> OpenRouterTransportError:
    error = payload.get("error") if isinstance(payload.get("error"), dict) else {}
    metadata = error.get("metadata") if isinstance(error.get("metadata"), dict) else {}
    openrouter_error_type = _normalize_error_type(
        metadata.get("error_type")
        or error.get("error_type")
        or payload.get("error_type")
        or _string_error_code(error.get("code"))
        or _ERROR_TYPE_BY_STATUS.get(status_code or 0)
        or "unmapped"
    )
    transport_error_type = _TRANSPORT_TYPE_BY_OPENROUTER_TYPE.get(
        openrouter_error_type,
        "provider_server_error" if status_code and status_code >= 500 else "invalid_request",
    )
    provider_code = _safe_text(metadata.get("provider_code"), limit=120)
    upstream_message = _safe_text(error.get("message"), limit=500)
    if not upstream_message:
        upstream_message = "OpenRouter request failed"
    status_text = f" HTTP {status_code}" if status_code is not None else ""
    return OpenRouterTransportError(
        transport_error_type,
        f"openrouter_{openrouter_error_type}: {context} returned{status_text}: {upstream_message}",
        status_code=status_code,
        openrouter_error_type=openrouter_error_type,
        provider_code=provider_code,
        generation_id=generation_id,
        retry_after_seconds=retry_after_seconds,
    )


def _response_payload(response: httpx.Response) -> dict[str, Any]:
    try:
        payload = response.json()
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def _payload_status_code(payload: dict[str, Any]) -> int | None:
    error = payload.get("error") if isinstance(payload.get("error"), dict) else {}
    raw = error.get("code")
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str) and raw.strip().isdigit():
        return int(raw.strip())
    return None


def _string_error_code(value: Any) -> str:
    if isinstance(value, str) and value.strip() and not value.strip().isdigit():
        return value.strip()
    return ""


def _normalize_error_type(value: Any) -> str:
    normalized = re.sub(r"[^a-z0-9_]+", "_", str(value or "").strip().lower()).strip("_")
    return normalized or "unmapped"


def _safe_text(value: Any, *, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]
