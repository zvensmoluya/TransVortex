from __future__ import annotations

import json
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Any, Callable, Iterator
from urllib.error import HTTPError, URLError

import httpx

from . import __version__


DEFAULT_USER_AGENT = f"TransVortex/{__version__}"
DEFAULT_JSON_HEADERS = {
    "Accept": "application/json",
    "User-Agent": DEFAULT_USER_AGENT,
}
RETRYABLE_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504, 524, 529}
MAX_RETRY_AFTER_SECONDS = 60.0

_HTTP2_AVAILABLE: bool | None = None
_CLIENTS: dict[tuple, httpx.Client] = {}


class HttpTransportError(RuntimeError):
    def __init__(
        self,
        error_type: str,
        message: str,
        *,
        status_code: int | None = None,
        retry_after_seconds: float | None = None,
    ) -> None:
        super().__init__(message)
        self.error_type = error_type
        self.status_code = status_code
        self.retry_after_seconds = retry_after_seconds


StatusErrorFactory = Callable[[httpx.Response, str], HttpTransportError | None]
PayloadErrorFactory = Callable[[Any, httpx.Response, str], HttpTransportError | None]


def merge_default_headers(headers: dict[str, str] | None = None, **defaults: str) -> dict[str, str]:
    merged = {key: value for key, value in defaults.items() if value}
    for key, value in (headers or {}).items():
        existing_key = next((item for item in merged if item.lower() == key.lower()), None)
        if existing_key is not None:
            merged.pop(existing_key)
        merged[str(key)] = str(value)
    return merged


def http2_enabled(requested: bool = True) -> bool:
    global _HTTP2_AVAILABLE
    if not requested:
        return False
    if _HTTP2_AVAILABLE is None:
        try:
            import h2  # noqa: F401

            _HTTP2_AVAILABLE = True
        except ImportError:
            _HTTP2_AVAILABLE = False
    return bool(_HTTP2_AVAILABLE)


def build_http_timeout(
    *,
    connect: float,
    read: float,
    write: float,
    pool: float,
) -> httpx.Timeout:
    return httpx.Timeout(
        connect=float(connect),
        read=float(read),
        write=float(write),
        pool=float(pool),
    )


def build_http_limits(
    *,
    max_connections: int,
    max_keepalive_connections: int,
) -> httpx.Limits:
    return httpx.Limits(
        max_connections=max(1, int(max_connections)),
        max_keepalive_connections=max(0, int(max_keepalive_connections)),
    )


def _network_value(network: Any | None, key: str, default: Any) -> Any:
    if isinstance(network, dict):
        return network.get(key, default)
    return getattr(network, key, default)


def _network_transport_options(
    network: Any | None,
    *,
    trust_env: bool,
) -> tuple[bool, str | None, tuple[str, int]]:
    if not trust_env:
        return False, None, ("bypass", 0)
    mode = str(_network_value(network, "mode", "system") or "system").strip().lower()
    try:
        proxy_port = int(_network_value(network, "proxy_port", 0) or 0)
    except (TypeError, ValueError):
        proxy_port = 0
    if mode == "direct":
        return False, None, ("direct", 0)
    if mode == "local_proxy" and 1 <= proxy_port <= 65535:
        return False, f"http://127.0.0.1:{proxy_port}", ("local_proxy", proxy_port)
    return True, None, ("system", 0)


def build_httpx_client(
    *,
    timeout: httpx.Timeout | float | int,
    limits: httpx.Limits | None = None,
    http2: bool = True,
    trust_env: bool = True,
    network: Any | None = None,
    follow_redirects: bool = False,
) -> httpx.Client:
    effective_trust_env, proxy, _network_key = _network_transport_options(
        network,
        trust_env=trust_env,
    )
    kwargs: dict[str, Any] = {
        "timeout": timeout,
        "http2": http2_enabled(http2),
        "trust_env": effective_trust_env,
    }
    if limits is not None:
        kwargs["limits"] = limits
    if proxy is not None:
        kwargs["proxy"] = proxy
    if follow_redirects:
        kwargs["follow_redirects"] = True
    return httpx.Client(**kwargs)


def get_shared_httpx_client(
    key: tuple,
    *,
    timeout: httpx.Timeout | float | int,
    limits: httpx.Limits | None = None,
    http2: bool = True,
    trust_env: bool = True,
    network: Any | None = None,
) -> httpx.Client:
    _effective_trust_env, _proxy, network_key = _network_transport_options(
        network,
        trust_env=trust_env,
    )
    cache_key = (key, http2_enabled(http2), network_key)
    client = _CLIENTS.get(cache_key)
    if client is None or client.is_closed:
        client = build_httpx_client(
            timeout=timeout,
            limits=limits,
            http2=http2,
            trust_env=trust_env,
            network=network,
        )
        _CLIENTS[cache_key] = client
    return client


