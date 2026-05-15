from __future__ import annotations

from difflib import SequenceMatcher

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


def _normalized_text(value: str) -> str:
    return " ".join(value.lower().split())


def _similar_enough(left: str, right: str, *, threshold: float) -> bool:
    if not left or not right:
        return False
    if left == right:
        return True
    if len(left) < 12 or len(right) < 12:
        return False
    return SequenceMatcher(None, left, right).ratio() >= threshold


def dedupe_overlap_segments(
    segments: list[Segment],
    *,
    overlap_window_seconds: float = 1.5,
    fuzzy: bool = False,
    fuzzy_threshold: float = 0.9,
) -> list[Segment]:
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    out: list[Segment] = []
    for seg in ordered:
        text = _normalized_text(seg.text_src)
        duplicate = False
        for prev in reversed(out[-5:]):
            prev_text = _normalized_text(prev.text_src)
            if text and seg.start <= prev.end + overlap_window_seconds and (
                text == prev_text or (fuzzy and _similar_enough(text, prev_text, threshold=fuzzy_threshold))
            ):
                duplicate = True
                break
        if not duplicate:
            out.append(seg)
    for idx, seg in enumerate(out, start=1):
        seg.id = idx
    return out


def merge_asr_window_segments(
    window_segments: list[tuple[dict, list[Segment]]],
    *,
    fuzzy_dedupe: bool = True,
) -> list[Segment]:
    kept: list[Segment] = []
    max_overlap = 1.5
    for manifest_item, segments in window_segments:
        trusted_start = float(manifest_item.get("trusted_start", manifest_item.get("start", 0.0)))
        trusted_end = float(
            manifest_item.get(
                "trusted_end",
                float(manifest_item.get("start", 0.0)) + float(manifest_item.get("duration", 0.0)),
            )
        )
        start = float(manifest_item.get("start", trusted_start))
        duration = float(manifest_item.get("duration", max(trusted_end - trusted_start, 0.0)))
        overlap_seconds = max(duration - max(trusted_end - trusted_start, 0.0), 0.0)
        max_overlap = max(max_overlap, overlap_seconds + 1.5)
        for seg in segments:
            midpoint = (seg.start + seg.end) / 2.0
            if trusted_start <= midpoint <= trusted_end:
                seg.meta["asr_window_index"] = manifest_item.get("segment_index")
                seg.meta["asr_window_start"] = start
                kept.append(seg)
    return dedupe_overlap_segments(
        kept,
        overlap_window_seconds=max_overlap,
        fuzzy=fuzzy_dedupe,
    )


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
