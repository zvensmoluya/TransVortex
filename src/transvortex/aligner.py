from __future__ import annotations

from .models import Segment


def apply_translations(segments: list[Segment], translated_chunk_rows: list[dict]) -> list[Segment]:
    by_id = {seg.id: seg for seg in segments}
    for chunk in translated_chunk_rows:
        for row in chunk.get("rows", []):
            seg_id = int(row["id"])
            text = str(row.get("text_tgt", "")).strip()
            if seg_id in by_id:
                by_id[seg_id].text_tgt = text
                by_id[seg_id].meta["provider"] = chunk.get("provider")
                by_id[seg_id].meta["model"] = chunk.get("model")
                by_id[seg_id].meta["chunk_id"] = chunk.get("chunk_id")
                by_id[seg_id].meta["compat_mode"] = chunk.get("compat_mode")
                by_id[seg_id].meta["base_url"] = chunk.get("base_url")
    return [by_id[idx] for idx in sorted(by_id)]


def validate_segments(segments: list[Segment]) -> list[str]:
    errors: list[str] = []
    for seg in segments:
        if not seg.text_tgt:
            errors.append(f"missing translation for segment {seg.id}")
        if seg.end <= seg.start:
            errors.append(f"invalid timestamp for segment {seg.id}")
    return errors
