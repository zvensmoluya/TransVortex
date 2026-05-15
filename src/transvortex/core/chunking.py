from __future__ import annotations

import re

from ..app.models import Chunk, Segment


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
