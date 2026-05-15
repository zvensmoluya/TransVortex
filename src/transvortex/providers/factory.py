from __future__ import annotations

import json
import re
import time
import urllib.parse
import posixpath
from urllib.error import HTTPError, URLError
from dataclasses import dataclass
from typing import Any

import httpx

from ..app.models import NormalizedRequest, NormalizedResponse, ProviderConfig
from ..app.credentials import resolve_provider_credential
from ..http import DEFAULT_JSON_HEADERS, merge_default_headers
from ..prompts import FALLBACK_TRANSLATION_SYSTEM_PROMPT
from .base import ProviderClient


_CLIENTS: dict[tuple, httpx.Client] = {}
_HTTP2_AVAILABLE: bool | None = None


class ProviderTransportError(RuntimeError):
    def __init__(self, error_type: str, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.error_type = error_type
        self.status_code = status_code


def _extract_numbered_lines(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if re.match(r"^\[\d+\]\s*", line):
            out.append(line)
            continue
        normalized = re.match(r"^(?:\(?\s*(\d+)\s*\)?|（\s*(\d+)\s*）)\s*[:：.)、-]\s*(.+)$", line)
        if normalized:
            seg_id = normalized.group(1) or normalized.group(2)
            text_body = normalized.group(3).strip()
            out.append(f"[{seg_id}] {text_body}")
    return out


TRANSLATION_SYSTEM_PROMPT = FALLBACK_TRANSLATION_SYSTEM_PROMPT


FIXED_TRANSLATION_CONSTRAINTS = (
    "Fixed output constraints:\n"
    "- Translate only the lines in TRANSLATE_ONLY.\n"
    "- Use CONTEXT_BEFORE and CONTEXT_AFTER only to understand tone, references, pronouns, and jokes.\n"
    "- Keep every requested [id] exactly unchanged.\n"
    "- Do not add, remove, merge, split, or renumber ids.\n"
    "- Output only numbered translated lines.\n"
    "- Do not output Markdown, explanations, summaries, notes, or context lines.\n"
    "- This is translation of user-provided subtitle text. Translate faithfully, including profanity, "
    "offensive language, sexual references, or violent dialogue if present. Do not censor, moralize, refuse, "
    "summarize, or add content."
)


def _section(title: str, lines: list[str]) -> str:
    body = "\n".join(lines) if lines else "(none)"
    return f"{title}\n{body}"


def _asr_uncertainty_section(ids: list[int]) -> str:
    if not ids:
        return ""
    unique_ids = sorted({int(item) for item in ids})
    lines = [f"- {item}" for item in unique_ids]
    return "\n".join(
        [
            "ASR_UNCERTAIN_LINES",
            *(lines or ["(none)"]),
            "These ids are internal risk hints only. Some listed source lines may contain ASR mishearing, malformed fragments, or punctuation errors. Use surrounding context and glossary to resolve clearly malformed ASR text, but do not invent unsupported content. Do not output this section or any uncertainty labels.",
        ]
    )


def _translation_prompt(
    req: NormalizedRequest,
    *,
    include_system_constraints: bool = False,
    include_asr_uncertainty_hints: bool = False,
) -> str:
    parts: list[str] = []
    if include_system_constraints:
        parts.append(TRANSLATION_SYSTEM_PROMPT)
    if req.prompt_mode == "compress":
        parts.extend(
            [
                "Subtitle compression mode:",
                "- Rewrite the existing translated subtitle to be shorter and easier to read.",
                "- Preserve meaning, tone, names, jokes, profanity, and key facts.",
                "- Keep the same [id] exactly unchanged.",
                "- Output only one numbered line.",
                "- Do not output Markdown, explanations, summaries, notes, or context lines.",
                f"Target language: {req.target_lang}.",
            ]
        )
        if req.style_prompt:
            parts.append("Compression instructions:\n" + req.style_prompt.strip())
        parts.extend(
            [
                f"Reason: {req.repair_reason or 'subtitle is too long for its display duration'}.",
                f"Current translation: {req.bad_translation or '(none)'}",
                _section("REFERENCE", req.context_before),
                _section("COMPRESS_ONLY", req.lines),
            ]
        )
        return "\n\n".join(parts)
    if req.prompt_mode == "memory_patch":
        parts.extend(
            [
                "Translation memory extraction mode:",
                "- Analyze the provided source and translated subtitles.",
                "- Return only the requested JSON object.",
                "- Do not output Markdown, explanations, numbered subtitle lines, or extra text.",
            ]
        )
        if req.style_prompt:
            parts.append(req.style_prompt.strip())
        return "\n\n".join(parts)
    if req.prompt_mode == "reflow":
        parts.extend(
            [
                "Subtitle post-editing reflow mode:",
                "- You are repairing readability and timing failures in already translated subtitles.",
                "- Do not retranslate the whole scene or globally polish unaffected subtitles.",
                "- Rewrite only the target-language subtitles in REFLOW_WINDOWS.",
                "- Use CONTEXT_BEFORE and CONTEXT_AFTER only to understand tone, references, pronouns, terms, and jokes.",
                "- Improve readability by shortening, merging adjacent subtitles, and making phrasing natural.",
                "- Preserve meaning, tone, names, jokes, profanity, and key facts.",
                "- Respect locked glossary and confirmed memory if provided.",
                "- Do not invent content and do not translate context lines.",
                "- Return only a JSON object with this shape:",
                '{"windows":[{"window_id":1,"replacements":[{"source_ids":[1,2],"text_tgt":"...","reason":"..."}]}]}',
                "- For single-window compatibility, this shape is also accepted:",
                '{"replacements":[{"source_ids":[1,2],"text_tgt":"...","reason":"..."}]}',
                "- source_ids must contain ids from the matching REFLOW_WINDOWS window only.",
                "- Only merge adjacent ids when needed. Do not drop content unless explicitly allowed.",
                "- Do not include Markdown, commentary, or extra text outside JSON.",
                f"Target language: {req.target_lang}.",
            ]
        )
        if req.style_prompt:
            parts.append("Style instructions:\n" + req.style_prompt.strip())
        if req.memory_prompt:
            parts.append(req.memory_prompt.strip())
        if req.repair_reason:
            parts.append("Quality problems to fix:\n" + req.repair_reason.strip())
        parts.extend(
            [
                _section("CONTEXT_BEFORE", req.context_before),
                _section("REFLOW_WINDOWS", req.lines),
                _section("CONTEXT_AFTER", req.context_after),
            ]
        )
        return "\n\n".join(parts)
    parts.extend(
        [
            FIXED_TRANSLATION_CONSTRAINTS,
            f"Translate from {req.source_lang} to {req.target_lang}.",
        ]
    )
    if req.style_prompt:
        parts.append("User style preferences:\n" + req.style_prompt.strip())
    if req.memory_prompt:
        parts.append(req.memory_prompt.strip())
    if include_asr_uncertainty_hints and (asr_uncertainty := _asr_uncertainty_section(req.asr_uncertain_ids)):
        parts.append(asr_uncertainty)
    if req.prompt_mode == "repair":
        parts.append(
            "Repair mode:\n"
            "- Return only a corrected translation for the single requested bad row.\n"
            "- Keep the same id.\n"
            f"- Failure reason: {req.repair_reason or 'row validation failed'}.\n"
            f"- Current bad translation: {req.bad_translation or '(none)'}."
        )
    parts.extend(
        [
            _section("CONTEXT_BEFORE", req.context_before),
            _section("TRANSLATE_ONLY", req.lines),
            _section("CONTEXT_AFTER", req.context_after),
        ]
    )
    return "\n\n".join(parts)


def classify_error(exc: Exception) -> str:
    text = str(exc).lower()
    if isinstance(exc, ProviderTransportError):
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
        code = exc.response.status_code
        if code in {401, 403}:
            return "auth_error"
        if code in {429}:
            return "rate_limit"
        if code == 408:
            return "provider_timeout"
        if code == 502:
            return "bad_gateway"
        if code == 503:
            return "service_unavailable"
        if code == 504:
            return "gateway_timeout"
        if 500 <= code <= 599:
            return "provider_server_error"
        return "bad_schema"
    if isinstance(exc, httpx.TransportError):
        return "network_error"
    if isinstance(exc, HTTPError):
        if exc.code in {401, 403}:
            return "auth_error"
        if exc.code in {429}:
            return "rate_limit"
        if exc.code == 408:
            return "provider_timeout"
        if exc.code == 502:
            return "bad_gateway"
        if exc.code == 503:
            return "service_unavailable"
        if exc.code == 504:
            return "gateway_timeout"
        if 500 <= exc.code <= 599:
            return "provider_server_error"
        return "bad_schema"
    if isinstance(exc, URLError):
        return "timeout" if "timed out" in text else "network_error"
    if "timed out" in text:
        return "timeout"
    if "mismatch" in text:
        return "mismatch_lines"
    return "unknown_error"


def _request_json(
    url: str,
    payload: dict | None,
    headers: dict[str, str],
    timeout: int,
    method: str = "POST",
) -> dict:
    request_headers = merge_default_headers(headers, **DEFAULT_JSON_HEADERS)
    if payload is not None:
        request_headers = merge_default_headers(request_headers, **{"Content-Type": "application/json"})
    with httpx.Client(timeout=float(timeout), http2=_http2_enabled(True)) as client:
        response = client.request(
            method=method,
            url=url,
            json=payload,
            headers=request_headers,
        )
        if response.status_code >= 400:
            response.raise_for_status()
        return response.json()


def _client_key(config: ProviderConfig) -> tuple:
    limits = config.limits
    return (
        config.name,
        config.base_url,
        _http2_enabled(limits.http2),
        limits.connect_timeout_seconds,
        limits.read_timeout_seconds,
        limits.write_timeout_seconds,
        limits.pool_timeout_seconds,
        limits.max_connections,
        limits.max_keepalive_connections,
    )


def _provider_timeout(config: ProviderConfig) -> httpx.Timeout:
    limits = config.limits
    return httpx.Timeout(
        connect=float(limits.connect_timeout_seconds),
        read=float(limits.read_timeout_seconds),
        write=float(limits.write_timeout_seconds),
        pool=float(limits.pool_timeout_seconds),
    )


def _provider_limits(config: ProviderConfig) -> httpx.Limits:
    limits = config.limits
    return httpx.Limits(
        max_connections=max(1, int(limits.max_connections)),
        max_keepalive_connections=max(0, int(limits.max_keepalive_connections)),
    )


def _http2_enabled(requested: bool) -> bool:
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


def _get_provider_client(config: ProviderConfig) -> httpx.Client:
    key = _client_key(config)
    client = _CLIENTS.get(key)
    if client is None or client.is_closed:
        client = httpx.Client(
            timeout=_provider_timeout(config),
            limits=_provider_limits(config),
            http2=_http2_enabled(config.limits.http2),
        )
        _CLIENTS[key] = client
    return client


def _raise_for_status(response: httpx.Response) -> None:
    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        error_type = classify_error(exc)
        raise ProviderTransportError(
            error_type,
            f"provider upstream returned HTTP {response.status_code}: {response.text[:500]}",
            status_code=response.status_code,
        ) from exc


def _transport_meta(response: httpx.Response, *, streaming: bool, stream_meta: dict[str, Any] | None = None) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "transport": "httpx",
        "http_version": response.extensions.get("http_version", b""),
        "streaming": streaming,
    }
    if isinstance(meta["http_version"], bytes):
        meta["http_version"] = meta["http_version"].decode("ascii", errors="ignore")
    if stream_meta:
        meta.update(stream_meta)
    return meta


def _response_json(data: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(data.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ProviderTransportError("bad_schema", f"bad_schema: invalid JSON response: {exc}") from exc
    if not isinstance(payload, dict):
        raise ProviderTransportError("bad_schema", "bad_schema: provider response must be a JSON object")
    return payload


def _provider_request_json(
    config: ProviderConfig,
    url: str,
    payload: dict,
    headers: dict[str, str],
    method: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    request_headers = merge_default_headers(headers, **DEFAULT_JSON_HEADERS, **{"Content-Type": "application/json"})
    response = _get_provider_client(config).request(method=method, url=url, json=payload, headers=request_headers)
    _raise_for_status(response)
    return _response_json(response.content), _transport_meta(response, streaming=False)


def _extract_sse_json(line: str) -> dict[str, Any] | None:
    stripped = line.strip()
    if not stripped.startswith("data:"):
        return None
    data = stripped[5:].strip()
    if not data or data == "[DONE]":
        return None
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _stream_text_parts(event: dict[str, Any], compat_mode: str) -> tuple[list[str], str | None]:
    event_type = str(event.get("type") or "")
    delta_parts: list[str] = []
    final_text: str | None = None
    if compat_mode == "openai_responses":
        if event_type in {"response.output_text.delta", "output_text.delta"} and isinstance(event.get("delta"), str):
            return [event["delta"]], None
        if event_type in {"response.output_text.done", "output_text.done"} and isinstance(event.get("text"), str):
            return [], event["text"]
        if event_type in {"response.completed", "response.done"}:
            response = event.get("response")
            if isinstance(response, dict):
                extracted = _extract_text_by_paths(response, ["output_text", "output[].content[].text"])
                if extracted:
                    return [], extracted
            if isinstance(event.get("output_text"), str):
                return [], event["output_text"]
            return [], None
        if event_type:
            return [], None
    if "choices" in event and isinstance(event["choices"], list):
        for choice in event["choices"]:
            if not isinstance(choice, dict):
                continue
            delta = choice.get("delta")
            if isinstance(delta, dict) and isinstance(delta.get("content"), str):
                delta_parts.append(delta["content"])
            text = choice.get("text")
            if isinstance(text, str):
                delta_parts.append(text)
            message = choice.get("message")
            if isinstance(message, dict) and isinstance(message.get("content"), str):
                final_text = message["content"]
    if isinstance(event.get("delta"), str):
        delta_parts.append(event["delta"])
    if not delta_parts and isinstance(event.get("text"), str):
        final_text = event["text"]
    if not delta_parts and isinstance(event.get("output_text"), str):
        final_text = event["output_text"]
    return delta_parts, final_text


def _stream_response_payload(
    config: ProviderConfig,
    url: str,
    payload: dict,
    headers: dict[str, str],
    method: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    request_headers = merge_default_headers(headers, **DEFAULT_JSON_HEADERS, **{"Content-Type": "application/json"})
    payload = dict(payload)
    payload["stream"] = True
    request_started = time.time()
    first_byte_at: float | None = None
    last_chunk_at: float | None = None
    bytes_received = 0
    text_parts: list[str] = []
    final_text: str | None = None
    usage: dict[str, Any] = {}
    final_payload: dict[str, Any] | None = None
    with _get_provider_client(config).stream(method=method, url=url, json=payload, headers=request_headers) as response:
        _raise_for_status(response)
        for line in response.iter_lines():
            if not line:
                continue
            now = time.time()
            first_byte_at = first_byte_at or now
            last_chunk_at = now
            bytes_received += len(line.encode("utf-8"))
            event = _extract_sse_json(line)
            if event is None:
                continue
            final_payload = event
            if isinstance(event.get("usage"), dict):
                usage = event["usage"]
            deltas, event_final_text = _stream_text_parts(event, config.compat_mode)
            text_parts.extend(deltas)
            if event_final_text:
                final_text = event_final_text
        stream_meta = {
            "request_started_at": request_started,
            "first_byte_at": first_byte_at,
            "last_chunk_at": last_chunk_at,
            "bytes_received": bytes_received,
            "elapsed_ms": int((time.time() - request_started) * 1000),
        }
        text = final_text if final_text is not None else "".join(text_parts)
        if config.compat_mode == "openai_chat":
            data = {"choices": [{"message": {"content": text}}]}
        elif config.compat_mode == "openai_responses":
            data = {"output_text": text}
        else:
            data = final_payload or {"text": text}
        if usage:
            data["usage"] = usage
        return data, _transport_meta(response, streaming=True, stream_meta=stream_meta)


def _can_stream(config: ProviderConfig) -> bool:
    return bool(config.limits.streaming_enabled) and config.compat_mode in {"openai_chat", "openai_responses"}


def _post_json(url: str, payload: dict, headers: dict[str, str], timeout: int, method: str = "POST") -> dict:
    return _request_json(url, payload, headers, timeout, method)


def _bool_string(value: bool) -> str:
    return "true" if value else "false"


def _stringify_query_value(value: object) -> str:
    if isinstance(value, bool):
        return _bool_string(value)
    return str(value)


def _append_query_params(url: str, params: dict[str, object]) -> str:
    if not params:
        return url
    parsed = urllib.parse.urlsplit(url)
    query_items = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    for key, value in params.items():
        if value is None:
            continue
        if isinstance(value, list):
            query_items.extend((str(key), _stringify_query_value(item)) for item in value if item is not None)
        else:
            query_items.append((str(key), _stringify_query_value(value)))
    return urllib.parse.urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path,
            urllib.parse.urlencode(query_items),
            parsed.fragment,
        )
    )


def _get_path_value(data: object, path: str) -> list[object]:
    def walk(nodes: list[object], token: str) -> list[object]:
        out: list[object] = []
        is_array = token.endswith("[]")
        key_token = token[:-2] if is_array else token
        idx = None
        if "[" in key_token and key_token.endswith("]"):
            k, i = key_token[:-1].split("[", 1)
            key_token, idx = k, int(i)
        for node in nodes:
            cur = node
            if key_token:
                if isinstance(cur, dict) and key_token in cur:
                    cur = cur[key_token]
                else:
                    continue
            if idx is not None:
                if isinstance(cur, list) and 0 <= idx < len(cur):
                    cur = cur[idx]
                else:
                    continue
            if is_array:
                if isinstance(cur, list):
                    out.extend(cur)
                else:
                    continue
            else:
                out.append(cur)
        return out

    tokens = [t for t in path.split(".") if t]
    nodes: list[object] = [data]
    for token in tokens:
        nodes = walk(nodes, token)
        if not nodes:
            return []
    return nodes


def _extract_text_by_paths(data: dict, paths: list[str]) -> str:
    for path in paths:
        vals = _get_path_value(data, path)
        if not vals:
            continue
        chunks = [str(v) for v in vals if isinstance(v, (str, int, float))]
        if chunks:
            return "\n".join(chunks)
        dict_chunks = [
            str(v.get("id") or v.get("name"))
            for v in vals
            if isinstance(v, dict) and (v.get("id") or v.get("name"))
        ]
        if dict_chunks:
            return "\n".join(dict_chunks)
    return ""


def _template_context(
    req: NormalizedRequest,
    *,
    prompt: str,
    system_prompt: str,
) -> dict[str, object]:
    return {
        "model": req.model,
        "prompt": prompt,
        "system_prompt": system_prompt,
        "temperature": req.temperature,
        "source_lang": req.source_lang,
        "target_lang": req.target_lang,
        "lines": req.lines,
        "lines_text": "\n".join(req.lines),
        "context_before": req.context_before,
        "context_before_text": "\n".join(req.context_before),
        "context_after": req.context_after,
        "context_after_text": "\n".join(req.context_after),
        "asr_uncertain_ids": req.asr_uncertain_ids,
        "asr_uncertain_ids_text": "\n".join(str(item) for item in req.asr_uncertain_ids),
        "style_prompt": req.style_prompt,
        "memory_prompt": req.memory_prompt,
        "prompt_mode": req.prompt_mode,
        "repair_reason": req.repair_reason,
        "bad_translation": req.bad_translation,
    }


def _render_template_string(value: str, context: dict[str, object]) -> object:
    exact = re.fullmatch(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}", value)
    if exact:
        return context.get(exact.group(1), "")

    def replace(match: re.Match[str]) -> str:
        replacement = context.get(match.group(1), "")
        if isinstance(replacement, (list, dict)):
            return json.dumps(replacement, ensure_ascii=False)
        return str(replacement)

    return re.sub(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}", replace, value)


def _render_template_value(value: object, context: dict[str, object]) -> object:
    if isinstance(value, str):
        return _render_template_string(value, context)
    if isinstance(value, list):
        return [_render_template_value(item, context) for item in value]
    if isinstance(value, dict):
        return {str(key): _render_template_value(item, context) for key, item in value.items()}
    return value


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged: dict[str, Any] = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def _remove_payload_path(payload: dict[str, Any], path: str) -> None:
    tokens = [token for token in str(path).split(".") if token]
    if not tokens:
        return
    current: Any = payload
    for token in tokens[:-1]:
        if isinstance(current, dict):
            current = current.get(token)
        elif isinstance(current, list) and token.isdigit():
            idx = int(token)
            current = current[idx] if 0 <= idx < len(current) else None
        else:
            return
        if current is None:
            return
    last = tokens[-1]
    if isinstance(current, dict):
        current.pop(last, None)
    elif isinstance(current, list) and last.isdigit():
        idx = int(last)
        if 0 <= idx < len(current):
            current.pop(idx)


def _apply_request_mapping(
    payload: dict[str, Any],
    config: ProviderConfig,
    context: dict[str, object],
) -> dict[str, Any]:
    mapping = config.mapping.request
    overrides = mapping.get("body_overrides")
    if isinstance(overrides, dict):
        payload = _deep_merge(payload, _render_template_value(overrides, context))
    for raw_path in mapping.get("body_remove_paths", []) or []:
        _remove_payload_path(payload, str(raw_path))
    return payload


def _query_params_for_config(config: ProviderConfig, model: str) -> dict[str, object]:
    raw = config.mapping.request.get("query_params", {})
    if not isinstance(raw, dict):
        return {}
    return _render_template_value(raw, {"model": model})


def response_shape_summary(value: object, *, depth: int = 4, max_keys: int = 24) -> object:
    if depth <= 0:
        return type(value).__name__
    if isinstance(value, dict):
        out: dict[str, object] = {}
        for idx, (key, item) in enumerate(value.items()):
            if idx >= max_keys:
                out["..."] = f"{len(value) - max_keys} more keys"
                break
            out[str(key)] = response_shape_summary(item, depth=depth - 1, max_keys=max_keys)
        return out
    if isinstance(value, list):
        if not value:
            return []
        return [response_shape_summary(value[0], depth=depth - 1, max_keys=max_keys)]
    return type(value).__name__


def _build_url_and_headers(config: ProviderConfig, api_key: str, model: str) -> tuple[str, dict[str, str]]:
    return _build_url_and_headers_for_path(config, api_key, model, config.endpoint.path_template)


def _build_url_and_headers_for_path(
    config: ProviderConfig,
    api_key: str,
    model: str,
    path_template: str,
) -> tuple[str, dict[str, str]]:
    raw_path = path_template.format(model=model)
    if not raw_path.startswith("/"):
        raw_path = f"/{raw_path}"
    parsed_base = urllib.parse.urlsplit(config.base_url)
    base_path = parsed_base.path or ""
    endpoint_path = raw_path
    if base_path and endpoint_path.startswith(f"{base_path}/"):
        endpoint_path = endpoint_path[len(base_path) :]
    elif base_path and endpoint_path == base_path:
        endpoint_path = "/"
    combined_path = posixpath.normpath(f"{base_path.rstrip('/')}/{endpoint_path.lstrip('/')}")
    if not combined_path.startswith("/"):
        combined_path = f"/{combined_path}"
    if endpoint_path.endswith("/") and not combined_path.endswith("/"):
        combined_path = f"{combined_path}/"
    url = urllib.parse.urlunsplit(
        (
            parsed_base.scheme,
            parsed_base.netloc,
            combined_path,
            parsed_base.query,
            parsed_base.fragment,
        )
    )
    url = _append_query_params(url, _query_params_for_config(config, model))
    headers: dict[str, str] = {}
    auth = config.auth
    if auth.type == "bearer":
        headers[auth.header_name] = f"{auth.prefix}{api_key}"
    elif auth.type == "header":
        headers[auth.header_name] = f"{auth.prefix}{api_key}"
    elif auth.type == "query":
        sep = "&" if "?" in url else "?"
        q_name = urllib.parse.quote_plus(auth.query_name)
        q_val = urllib.parse.quote_plus(f"{auth.prefix}{api_key}")
        url = f"{url}{sep}{q_name}={q_val}"
    else:
        raise RuntimeError(f"Unsupported auth.type: {auth.type}")
    return url, headers


def _build_payload(config: ProviderConfig, req: NormalizedRequest) -> dict:
    style = config.mapping.request.get("style", config.compat_mode)
    prompt = _translation_prompt(
        req,
        include_system_constraints=not config.capabilities.supports_system_prompt,
        include_asr_uncertainty_hints=req.include_asr_uncertainty_hints,
    )
    system_prompt = req.system_prompt or TRANSLATION_SYSTEM_PROMPT
    context = _template_context(req, prompt=prompt, system_prompt=system_prompt)
    if style == "openai_chat":
        messages = []
        if config.capabilities.supports_system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": req.model,
            "messages": messages,
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        return _apply_request_mapping(payload, config, context)
    if style == "openai_responses":
        input_items: list[dict[str, str]] = []
        if config.capabilities.supports_system_prompt:
            input_items.append({"role": "system", "content": system_prompt})
        input_items.append({"role": "user", "content": prompt})
        payload = {
            "model": req.model,
            "input": input_items,
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        return _apply_request_mapping(payload, config, context)
    if style == "openai_completions":
        payload = {
            "model": req.model,
            "prompt": f"{system_prompt}\n\n{prompt}",
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        max_tokens = config.mapping.request.get("max_tokens")
        if max_tokens is not None:
            payload["max_tokens"] = int(max_tokens)
        return _apply_request_mapping(payload, config, context)
    if style == "anthropic_messages":
        payload = {
            "model": req.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": int(config.mapping.request.get("max_tokens", 4096)),
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        if config.capabilities.supports_system_prompt:
            payload["system"] = system_prompt
        return _apply_request_mapping(payload, config, context)
    if style == "gemini_generate_content":
        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
        }
        if config.capabilities.supports_temperature:
            payload["generationConfig"] = {"temperature": req.temperature}
        return _apply_request_mapping(payload, config, context)
    if style == "custom_json":
        template = config.mapping.request.get("body_template")
        if not isinstance(template, dict):
            raise RuntimeError("custom_json requires request_mapping.body_template object")
        rendered = _render_template_value(template, context)
        if not isinstance(rendered, dict):
            raise RuntimeError("custom_json body_template must render to a JSON object")
        return _apply_request_mapping(rendered, config, context)
    raise RuntimeError(f"Unsupported request style: {style}")


@dataclass
class ConfigurableProtocolClient(ProviderClient):
    config: ProviderConfig
    timeout: int

    def translate_request(self, req: NormalizedRequest) -> NormalizedResponse:
        if len(req.lines) > self.config.capabilities.max_batch_lines:
            raise RuntimeError(
                f"batch too large: {len(req.lines)} > {self.config.capabilities.max_batch_lines}"
            )
        credential = resolve_provider_credential(self.config, root_dir=self.config.credential_root_dir)
        if not credential.found:
            raise RuntimeError(f"Missing credential: {credential.credential_id or self.config.env_key}")
        payload = _build_payload(self.config, req)
        url, headers = _build_url_and_headers(self.config, credential.key, req.model)
        headers.update(self.config.extra_headers)
        if self.config.compat_mode == "anthropic_messages":
            headers.setdefault("anthropic-version", "2023-06-01")
        if _can_stream(self.config):
            data, transport_meta = _stream_response_payload(
                self.config,
                url,
                payload,
                headers,
                method=self.config.endpoint.method,
            )
        else:
            data, transport_meta = _provider_request_json(
                self.config,
                url,
                payload,
                headers,
                method=self.config.endpoint.method,
            )
        text_paths = self.config.mapping.response.get("text_paths", [])
        text = _extract_text_by_paths(data, text_paths)
        if not text:
            raise RuntimeError("bad_schema: no text extracted from response mapping")
        normalized = NormalizedResponse(
            numbered_lines=_extract_numbered_lines(text),
            raw_text=text,
            usage=(data.get("usage") if isinstance(data.get("usage"), dict) else {}),
            provider_meta={
                "compat_mode": self.config.compat_mode,
                "base_url": self.config.base_url,
                **transport_meta,
            },
        )
        return normalized


def build_provider_client(config: ProviderConfig) -> ProviderClient:
    if config.compat_mode not in {
        "openai_chat",
        "openai_responses",
        "openai_completions",
        "anthropic_messages",
        "gemini_generate_content",
        "custom_json",
    }:
        raise ValueError(f"Unsupported compat_mode: {config.compat_mode}")
    return ConfigurableProtocolClient(config=config, timeout=config.limits.timeout_seconds)
