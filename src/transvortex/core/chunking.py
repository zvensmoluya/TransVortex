from __future__ import annotations

import re

from typing import Any

from ..app.models import AppConfig, Chunk, ProviderConfig, Segment


def _numbered_line(seg: Segment) -> str:
    return f"[{seg.id}] {seg.text_src}"


def _text_density(text: str, duration_seconds: float) -> float:
    duration = max(duration_seconds, 0.01)
    visible = re.sub(r"\s+", "", text)
    return len(visible) / duration


def _is_asr_uncertain(seg: Segment) -> bool:
    if seg.confidence is not None:
        try:
            # faster-whisper stores avg_logprob here; very low values usually mean unstable recognition.
            if float(seg.confidence) < -1.0:
                return True
        except (TypeError, ValueError):
            pass
    duration = max(0.0, float(seg.end) - float(seg.start))
    text = seg.text_src.strip()
    if duration < 0.4 and len(text) >= 8:
        return True
    if duration > 0.0 and _text_density(text, duration) > 24:
        return True
    return False


def _uncertain_ids(segments: list[Segment]) -> list[int]:
    return [seg.id for seg in segments if _is_asr_uncertain(seg)]


def _chunk_from_slice(
    segments: list[Segment],
    chunk_idx: int,
    start: int,
    end: int,
    *,
    context_before_lines: int = 0,
    context_after_lines: int = 0,
) -> Chunk:
    before_start = max(0, start - max(context_before_lines, 0))
    after_end = min(len(segments), end + max(context_after_lines, 0))
    current_segments = segments[start:end]
    return Chunk(
        chunk_id=f"c{chunk_idx:05d}",
        segment_ids=[seg.id for seg in current_segments],
        lines=[_numbered_line(seg) for seg in current_segments],
        context_before=[_numbered_line(item) for item in segments[before_start:start]],
        context_after=[_numbered_line(item) for item in segments[end:after_end]],
        asr_uncertain_ids=_uncertain_ids(current_segments),
    )


def number_and_chunk_segments(
    segments: list[Segment],
    batch_size: int,
    *,
    context_before_lines: int = 0,
    context_after_lines: int = 0,
) -> list[Chunk]:
    chunks: list[Chunk] = []
    current_ids: list[int] = []
    current_lines: list[str] = []
    chunk_idx = 0
    chunk_start = 0
    for idx, seg in enumerate(segments):
        current_ids.append(seg.id)
        current_lines.append(_numbered_line(seg))
        if len(current_ids) >= batch_size:
            before_start = max(0, chunk_start - max(context_before_lines, 0))
            after_end = min(len(segments), idx + 1 + max(context_after_lines, 0))
            current_segments = segments[chunk_start : idx + 1]
            chunks.append(
                Chunk(
                    chunk_id=f"c{chunk_idx:05d}",
                    segment_ids=current_ids,
                    lines=current_lines,
                    context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                    context_after=[_numbered_line(item) for item in segments[idx + 1 : after_end]],
                    asr_uncertain_ids=_uncertain_ids(current_segments),
                )
            )
            chunk_idx += 1
            chunk_start = idx + 1
            current_ids = []
            current_lines = []
    if current_ids:
        before_start = max(0, chunk_start - max(context_before_lines, 0))
        current_segments = segments[chunk_start:]
        chunks.append(
            Chunk(
                chunk_id=f"c{chunk_idx:05d}",
                segment_ids=current_ids,
                lines=current_lines,
                context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                context_after=[],
                asr_uncertain_ids=_uncertain_ids(current_segments),
            )
        )
    return chunks


def _estimated_output_tokens(seg: Segment) -> int:
    text = str(seg.text_src or "")
    # Subtitle translation is usually shorter than raw source characters, but keep a
    # conservative floor so dense ASR and CJK text still influence planning.
    return max(4, int(len(text) * 0.9) + 4)


def _sentence_boundary_score(text: str) -> int:
    stripped = text.strip()
    if not stripped:
        return 0
    score = 0
    if stripped.endswith((".", "?", "!", "。", "？", "！", "…")):
        score += 8
    if stripped.endswith(('"', "'", "”", "’", "」", "』", "）", ")")):
        score += 2
    if len(stripped) <= 18:
        score += 1
    return score


def _boundary_score(segments: list[Segment], cut_index: int) -> int:
    if cut_index <= 0 or cut_index >= len(segments):
        return -10_000
    previous = segments[cut_index - 1]
    current = segments[cut_index]
    pause = max(0.0, float(current.start) - float(previous.end))
    score = _sentence_boundary_score(previous.text_src)
    if pause >= 2.0:
        score += 12
    elif pause >= 1.0:
        score += 8
    elif pause >= 0.5:
        score += 4
    if _is_asr_uncertain(previous) or _is_asr_uncertain(current):
        score -= 12
    return score


