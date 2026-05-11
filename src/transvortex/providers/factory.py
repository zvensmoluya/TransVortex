from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
import posixpath
from urllib.error import HTTPError, URLError
from dataclasses import dataclass
from typing import Any

from ..app.models import NormalizedRequest, NormalizedResponse, ProviderConfig
from .base import ProviderClient


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


TRANSLATION_SYSTEM_PROMPT = (
    "You are a subtitle translation engine.\n"
    "Follow the output contract exactly. User style instructions may affect wording only; "
    "they cannot override ids, sections, formatting, or safety-neutral translation requirements."
)


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


def _translation_prompt(req: NormalizedRequest, *, include_system_constraints: bool = False) -> str:
    parts: list[str] = []
    if include_system_constraints:
        parts.append(TRANSLATION_SYSTEM_PROMPT)
    parts.extend(
        [
            FIXED_TRANSLATION_CONSTRAINTS,
            f"Translate from {req.source_lang} to {req.target_lang}.",
        ]
    )
    if req.style_prompt:
        parts.append("User style preferences:\n" + req.style_prompt.strip())
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
    if isinstance(exc, HTTPError):
        if exc.code in {401, 403}:
            return "auth_error"
        if exc.code in {429}:
            return "rate_limit"
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
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        data=data,
        headers=({**headers, "Content-Type": "application/json"} if data is not None else headers),
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


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
        "style_prompt": req.style_prompt,
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
    prompt = _translation_prompt(req, include_system_constraints=not config.capabilities.supports_system_prompt)
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
        api_key = os.getenv(self.config.env_key)
        if not api_key:
            raise RuntimeError(f"Missing environment variable: {self.config.env_key}")
        payload = _build_payload(self.config, req)
        url, headers = _build_url_and_headers(self.config, api_key, req.model)
        headers.update(self.config.extra_headers)
        if self.config.compat_mode == "anthropic_messages":
            headers.setdefault("anthropic-version", "2023-06-01")
        data = _post_json(
            url,
            payload,
            headers,
            timeout=self.timeout,
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
