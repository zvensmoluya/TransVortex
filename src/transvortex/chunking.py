from __future__ import annotations

from .models import Chunk, Segment


def number_and_chunk_segments(segments: list[Segment], batch_size: int) -> list[Chunk]:
    chunks: list[Chunk] = []
    current_ids: list[int] = []
    current_lines: list[str] = []
    chunk_idx = 0
    for seg in segments:
        current_ids.append(seg.id)
        current_lines.append(f"[{seg.id}] {seg.text_src}")
        if len(current_ids) >= batch_size:
            chunks.append(
                Chunk(
                    chunk_id=f"c{chunk_idx:05d}",
                    segment_ids=current_ids,
                    lines=current_lines,
                )
            )
            chunk_idx += 1
            current_ids = []
            current_lines = []
    if current_ids:
        chunks.append(
            Chunk(
                chunk_id=f"c{chunk_idx:05d}",
                segment_ids=current_ids,
                lines=current_lines,
            )
        )
    return chunks
