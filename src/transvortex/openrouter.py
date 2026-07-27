from __future__ import annotations

import re
from typing import Any

import httpx

from .http import HttpTransportError, request_json_with_retry, response_retry_after_seconds


OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
OPENROUTER_ENV_KEY = "OPENROUTER_API_KEY"


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