def close_shared_httpx_clients() -> None:
    clients = list(_CLIENTS.values())
    _CLIENTS.clear()
    for client in clients:
        try:
            client.close()
        except Exception:
            pass


def classify_http_error(exc: Exception) -> str:
    text = str(exc).lower()
    if isinstance(exc, HttpTransportError):
        return exc.error_type
    if isinstance(exc, httpx.ConnectTimeout):
        return "connect_timeout"
    if isinstance(exc, httpx.ReadTimeout):
        return "read_timeout"
    if isinstance(exc, httpx.WriteTimeout):
        return "write_timeout"
    if isinstance(exc, httpx.PoolTimeout):
        return "pool_timeout"
    if isinstance(exc, httpx.TimeoutException):
        return "provider_timeout"
    if isinstance(exc, httpx.HTTPStatusError):
        return _classify_http_status(exc.response.status_code)
    if isinstance(exc, httpx.TransportError):
        return "network_error"
    if isinstance(exc, HTTPError):
        return _classify_http_status(exc.code)
    if isinstance(exc, URLError):
        return "timeout" if "timed out" in text else "network_error"
    if "timed out" in text:
        return "timeout"
    if "mismatch" in text:
        return "mismatch_lines"
    return "unknown_error"


def _classify_http_status(code: int) -> str:
    if code in {401, 403}:
        return "auth_error"
    if code == 429:
        return "rate_limit"
    if code == 408:
        return "provider_timeout"
    if code == 502:
        return "bad_gateway"
    if code == 503:
        return "service_unavailable"
    if code == 504:
        return "gateway_timeout"
    if code == 524:
        return "gateway_timeout"
    if code == 529:
        return "service_unavailable"
    if 500 <= code <= 599:
        return "provider_server_error"
    return "bad_schema"


def is_retryable_http_error(exc: Exception) -> bool:
    if isinstance(exc, HttpTransportError):
        if exc.status_code is not None:
            return exc.status_code in RETRYABLE_STATUS_CODES
        return exc.error_type in {
            "connect_timeout",
            "read_timeout",
            "write_timeout",
            "pool_timeout",
            "provider_timeout",
            "timeout",
            "network_error",
            "rate_limit",
            "bad_gateway",
            "service_unavailable",
            "gateway_timeout",
            "provider_server_error",
        }
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in RETRYABLE_STATUS_CODES
    if isinstance(exc, httpx.TimeoutException):
        return True
    if isinstance(exc, httpx.TransportError):
        return isinstance(
            exc,
            (
                httpx.ConnectError,
                httpx.ReadError,
                httpx.WriteError,
                httpx.NetworkError,
                httpx.RemoteProtocolError,
            ),
        ) or _has_retryable_transport_marker(exc)
    if isinstance(exc, HTTPError):
        return exc.code in RETRYABLE_STATUS_CODES
    if isinstance(exc, URLError):
        return _has_retryable_transport_marker(exc)
    return _has_retryable_transport_marker(exc)


def _has_retryable_transport_marker(exc: Exception) -> bool:
    lowered = str(exc).lower()
    return any(
        marker in lowered
        for marker in (
            "timed out",
            "timeout",
            "temporarily unavailable",
            "unexpected_eof",
            "eof occurred",
            "connection reset",
            "connection aborted",
            "remote end closed connection",
        )
    )


def response_text_preview(response: httpx.Response) -> str:
    try:
        return response.text[:500]
    except httpx.ResponseNotRead:
        try:
            response.read()
            return response.text[:500]
        except Exception:
            return ""
    except Exception:
        return ""


def response_retry_after_seconds(response: httpx.Response) -> float | None:
    raw = str(response.headers.get("retry-after") or "").strip()
    if not raw:
        return None
    try:
        seconds = float(raw)
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(raw)
        except (TypeError, ValueError, OverflowError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=timezone.utc)
        seconds = (retry_at - datetime.now(timezone.utc)).total_seconds()
    return max(0.0, seconds)


