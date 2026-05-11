from __future__ import annotations

from ..app.models import Chunk, Segment


def _numbered_line(seg: Segment) -> str:
    return f"[{seg.id}] {seg.text_src}"


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
            chunks.append(
                Chunk(
                    chunk_id=f"c{chunk_idx:05d}",
                    segment_ids=current_ids,
                    lines=current_lines,
                    context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                    context_after=[_numbered_line(item) for item in segments[idx + 1 : after_end]],
                )
            )
            chunk_idx += 1
            chunk_start = idx + 1
            current_ids = []
            current_lines = []
    if current_ids:
        before_start = max(0, chunk_start - max(context_before_lines, 0))
        chunks.append(
            Chunk(
                chunk_id=f"c{chunk_idx:05d}",
                segment_ids=current_ids,
                lines=current_lines,
                context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                context_after=[],
            )
        )
    return chunks
