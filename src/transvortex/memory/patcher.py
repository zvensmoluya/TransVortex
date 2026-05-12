from __future__ import annotations

import json
import re
from typing import Any

from ..app.models import AppConfig, Chunk, NormalizedRequest
from ..providers import build_provider_client, classify_error
from ..providers.factory import TRANSLATION_SYSTEM_PROMPT
from .schema import MemoryPatch
from .merger import patch_from_payload


MEMORY_PATCH_SYSTEM_PROMPT = (
    "You are a translation memory curator for subtitle localization.\n"
    "Your only job is to identify entries worth remembering for consistency across future chunks.\n"
    "You do not translate. You do not explain. You return only a JSON object.\n\n"
    "WHAT TO CAPTURE\n"
    "- Character names and their established translations.\n"
    "- Place names, organization names, titles, and named objects.\n"
    "- Invented, technical, or setting-specific terms with no obvious natural equivalent.\n"
    "- Recurring phrasing where a specific translation choice must stay stable.\n"
    "- Character voice rules, if a character has a distinct register, dialect, catchphrase, or speech pattern.\n\n"
    "WHAT TO IGNORE\n"
    "- Generic words, pronouns, vague references, and deictic phrases such as here, there, upstairs, or downstairs.\n"
    "- Common fillers or ordinary dialogue words such as man, well, ok, yes, no, things, those things, or them.\n"
    "- One-off idioms unless the same expression recurs and its translation choice must remain stable.\n"
    "- Terms already obvious from context with no future consistency risk.\n\n"
    "STATUS RULES\n"
    "- proposed: default for all new candidates.\n"
    "- confirmed: only when the input includes an explicit user glossary marked as confirmed.\n"
    "- locked: only when explicitly instructed by the user.\n"
    "- Never self-promote a proposed entry to confirmed or locked.\n\n"
    "CATEGORY RULES\n"
    "- Use category name for people or character names.\n"
    "- Use category place for locations.\n"
    "- Use category organization for groups, institutions, or companies.\n"
    "- Use category title for works, ranks, formal titles, or named broadcasts.\n"
    "- Use category term for all other useful terminology."
)


def _json_from_text(text: str) -> dict[str, Any]:
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
        '"category":"term","status":"proposed","confidence":0.0,"evidence_ids":[1],"aliases":[],"notes":""}]}\n'
        "When no useful candidate exists, return the same shape with an empty actions array."
    )


def generate_memory_patch(
    config: AppConfig,
    chunks: list[Chunk],
    translated_rows: list[dict],
    *,
    source_lang: str,
    target_lang: str,
) -> tuple[MemoryPatch | None, dict[str, Any] | None]:
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    errors: list[dict[str, Any]] = []
    for route in route_candidates:
        provider = config.providers.get(route.provider)
        if not provider:
            errors.append({"provider": route.provider, "model": route.model, "error_type": "bad_schema", "message": "provider not found"})
            continue
        client = build_provider_client(provider)
        try:
            req = NormalizedRequest(
                model=route.model,
                lines=[],
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=[],
                context_after=[],
                style_prompt=_window_prompt(chunks, translated_rows, source_lang, target_lang),
                prompt_mode="memory_patch",
                system_prompt=MEMORY_PATCH_SYSTEM_PROMPT,
            )
            response = client.translate_request(req)
            payload = _json_from_text(response.raw_text)
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