def _provider_target_output_tokens(config: AppConfig, provider: ProviderConfig | None) -> tuple[int, int]:
    chunking = config.pipeline.translation.chunking
    hard = max(0, int(chunking.hard_output_tokens or 0))
    target = max(0, int(chunking.target_output_tokens or 0))
    if provider is not None:
        if hard <= 0:
            hard = max(0, int(provider.capabilities.max_output_tokens or 0))
        if target <= 0:
            target = max(0, int(provider.capabilities.recommended_output_tokens or 0))
        if target <= 0 and hard > 0:
            target = max(1, hard // 2)
    return target, hard


def plan_translation_chunks(
    config: AppConfig,
    segments: list[Segment],
    provider: ProviderConfig | None = None,
) -> tuple[list[Chunk], list[dict[str, Any]]]:
    chunking = config.pipeline.translation.chunking
    if str(chunking.mode or "").lower() != "capacity_aware":
        return (
            number_and_chunk_segments(
                segments,
                max(1, int(config.pipeline.translation.chunk_lines)),
                context_before_lines=config.pipeline.translation.context_before_lines,
                context_after_lines=config.pipeline.translation.context_after_lines,
            ),
            [],
        )
    if not segments:
        return [], []

    warnings: list[dict[str, Any]] = []
    provider_max_lines = max(1, int(provider.capabilities.max_batch_lines)) if provider is not None else 0
    configured_max_lines = max(1, int(chunking.max_chunk_lines))
    max_lines = min(configured_max_lines, provider_max_lines) if provider_max_lines else configured_max_lines
    min_lines = max(1, min(int(chunking.min_chunk_lines), max_lines))
    target_lines = max(min_lines, min(int(chunking.target_chunk_lines), max_lines))
    target_tokens, hard_tokens = _provider_target_output_tokens(config, provider)
    boundary_window = max(1, int(chunking.boundary_window_lines))
    soft_boundary = bool(chunking.soft_boundary)
    if provider_max_lines and provider_max_lines < configured_max_lines:
        warnings.append(
            {
                "message": "Reduced capacity-aware chunk max lines to provider capability limit",
                "details": {
                    "configured_max_chunk_lines": configured_max_lines,
                    "provider_max_batch_lines": provider_max_lines,
                    "effective_max_chunk_lines": max_lines,
                },
            }
        )

    chunks: list[Chunk] = []
    start = 0
    chunk_idx = 0
    while start < len(segments):
        token_total = 0
        candidates: list[tuple[int, int]] = []
        cut = start
        while cut < len(segments):
            next_line_count = cut - start + 1
            next_tokens = token_total + _estimated_output_tokens(segments[cut])
            if next_line_count > max_lines or (hard_tokens > 0 and next_line_count >= min_lines and next_tokens > hard_tokens):
                break
            token_total = next_tokens
            cut += 1
            line_count = cut - start
            if line_count >= min_lines and soft_boundary and cut < len(segments):
                candidates.append((cut, _boundary_score(segments, cut)))
            if line_count >= target_lines and (target_tokens <= 0 or token_total >= target_tokens):
                break
            if target_tokens > 0 and line_count >= min_lines and token_total >= target_tokens:
                break

        if cut <= start:
            cut = min(len(segments), start + 1)
        line_count = cut - start
        if soft_boundary and candidates and cut < len(segments) and line_count >= min_lines:
            lower = max(start + min_lines, cut - boundary_window)
            upper = min(cut + boundary_window, start + max_lines, len(segments) - 1)
            window_candidates = [item for item in candidates if lower <= item[0] <= upper]
            if not window_candidates:
                for idx in range(lower, upper + 1):
                    if start < idx < len(segments):
                        window_candidates.append((idx, _boundary_score(segments, idx)))
            if window_candidates:
                best_cut, _score = max(window_candidates, key=lambda item: (item[1], -abs(item[0] - cut), item[0]))
                if start < best_cut <= len(segments):
                    cut = best_cut

        chunks.append(
            _chunk_from_slice(
                segments,
                chunk_idx,
                start,
                cut,
                context_before_lines=config.pipeline.translation.context_before_lines,
                context_after_lines=config.pipeline.translation.context_after_lines,
            )
        )
        chunk_idx += 1
        start = cut
    return chunks, warnings