def raise_for_status(
    response: httpx.Response,
    *,
    context: str = "upstream",
    status_error_factory: StatusErrorFactory | None = None,
) -> None:
    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        retry_after_seconds = response_retry_after_seconds(response)
        if status_error_factory is not None:
            mapped = status_error_factory(response, context)
            if mapped is not None:
                if mapped.retry_after_seconds is None:
                    mapped.retry_after_seconds = retry_after_seconds
                raise mapped from exc
        raise HttpTransportError(
            classify_http_error(exc),
            f"{context} returned HTTP {response.status_code}: {response_text_preview(response)}",
            status_code=response.status_code,
            retry_after_seconds=retry_after_seconds,
        ) from exc


def transport_meta(
    response: httpx.Response,
    *,
    streaming: bool,
    http2_requested: bool = True,
    stream_meta: dict[str, Any] | None = None,
    attempts: int = 1,
) -> dict[str, Any]:
    http_version: Any = response.extensions.get("http_version", b"")
    if isinstance(http_version, bytes):
        http_version = http_version.decode("ascii", errors="ignore")
    meta: dict[str, Any] = {
        "transport": "httpx",
        "http_version": http_version,
        "http2_requested": bool(http2_requested),
        "http2_enabled": http2_enabled(http2_requested),
        "streaming": streaming,
        "attempts": max(1, int(attempts)),
    }
    headers = getattr(response, "headers", {})
    generation_id = str(headers.get("x-generation-id") or "").strip()
    if generation_id:
        meta["generation_id"] = generation_id
    if stream_meta:
        meta.update(stream_meta)
    return meta


def _request_headers(headers: dict[str, str] | None, *, json_body: bool) -> dict[str, str]:
    request_headers = merge_default_headers(headers, **DEFAULT_JSON_HEADERS)
    if json_body:
        request_headers = merge_default_headers(request_headers, **{"Content-Type": "application/json"})
    return request_headers


def request_json_with_retry(
    method: str,
    url: str,
    *,
    json_payload: Any | None = None,
    data: Any | None = None,
    files: Any | None = None,
    headers: dict[str, str] | None = None,
    timeout: httpx.Timeout | float | int = 30.0,
    limits: httpx.Limits | None = None,
    http2: bool = True,
    retry: int = 1,
    client: httpx.Client | None = None,
    context: str = "upstream",
    trust_env: bool = True,
    network: Any | None = None,
    status_error_factory: StatusErrorFactory | None = None,
    payload_error_factory: PayloadErrorFactory | None = None,
) -> tuple[Any, dict[str, Any]]:
    attempts = max(1, int(retry or 1))
    request_headers = _request_headers(headers, json_body=json_payload is not None)
    owned_client = client is None
    active_client = client or build_httpx_client(
        timeout=timeout,
        limits=limits,
        http2=http2,
        trust_env=trust_env,
        network=network,
    )
    try:
        last_exc: Exception | None = None
        for attempt in range(attempts):
            try:
                response = active_client.request(
                    method=method,
                    url=url,
                    json=json_payload,
                    data=data,
                    files=files,
                    headers=request_headers,
                )
                raise_for_status(
                    response,
                    context=context,
                    status_error_factory=status_error_factory,
                )
                try:
                    payload = response.json()
                except json.JSONDecodeError as exc:
                    raise HttpTransportError("bad_schema", f"bad_schema: invalid JSON response: {exc}") from exc
                if payload_error_factory is not None:
                    payload_error = payload_error_factory(payload, response, context)
                    if payload_error is not None:
                        raise payload_error
                return payload, transport_meta(
                    response,
                    streaming=False,
                    http2_requested=http2,
                    attempts=attempt + 1,
                )
            except Exception as exc:
                last_exc = exc
                if attempt + 1 >= attempts or not is_retryable_http_error(exc):
                    raise
                retry_after_seconds = getattr(exc, "retry_after_seconds", None)
                delay = (
                    float(retry_after_seconds)
                    if isinstance(retry_after_seconds, (int, float))
                    and retry_after_seconds > 0
                    else min(0.5 * (2**attempt), 4.0)
                )
                time.sleep(min(delay, MAX_RETRY_AFTER_SECONDS))
        if last_exc is not None:
            raise last_exc
        raise HttpTransportError("network_error", "http request failed before attempting request")
    finally:
        if owned_client:
            active_client.close()


@contextmanager
def stream_with_meta(
    client: httpx.Client,
    method: str,
    url: str,
    *,
    json_payload: Any | None = None,
    headers: dict[str, str] | None = None,
    context: str = "upstream",
) -> Iterator[httpx.Response]:
    request_headers = _request_headers(headers, json_body=json_payload is not None)
    with client.stream(method=method, url=url, json=json_payload, headers=request_headers) as response:
        raise_for_status(response, context=context)
        yield response
