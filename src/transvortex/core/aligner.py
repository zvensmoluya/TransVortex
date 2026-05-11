from __future__ import annotations

from ..app.models import Segment


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


def normalize_timeline(
    segments: list[Segment],
    *,
    min_gap_seconds: float = 0.001,
    min_duration_seconds: float = 0.1,
) -> list[Segment]:
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    previous_end = 0.0
    for seg in ordered:
        if seg.start < previous_end:
            seg.start = previous_end + min_gap_seconds
        if seg.end <= seg.start:
            seg.end = seg.start + min_duration_seconds
        previous_end = seg.end
    return ordered


def dedupe_overlap_segments(segments: list[Segment], *, overlap_window_seconds: float = 1.5) -> list[Segment]:
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    out: list[Segment] = []
    for seg in ordered:
        text = " ".join(seg.text_src.lower().split())
        duplicate = False
        for prev in reversed(out[-5:]):
            prev_text = " ".join(prev.text_src.lower().split())
            if text and text == prev_text and seg.start <= prev.end + overlap_window_seconds:
                duplicate = True
                break
        if not duplicate:
            out.append(seg)
    for idx, seg in enumerate(out, start=1):
        seg.id = idx
    return out


def validate_segments(
    segments: list[Segment],
    *,
    max_cps: int = 20,
    max_line_chars: int = 42,
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    previous_end = -1.0
    for seg in segments:
        if not seg.text_tgt:
            errors.append(f"missing translation for segment {seg.id}")
        if seg.end <= seg.start:
            errors.append(f"invalid timestamp for segment {seg.id}")
        if seg.start < previous_end:
            warnings.append(f"overlapping timestamp near segment {seg.id}")
        previous_end = max(previous_end, seg.end)
        text = (seg.text_tgt or "").strip()
        if not text:
            continue
        duration = max(seg.end - seg.start, 0.001)
        cps = len(text) / duration
        if cps > max_cps:
            warnings.append(f"segment {seg.id} exceeds max cps: {cps:.1f} > {max_cps}")
        longest_line = max((len(line) for line in text.splitlines()), default=0)
        if longest_line > max_line_chars:
            warnings.append(f"segment {seg.id} line too long: {longest_line} > {max_line_chars}")
    return errors, warnings
