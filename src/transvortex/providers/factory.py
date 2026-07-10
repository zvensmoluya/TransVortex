from __future__ import annotations

import json
import re
import time
import urllib.parse
import posixpath
from dataclasses import dataclass
from typing import Any

import httpx

from ..app.models import NormalizedRequest, NormalizedResponse, ProviderConfig
from ..app.credentials import resolve_provider_credential
from ..http import (
    DEFAULT_JSON_HEADERS,
    HttpTransportError,
    build_http_limits,
    build_http_timeout,
    classify_http_error,
    get_shared_httpx_client,
    merge_default_headers,
    raise_for_status,
    request_json_with_retry,
    transport_meta,
)
from ..prompts import FALLBACK_TRANSLATION_SYSTEM_PROMPT
from .base import ProviderClient


ProviderTransportError = HttpTransportError


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


TRANSLATION_OUTPUT_REMINDER = (
    "Output reminder:\n"
    "- Translate only TRANSLATE_ONLY.\n"
    "- Return exactly one numbered translated line for each requested [id], preferably in the same order.\n"
    "- Do not output context lines, Markdown, explanations, summaries, or notes."
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
        if req.memory_prompt:
            parts.append(req.memory_prompt.strip())
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
            TRANSLATION_OUTPUT_REMINDER,
            f"Translate from {req.source_lang} to {req.target_lang}.",
        ]
    )
    if req.style_prompt:
        parts.append("User style preferences:\n" + req.style_prompt.strip())
    if req.memory_prompt:
        parts.append(req.memory_prompt.strip())
    if include_asr_uncertainty_hints and (asr_uncertainty := _asr_uncertainty_section(req.asr_uncertain_ids)):
        parts.append(asr_uncertainty)
    if req.adaptive_context_hint:
        parts.append("Adaptive capacity retry context:\n" + req.adaptive_context_hint.strip())
    if req.protocol_recovery_hint:
        parts.append("Protocol recovery retry:\n" + req.protocol_recovery_hint.strip())
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
    return classify_http_error(exc)


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
    data, _meta = request_json_with_retry(
        method,
        url,
        json_payload=payload,
        headers=request_headers,
        timeout=float(timeout),
        http2=True,
        retry=1,
        context="provider upstream",
    )
    return data


def _client_key(config: ProviderConfig) -> tuple:
    limits = config.limits
    return (
        config.name,
        config.base_url,
        limits.http2,
        limits.connect_timeout_seconds,
        limits.read_timeout_seconds,
        limits.write_timeout_seconds,
        limits.pool_timeout_seconds,
        limits.max_connections,
        limits.max_keepalive_connections,
    )


def _provider_timeout(config: ProviderConfig) -> httpx.Timeout:
    limits = config.limits
    return build_http_timeout(
        connect=float(limits.connect_timeout_seconds),
        read=float(limits.read_timeout_seconds),
        write=float(limits.write_timeout_seconds),
        pool=float(limits.pool_timeout_seconds),
    )


def _provider_limits(config: ProviderConfig) -> httpx.Limits:
    limits = config.limits
    return build_http_limits(
        max_connections=max(1, int(limits.max_connections)),
        max_keepalive_connections=max(0, int(limits.max_keepalive_connections)),
    )


def _get_provider_client(config: ProviderConfig) -> httpx.Client:
    return get_shared_httpx_client(
        _client_key(config),
        timeout=_provider_timeout(config),
        limits=_provider_limits(config),
        http2=config.limits.http2,
    )


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
    raise_for_status(response, context="provider upstream")
    return _response_json(response.content), transport_meta(
        response,
        streaming=False,
        http2_requested=config.limits.http2,
    )


