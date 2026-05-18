from __future__ import annotations

import json
import re
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest
from ..prompts import FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT
from ..providers import build_provider_client, classify_error
from .schema import MemoryPatch
from .merger import patch_from_payload


MEMORY_PATCH_SYSTEM_PROMPT = FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT


ProgressCallback = Callable[[dict[str, Any]], None]


def _notify_progress(progress_callback: ProgressCallback | None, **payload: Any) -> None:
    if progress_callback is None:
        return
    try:
        progress_callback(payload)
    except Exception:
        pass


def json_from_memory_text(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
        stripped = re.sub(r"\s*```$", "", stripped)
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start < 0 or end <= start:
            raise
        data = json.loads(stripped[start : end + 1])
    if not isinstance(data, dict):
        raise ValueError("memory patch response must be a JSON object")
    return data


def _window_prompt(chunks: list[Chunk], translated_rows: list[dict], source_lang: str, target_lang: str) -> str:
    source_lines: list[str] = []
    for chunk in chunks:
        source_lines.extend(chunk.lines)
    translated_lines: list[str] = []
    for row in translated_rows:
        for item in row.get("rows", []):
            translated_lines.append(f"[{item.get('id')}] {item.get('text_tgt', '')}")
    return (
        f"Source language: {source_lang}\n"
        f"Target language: {target_lang}\n\n"
        "SOURCE SUBTITLES\n"
        + "\n".join(source_lines)
        + "\n\nTRANSLATED SUBTITLES\n"
        + "\n".join(translated_lines)
        + "\n\nReturn JSON exactly in this shape:\n"
        '{"chunk_ids":["..."],"actions":[{"action":"upsert","source":"...","target":"...",'
        '"category":"term","status":"proposed","memory_type":"term","constraint":"hint",'
        '"confidence":0.0,"evidence_ids":[1],"aliases":[],'
        '"alias_details":[{"source":"...","kind":"asr_error"}],'
        '"target_variants":[{"source":"...","target":"...","kind":"nickname"}],'
        '"notes":""}]}\n'
        "When no useful candidate exists, return the same shape with an empty actions array."
    )


def generate_memory_patch(
    config: AppConfig,
    chunks: list[Chunk],
    translated_rows: list[dict],
    *,
    source_lang: str,
    target_lang: str,
    progress_callback: ProgressCallback | None = None,
) -> tuple[MemoryPatch | None, dict[str, Any] | None]:
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    errors: list[dict[str, Any]] = []
    for attempt, route in enumerate(route_candidates, start=1):
        provider = config.providers.get(route.provider)
        if not provider:
            errors.append({"provider": route.provider, "model": route.model, "error_type": "bad_schema", "message": "provider not found"})
            continue
        client = build_provider_client(provider)
        try:
            _notify_progress(
                progress_callback,
                mode="memory_patch",
                chunk_ids=[chunk.chunk_id for chunk in chunks],
                provider=route.provider,
                model=route.model,
                attempt=attempt,
                max_attempts=len(route_candidates),
            )
            req = NormalizedRequest(
                model=route.model,
                lines=[],
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=[],
                context_after=[],
                style_prompt=_window_prompt(chunks, translated_rows, source_lang, target_lang),
                prompt_mode="memory_patch",
                system_prompt=config.pipeline.memory.patch.system_prompt or MEMORY_PATCH_SYSTEM_PROMPT,
            )
            response = client.translate_request(req)
            payload = json_from_memory_text(response.raw_text)
            payload.setdefault("chunk_ids", [chunk.chunk_id for chunk in chunks])
            payload["provider"] = route.provider
            payload["model"] = route.model
            payload["raw_text"] = response.raw_text
            return patch_from_payload(payload), payload
        except Exception as exc:  # pragma: no cover - runtime network branches
            errors.append(
                {
                    "provider": route.provider,
                    "model": route.model,
                    "error_type": classify_error(exc),
                    "message": str(exc),
                }
            )
    return None, {"errors": errors}
