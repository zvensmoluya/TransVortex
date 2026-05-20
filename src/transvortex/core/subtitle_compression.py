from __future__ import annotations

import time
from dataclasses import replace
from pathlib import Path
from typing import Any

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment, SubtitleQualityConfig
from ..memory.injector import build_memory_prompt
from ..memory.selector import select_memory_entries
from ..memory.store import MemoryStore
from ..memory.workflow import effective_memory_sources, translates_with_memory
from ..providers import build_provider_client, classify_error
from .subtitle_optimizer import subtitle_cps
from .translation_validation import strip_numbered_text


COMPRESSION_STYLE_PROMPT = (
    "Compress the translated subtitle for readability. Preserve the meaning, tone, names, jokes, profanity, "
    "and key facts. Prefer natural concise subtitles over literal wording. Output only the requested numbered line."
)


def _budget(seg: Segment, config: SubtitleQualityConfig) -> int:
    duration = max(float(seg.end) - float(seg.start), config.min_duration_seconds)
    return max(1, int(duration * max(config.target_cps, 1)))


def _compressed_text_is_valid(original: Segment, text: str, quality: SubtitleQualityConfig, budget: int) -> tuple[bool, str]:
    candidate = replace(original, text_tgt=text)
    original_text = original.text_tgt or original.text_src or ""
    if len(text) >= len(original_text.strip()):
        return False, "compression did not shorten text"
    if len(text) > budget and subtitle_cps(candidate) > quality.hard_max_cps:
        return False, f"compressed text still exceeds budget {budget} and hard cps {quality.hard_max_cps}"
    return True, ""


def _compress_segment(
    *,
    config: AppConfig,
    seg: Segment,
    source_lang: str,
    target_lang: str,
    provider_name: str,
    model: str,
    quality: SubtitleQualityConfig,
    memory_prompt: str = "",
) -> tuple[Segment | None, list[dict[str, Any]]]:
    provider = config.providers[provider_name]
    client = build_provider_client(provider)
    attempts = max(1, config.pipeline.subtitle.compression.max_attempts)
    errors: list[dict[str, Any]] = []
    budget = _budget(seg, quality)
    for attempt in range(attempts):
        try:
            req = NormalizedRequest(
                model=model,
                lines=[f"[{seg.id}] {seg.text_tgt or seg.text_src}"],
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=[f"Source: {seg.text_src}", f"Max target characters: {budget}"],
                context_after=[],
                style_prompt=COMPRESSION_STYLE_PROMPT,
                memory_prompt=memory_prompt,
                prompt_mode="compress",
                repair_reason=f"subtitle cps {subtitle_cps(seg):.1f} exceeds hard maximum {quality.hard_max_cps}",
                bad_translation=seg.text_tgt or "",
                system_prompt=config.pipeline.translation.system_prompt,
            )
            response = client.translate_request(req)
            if len(response.numbered_lines) != 1:
                raise RuntimeError("compression returned wrong number of lines")
            seg_id, text = strip_numbered_text(response.numbered_lines[0])
            if seg_id != seg.id:
                raise RuntimeError(f"compression returned id {seg_id}, expected {seg.id}")
            text = text.strip()
            if not text:
                raise RuntimeError("compression returned empty text")
            valid, reason = _compressed_text_is_valid(seg, text, quality, budget)
            if not valid:
                raise RuntimeError(reason)
            meta = dict(seg.meta)
            meta["compressed"] = True
            meta["compression_budget"] = budget
            return replace(seg, text_tgt=text, meta=meta), errors
        except Exception as exc:  # pragma: no cover - runtime network branches
            errors.append(
                {
                    "id": seg.id,
                    "provider": provider_name,
                    "model": model,
                    "attempt": attempt + 1,
                    "error_type": classify_error(exc),
                    "message": str(exc),
                }
            )
            if attempt + 1 < attempts:
                time.sleep(min(2**attempt, 5))
    return None, errors


def compress_overlong_subtitles(
    *,
    config: AppConfig,
    segments: list[Segment],
    source_lang: str,
    target_lang: str,
    memory_dir: Path | None = None,
) -> tuple[list[Segment], list[dict[str, Any]]]:
    if not config.pipeline.subtitle.compression.enabled:
        return segments, []
    quality = config.pipeline.subtitle.quality
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    output = list(segments)
    artifacts: list[dict[str, Any]] = []
    memory_document = None
    if memory_dir and translates_with_memory(config.pipeline.memory):
        memory_document = MemoryStore(memory_dir).load_effective(effective_memory_sources(config.pipeline.memory))
    for idx, seg in enumerate(output):
        if subtitle_cps(seg) <= quality.hard_max_cps:
            continue
        memory_prompt = ""
        if memory_document is not None:
            chunk = Chunk(
                chunk_id=f"compress_{seg.id}",
                segment_ids=[seg.id],
                lines=[f"[{seg.id}] {seg.text_src}"],
                context_before=[],
                context_after=[],
            )
            selected = select_memory_entries(memory_document, chunk, config.pipeline.memory.inject)
            memory_prompt = build_memory_prompt(selected, config.pipeline.memory.inject)
        row_errors: list[dict[str, Any]] = []
        compressed: Segment | None = None
        for route in route_candidates:
            provider = config.providers.get(route.provider)
            if not provider:
                row_errors.append(
                    {
                        "id": seg.id,
                        "provider": route.provider,
                        "model": route.model,
                        "error_type": "bad_schema",
                        "message": "provider not found",
                    }
                )
                continue
            compressed, errors = _compress_segment(
                config=config,
                seg=seg,
                source_lang=source_lang,
                target_lang=target_lang,
                provider_name=route.provider,
                model=route.model,
                quality=quality,
                memory_prompt=memory_prompt,
            )
            row_errors.extend(errors)
            if compressed is not None:
                output[idx] = compressed
                artifacts.append(
                    {
                        "id": seg.id,
                        "provider": route.provider,
                        "model": route.model,
                        "status": "compressed",
                        "before": seg.text_tgt,
                        "after": compressed.text_tgt,
                        "budget": _budget(seg, quality),
                        "errors": row_errors,
                    }
                )
                break
        if compressed is None:
            artifacts.append(
                {
                    "id": seg.id,
                    "status": "failed",
                    "before": seg.text_tgt,
                    "after": seg.text_tgt,
                    "budget": _budget(seg, quality),
                    "errors": row_errors,
                }
            )
    return output, artifacts