def _extract_sse_json(line: str) -> dict[str, Any] | None:
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.startswith("data:"):
        stripped = stripped[5:].strip()
        if not stripped or stripped == "[DONE]":
            return None
    elif stripped.startswith("event:") or stripped.startswith(":"):
        return None
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _stream_text_parts(event: dict[str, Any], compat_mode: str) -> tuple[list[str], str | None]:
    if compat_mode in {"gemini_generate_content", "vertex_express"}:
        delta_parts: list[str] = []
        for piece in _get_path_value(event, "candidates[0].content.parts[].text"):
            if isinstance(piece, (str, int, float)):
                delta_parts.append(str(piece))
        if delta_parts:
            return delta_parts, None
        if isinstance(event.get("text"), str):
            return [], event["text"]
        if isinstance(event.get("output_text"), str):
            return [], event["output_text"]
        return [], None
    event_type = str(event.get("type") or "")
    delta_parts: list[str] = []
    final_text: str | None = None
    if compat_mode == "openai_responses":
        if event_type in {"response.output_text.delta", "output_text.delta"} and isinstance(event.get("delta"), str):
            return [event["delta"]], None
        if event_type in {"response.output_text.done", "output_text.done"} and isinstance(event.get("text"), str):
            return [], event["text"]
        if event_type in {"response.completed", "response.done", "response.incomplete", "response.failed"}:
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


def _provider_response_metadata(payload: dict[str, Any], compat_mode: str) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    response = payload.get("response") if isinstance(payload.get("response"), dict) else payload
    if compat_mode == "openai_responses":
        status = response.get("status")
        if isinstance(status, str) and status:
            meta["response_status"] = status
        incomplete_details = response.get("incomplete_details")
        if isinstance(incomplete_details, dict) and incomplete_details:
            meta["incomplete_details"] = dict(incomplete_details)
    choices = payload.get("choices")
    if isinstance(choices, list) and choices and isinstance(choices[0], dict):
        finish_reason = choices[0].get("finish_reason")
        if isinstance(finish_reason, str) and finish_reason:
            meta["finish_reason"] = finish_reason
    candidates = payload.get("candidates")
    if isinstance(candidates, list) and candidates and isinstance(candidates[0], dict):
        finish_reason = candidates[0].get("finishReason")
        if isinstance(finish_reason, str) and finish_reason:
            meta["finish_reason"] = finish_reason
    return meta


def _provider_response_usage(payload: dict[str, Any]) -> dict[str, Any]:
    candidates = [payload]
    if isinstance(payload.get("response"), dict):
        candidates.insert(0, payload["response"])
    for candidate in candidates:
        usage = candidate.get("usage")
        if not isinstance(usage, dict):
            usage = candidate.get("usageMetadata")
        if isinstance(usage, dict):
            return usage
    return {}


