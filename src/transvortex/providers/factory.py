from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass

from ..models import ProviderConfig
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


def _post_json(url: str, payload: dict, headers: dict[str, str], timeout: int) -> dict:
    req = urllib.request.Request(
        url=url,
        data=json.dumps(payload).encode("utf-8"),
        headers={**headers, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


@dataclass
class OpenAICompatibleClient(ProviderClient):
    config: ProviderConfig
    timeout: int

    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        key = os.getenv(self.config.env_key)
        if not key:
            raise RuntimeError(f"Missing environment variable: {self.config.env_key}")
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": "Return only numbered translation lines."},
                {"role": "user", "content": _translation_prompt(lines, source_lang, target_lang)},
            ],
            "temperature": 0.1,
        }
        data = _post_json(
            f"{self.config.base_url}/chat/completions",
            payload,
            {"Authorization": f"Bearer {key}"},
            timeout=self.timeout,
        )
        content = data["choices"][0]["message"]["content"]
        result = _extract_numbered_lines(content)
        if len(result) != len(lines):
            raise RuntimeError("Model output line count mismatch")
        return result


@dataclass
class AnthropicClient(ProviderClient):
    config: ProviderConfig
    timeout: int

    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        key = os.getenv(self.config.env_key)
        if not key:
            raise RuntimeError(f"Missing environment variable: {self.config.env_key}")
        payload = {
            "model": model,
            "max_tokens": 4096,
            "temperature": 0,
            "messages": [{"role": "user", "content": _translation_prompt(lines, source_lang, target_lang)}],
        }
        data = _post_json(
            f"{self.config.base_url}/messages",
            payload,
            {
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            },
            timeout=self.timeout,
        )
        content_parts = data.get("content", [])
        text = "\n".join(part.get("text", "") for part in content_parts if isinstance(part, dict))
        result = _extract_numbered_lines(text)
        if len(result) != len(lines):
            raise RuntimeError("Model output line count mismatch")
        return result


@dataclass
class GeminiCompatibleClient(ProviderClient):
    config: ProviderConfig
    timeout: int

    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        key = os.getenv(self.config.env_key)
        if not key:
            raise RuntimeError(f"Missing environment variable: {self.config.env_key}")
        prompt = _translation_prompt(lines, source_lang, target_lang)
        query_key = urllib.parse.quote_plus(key)
        url = f"{self.config.base_url}/models/{model}:generateContent?key={query_key}"
        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.1},
        }
        data = _post_json(url, payload, {}, timeout=self.timeout)
        candidates = data.get("candidates", [])
        if not candidates:
            raise RuntimeError("Empty Gemini response")
        parts = candidates[0].get("content", {}).get("parts", [])
        text = "\n".join(part.get("text", "") for part in parts if isinstance(part, dict))
        result = _extract_numbered_lines(text)
        if len(result) != len(lines):
            raise RuntimeError("Model output line count mismatch")
        return result


def build_provider_client(config: ProviderConfig) -> ProviderClient:
    if config.api_type in {"openai", "openai-compatible"}:
        return OpenAICompatibleClient(config=config, timeout=config.limits.timeout_seconds)
    if config.api_type == "anthropic":
        return AnthropicClient(config=config, timeout=config.limits.timeout_seconds)
    if config.api_type == "gemini-compatible":
        return GeminiCompatibleClient(config=config, timeout=config.limits.timeout_seconds)
    raise ValueError(f"Unsupported api_type: {config.api_type}")
