from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
from urllib.error import HTTPError, URLError
from dataclasses import dataclass

from ..models import NormalizedRequest, NormalizedResponse, ProviderConfig
from .base import ProviderClient


def _extract_numbered_lines(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if re.match(r"^\[\d+\]\s*", line):
            out.append(line)
    return out


def _translation_prompt(lines: list[str], source_lang: str, target_lang: str) -> str:
    joined = "\n".join(lines)
    return (
        "You are a subtitle translation engine.\n"
        f"Translate from {source_lang} to {target_lang}.\n"
        "Keep numbering exactly unchanged, output only translated lines.\n"
        "Do not add explanations.\n\n"
        f"{joined}"
    )


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


def _post_json(url: str, payload: dict, headers: dict[str, str], timeout: int, method: str = "POST") -> dict:
    req = urllib.request.Request(
        url=url,
        data=json.dumps(payload).encode("utf-8"),
        headers={**headers, "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


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
    return ""


def _build_url_and_headers(config: ProviderConfig, api_key: str, model: str) -> tuple[str, dict[str, str]]:
    path = config.endpoint.path_template.format(model=model)
    if not path.startswith("/"):
        path = f"/{path}"
    url = f"{config.base_url}{path}"
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
    prompt = _translation_prompt(req.lines, req.source_lang, req.target_lang)
    if style == "openai_chat":
        payload = {
            "model": req.model,
            "messages": [
                {"role": "system", "content": req.system_prompt},
                {"role": "user", "content": prompt},
            ],
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        return payload
    if style == "anthropic_messages":
        payload = {
            "model": req.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": int(config.mapping.request.get("max_tokens", 4096)),
        }
        if config.capabilities.supports_temperature:
            payload["temperature"] = req.temperature
        if config.capabilities.supports_system_prompt:
            payload["system"] = req.system_prompt
        return payload
    if style == "gemini_generate_content":
        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
        }
        if config.capabilities.supports_temperature:
            payload["generationConfig"] = {"temperature": req.temperature}
        return payload
    raise RuntimeError(f"Unsupported request style: {style}")


@dataclass
class ConfigurableProtocolClient(ProviderClient):
    config: ProviderConfig
    timeout: int

    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        if len(lines) > self.config.capabilities.max_batch_lines:
            raise RuntimeError(
                f"batch too large: {len(lines)} > {self.config.capabilities.max_batch_lines}"
            )
        api_key = os.getenv(self.config.env_key)
        if not api_key:
            raise RuntimeError(f"Missing environment variable: {self.config.env_key}")
        req = NormalizedRequest(
            model=model,
            lines=lines,
            source_lang=source_lang,
            target_lang=target_lang,
        )
        payload = _build_payload(self.config, req)
        url, headers = _build_url_and_headers(self.config, api_key, model)
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
        if len(normalized.numbered_lines) != len(lines):
            raise RuntimeError("mismatch_lines: model output line count mismatch")
        return normalized.numbered_lines


def build_provider_client(config: ProviderConfig) -> ProviderClient:
    if config.compat_mode not in {
        "openai_chat",
        "anthropic_messages",
        "gemini_generate_content",
    }:
        raise ValueError(f"Unsupported compat_mode: {config.compat_mode}")
    return ConfigurableProtocolClient(config=config, timeout=config.limits.timeout_seconds)