def _stream_response_payload(
    config: ProviderConfig,
    url: str,
    payload: dict,
    headers: dict[str, str],
    method: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    request_headers = merge_default_headers(headers, **DEFAULT_JSON_HEADERS, **{"Content-Type": "application/json"})
    payload = dict(payload)
    stream_url = url
    if config.compat_mode in {"openai_chat", "openai_responses"}:
        payload["stream"] = True
    elif config.compat_mode in {"gemini_generate_content", "vertex_express"}:
        parsed = urllib.parse.urlsplit(url)
        stream_path = parsed.path
        if stream_path.endswith(":generateContent"):
            stream_path = f"{stream_path[:-len(':generateContent')]}:streamGenerateContent"
        elif stream_path.endswith("generateContent"):
            stream_path = f"{stream_path[:-len('generateContent')]}streamGenerateContent"
        elif ":streamGenerateContent" not in stream_path:
            stream_path = f"{stream_path.rstrip('/')}:streamGenerateContent"
        stream_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, stream_path, parsed.query, parsed.fragment))
    request_started = time.time()
    first_byte_at: float | None = None
    last_chunk_at: float | None = None
    bytes_received = 0
    text_parts: list[str] = []
    final_text: str | None = None
    usage: dict[str, Any] = {}
    response_meta: dict[str, Any] = {}
    final_payload: dict[str, Any] | None = None
    raw_lines: list[str] = []
    with _get_provider_client(config).stream(method=method, url=stream_url, json=payload, headers=request_headers) as response:
        raise_for_status(response, context="provider upstream")
        for line in response.iter_lines():
            if not line:
                continue
            raw_lines.append(line)
            now = time.time()
            first_byte_at = first_byte_at or now
            last_chunk_at = now
            bytes_received += len(line.encode("utf-8"))
            event = _extract_sse_json(line)
            if event is None:
                continue
            final_payload = event
            usage_payload = _provider_response_usage(event)
            if usage_payload:
                usage = usage_payload
            response_meta.update(_provider_response_metadata(event, config.compat_mode))
            deltas, event_final_text = _stream_text_parts(event, config.compat_mode)
            text_parts.extend(deltas)
            if event_final_text:
                final_text = event_final_text
        if config.compat_mode in {"gemini_generate_content", "vertex_express"} and not text_parts and final_text is None:
            raw_text = "\n".join(raw_lines).strip()
            if raw_text:
                try:
                    parsed = json.loads(raw_text)
                except json.JSONDecodeError:
                    parsed = None
                events = parsed if isinstance(parsed, list) else [parsed] if isinstance(parsed, dict) else []
                for item in events:
                    if not isinstance(item, dict):
                        continue
                    final_payload = item
                    usage_payload = _provider_response_usage(item)
                    if usage_payload:
                        usage = usage_payload
                    response_meta.update(_provider_response_metadata(item, config.compat_mode))
                    deltas, event_final_text = _stream_text_parts(item, config.compat_mode)
                    text_parts.extend(deltas)
                    if event_final_text:
                        final_text = event_final_text
        stream_meta = {
            "request_started_at": request_started,
            "first_byte_at": first_byte_at,
            "last_chunk_at": last_chunk_at,
            "bytes_received": bytes_received,
            "elapsed_ms": int((time.time() - request_started) * 1000),
            **response_meta,
        }
        text = final_text if final_text is not None else "".join(text_parts)
        if config.compat_mode == "openai_chat":
            data = {"choices": [{"message": {"content": text}}]}
        elif config.compat_mode == "openai_responses":
            data = {"output_text": text}
        elif config.compat_mode in {"gemini_generate_content", "vertex_express"}:
            data = {"candidates": [{"content": {"parts": [{"text": text}]}}]}
        else:
            data = final_payload or {"text": text}
        if usage:
            data["usage"] = usage
        return data, transport_meta(
            response,
            streaming=True,
            http2_requested=config.limits.http2,
            stream_meta=stream_meta,
        )


def _can_stream(config: ProviderConfig) -> bool:
    return bool(config.limits.streaming_enabled) and config.compat_mode in {
        "openai_chat",
        "openai_responses",
        "gemini_generate_content",
        "vertex_express",
    }


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


def _has_nested_payload_value(payload: dict[str, Any], path: list[str]) -> bool:
    current: Any = payload
    for token in path:
        if not isinstance(current, dict) or token not in current:
            return False
        current = current[token]
    return True


def _set_nested_payload_value(payload: dict[str, Any], path: list[str], value: int) -> None:
    current: dict[str, Any] = payload
    for token in path[:-1]:
        existing = current.get(token)
        if not isinstance(existing, dict):
            existing = {}
            current[token] = existing
        current = existing
    current[path[-1]] = value


def _output_token_param_path(config: ProviderConfig, style: str) -> list[str]:
    explicit_param = str(config.capabilities.output_token_param or "").strip()
    if explicit_param:
        return [token for token in explicit_param.split(".") if token]
    if style == "openai_responses":
        return ["max_output_tokens"]
    if style in {"openai_chat", "openai_completions", "anthropic_messages"}:
        return ["max_tokens"]
    if style == "gemini_generate_content":
        return ["generationConfig", "maxOutputTokens"]
    return []


def _request_mapping_value_for_path(mapping: dict[str, Any], path: list[str]) -> Any:
    if not path:
        return None
    if len(path) == 1:
        return mapping.get(path[0])
    current: Any = mapping
    for token in path:
        if not isinstance(current, dict) or token not in current:
            return None
        current = current[token]
    return current


def _apply_request_mapping_output_tokens(payload: dict[str, Any], config: ProviderConfig, style: str) -> dict[str, Any]:
    path = _output_token_param_path(config, style)
    explicit_value = _request_mapping_value_for_path(config.mapping.request, path)
    if explicit_value is None:
        return payload
    _set_nested_payload_value(payload, path, int(explicit_value))
    return payload


def _apply_capability_output_tokens(payload: dict[str, Any], config: ProviderConfig, style: str) -> dict[str, Any]:
    max_output_tokens = int(config.capabilities.max_output_tokens or 0)
    if max_output_tokens <= 0:
        return payload
    path = _output_token_param_path(config, style)
    if not path or _has_nested_payload_value(payload, path):
        return payload
    _set_nested_payload_value(payload, path, max_output_tokens)
    return payload


def _query_params_for_config(config: ProviderConfig, model: str) -> dict[str, object]:
    raw = config.mapping.request.get("query_params", {})
    if not isinstance(raw, dict):
        return {}
    return _render_template_value(raw, {"model": model})


_VERTEX_EXPRESS_MODEL_PREFIX = "publishers/google/models/"


def _vertex_express_bare_model(model: str) -> str:
    model = model.strip().lstrip("/")
    if model.startswith(_VERTEX_EXPRESS_MODEL_PREFIX):
        return model[len(_VERTEX_EXPRESS_MODEL_PREFIX) :]
    if model.startswith("models/"):
        return model[len("models/") :]
    return model


def _model_for_path_template(config: ProviderConfig, model: str, path_template: str) -> str:
    if config.compat_mode != "vertex_express":
        return model
    bare_model = _vertex_express_bare_model(model)
    normalized_template = path_template.strip()
    if "{model}" not in normalized_template:
        return bare_model
    if normalized_template.startswith("/publishers/google/models/{model}") or normalized_template.startswith(
        "publishers/google/models/{model}"
    ):
        return bare_model
    if normalized_template.startswith("/{model}") or normalized_template.startswith("{model}"):
        return f"{_VERTEX_EXPRESS_MODEL_PREFIX}{bare_model}"
    return model


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
    raw_path = path_template.format(model=_model_for_path_template(config, model, path_template))
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
        payload = _apply_request_mapping_output_tokens(payload, config, style)
        payload = _apply_capability_output_tokens(payload, config, style)
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
        payload = _apply_request_mapping_output_tokens(payload, config, style)
        payload = _apply_capability_output_tokens(payload, config, style)
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
        payload = _apply_request_mapping_output_tokens(payload, config, style)
        payload = _apply_capability_output_tokens(payload, config, style)
        return _apply_request_mapping(payload, config, context)
    if style == "anthropic_messages":
        payload = {
            "model": req.model,
            "messages": [{"role": "user", "content": prompt}],
        }
        max_tokens = config.mapping.request.get("max_tokens")
        if max_tokens is not None:
            payload["max_tokens"] = int(max_tokens)
        payload = _apply_request_mapping_output_tokens(payload, config, style)
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        if config.capabilities.supports_system_prompt:
            payload["system"] = system_prompt
        payload = _apply_capability_output_tokens(payload, config, style)
        return _apply_request_mapping(payload, config, context)
    if style == "gemini_generate_content":
        content = {"parts": [{"text": prompt}]}
        if config.compat_mode == "vertex_express":
            content["role"] = "user"
        payload = {"contents": [content]}
        if config.capabilities.supports_system_prompt:
            payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}
        if config.capabilities.supports_temperature:
            payload["generationConfig"] = {"temperature": req.temperature}
        payload = _apply_request_mapping_output_tokens(payload, config, style)
        payload = _apply_capability_output_tokens(payload, config, style)
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
                **_provider_response_metadata(data, self.config.compat_mode),
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
        "vertex_express",
        "custom_json",
    }:
        raise ValueError(f"Unsupported compat_mode: {config.compat_mode}")
    return ConfigurableProtocolClient(config=config, timeout=config.limits.timeout_seconds)
