from __future__ import annotations

import copy
import math
import unicodedata
from typing import Any

from .subtitle_quality import visual_width


_WORD_SEGMENT_MIN_SECONDS = 0.5
_WORD_SEGMENT_TARGET_SECONDS = 4.0
_WORD_SEGMENT_MAX_SECONDS = 6.0
_WORD_SEGMENT_SOFT_PAUSE_SECONDS = 0.35
_WORD_SEGMENT_HARD_PAUSE_SECONDS = 0.75
_WORD_SEGMENT_TARGET_VISUAL_WIDTH = 64
_WORD_SEGMENT_MAX_VISUAL_WIDTH = 84
_WORD_STRONG_ENDINGS = (".", "?", "!", "。", "？", "！", "…")
_WORD_WEAK_ENDINGS = (",", ";", ":", "，", "；", "：", "、")
_WORD_TRAILING_CLOSERS = "\"'”’」』）)]}】》〉"
_WORD_NO_SPACE_BEFORE = set(",.!?;:，。！？；：、)]}）】〕〉》」』”’%")
_WORD_NO_SPACE_AFTER = set("([{（【〔〈《「『“‘")

_WORD_SOURCE_METAS = "_word_timeline_source_metas"
_WORD_WINDOW_INDICES = "_word_timeline_window_indices"
_WORD_PUBLIC_FIELDS = (
    "text",
    "start",
    "end",
    "confidence",
    "speaker",
    "channel",
    "channel_index",
)
_WORD_META_EXCLUDED_FIELDS = {
    "word_timestamps",
    "word_segmentation",
    "word_overlap_merged",
    "asr_window_index",
    "asr_window_indices",
}
_OVERLAP_ALIGNMENT_MAX_DRIFT_SECONDS = 1.25
_OVERLAP_CANDIDATE_PADDING_SECONDS = 0.35


def build_word_timeline_rows(
    words: list[dict[str, Any]],
    *,
    base_meta: dict[str, Any] | None = None,
    overlap_merged: bool = False,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for group in _segment_words(words):
        text = _join_word_text(group)
        if not text:
            continue
        confidences = [
            float(item["confidence"])
            for item in group
            if isinstance(item.get("confidence"), (int, float))
        ]
        meta = _word_group_meta(
            group,
            base_meta=base_meta,
            overlap_merged=overlap_merged,
        )
        rows.append(
            {
                "start": float(group[0]["start"]),
                "end": max(float(item["end"]) for item in group),
                "text": text,
                "confidence": sum(confidences) / len(confidences) if confidences else None,
                "meta": meta,
            }
        )
    return rows


def merge_word_timeline_windows(
    window_rows: list[tuple[dict[str, Any], list[dict[str, Any]]]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    ordered = sorted(
        window_rows,
        key=lambda item: (
            float(item[0].get("start", 0.0)),
            int(item[0].get("segment_index", 0)),
        ),
    )
    windows: list[tuple[dict[str, Any], list[dict[str, Any]]]] = []
    for manifest_item, rows in ordered:
        windows.append((manifest_item, _extract_window_words(manifest_item, rows)))

    input_word_count = sum(len(words) for _, words in windows)
    seams: list[dict[str, Any]] = []
    merged_words: list[dict[str, Any]] = list(windows[0][1]) if windows else []
    for index in range(1, len(windows)):
        left_manifest, left_window_words = windows[index - 1]
        right_manifest, right_words = windows[index]
        merged_words, seam = _merge_word_timeline_seam(
            merged_words,
            right_words,
            left_manifest=left_manifest,
            right_manifest=right_manifest,
            left_window_empty=not left_window_words,
        )
        seams.append(seam)

    status_counts = {
        status: sum(1 for seam in seams if seam["status"] == status)
        for status in (
            "aligned",
            "weak_alignment",
            "trusted_boundary",
            "no_overlap",
            "empty_window",
        )
    }
    report = {
        "version": 1,
        "strategy": "time_gated_monotonic_word_alignment_v1",
        "applied": any(seam["overlap_seconds"] > 0 for seam in seams),
        "window_count": len(windows),
        "input_word_count": input_word_count,
        "output_word_count": len(merged_words),
        "removed_word_count": max(input_word_count - len(merged_words), 0),
        "seams": seams,
        "summary": {
            **status_counts,
            "fallback_seams": status_counts["trusted_boundary"],
        },
    }
    return (
        build_word_timeline_rows(
            merged_words,
            overlap_merged=bool(seams),
        ),
        report,
    )


def _extract_window_words(
    manifest_item: dict[str, Any],
    rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    window_index = int(manifest_item.get("segment_index", 0))
    words: list[dict[str, Any]] = []
    for row in rows:
        meta = row.get("meta")
        raw_words = meta.get("word_timestamps") if isinstance(meta, dict) else None
        if not isinstance(raw_words, list):
            raise RuntimeError(
                f"word_timeline_metadata_missing: segment={window_index}"
            )
        source_meta = {
            key: copy.deepcopy(value)
            for key, value in meta.items()
            if key not in _WORD_META_EXCLUDED_FIELDS
        }
        for raw_word in raw_words:
            word = _validated_public_word(raw_word)
            if word is None:
                continue
            word[_WORD_SOURCE_METAS] = [source_meta]
            word[_WORD_WINDOW_INDICES] = [window_index]
            words.append(word)
    words.sort(key=lambda item: (float(item["start"]), float(item["end"])))
    return words


def _validated_public_word(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    text = str(value.get("text") or value.get("word") or "").strip()
    start = _finite_float(value.get("start"))
    end = _finite_float(value.get("end"))
    if not text or start is None or end is None or start < 0 or end <= start:
        return None
    word: dict[str, Any] = {"text": text, "start": start, "end": end}
    confidence = _finite_float(value.get("confidence"))
    if confidence is not None and 0 <= confidence <= 1:
        word["confidence"] = confidence
    for field in ("speaker", "channel", "channel_index"):
        if value.get(field) is not None:
            word[field] = copy.deepcopy(value[field])
    return word


def _merge_word_timeline_seam(
    left_words: list[dict[str, Any]],
    right_words: list[dict[str, Any]],
    *,
    left_manifest: dict[str, Any],
    right_manifest: dict[str, Any],
    left_window_empty: bool,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    overlap_start, overlap_end = _window_overlap(left_manifest, right_manifest)
    overlap_seconds = max(overlap_end - overlap_start, 0.0)
    boundary = _trusted_boundary(
        left_manifest,
        right_manifest,
        overlap_start=overlap_start,
        overlap_end=overlap_end,
    )
    base_report: dict[str, Any] = {
        "left_window_index": int(left_manifest.get("segment_index", 0)),
        "right_window_index": int(right_manifest.get("segment_index", 0)),
        "overlap_start": overlap_start,
        "overlap_end": overlap_end,
        "overlap_seconds": overlap_seconds,
        "trusted_boundary": boundary,
        "left_candidate_words": 0,
        "right_candidate_words": 0,
        "matched_words": 0,
        "max_time_drift_seconds": None,
        "removed_words": 0,
    }
    if left_window_empty or not right_words:
        merged = [*left_words, *right_words]
        return merged, {**base_report, "status": "empty_window"}
    if overlap_seconds <= 0:
        merged = [*left_words, *right_words]
        return merged, {**base_report, "status": "no_overlap"}

    left_candidates = _overlap_candidates(left_words, overlap_start, overlap_end)
    right_candidates = _overlap_candidates(right_words, overlap_start, overlap_end)
    matches = _align_word_candidates(left_candidates, right_candidates)
    base_report["left_candidate_words"] = len(left_candidates)
    base_report["right_candidate_words"] = len(right_candidates)
    base_report["matched_words"] = len(matches)
    if matches:
        base_report["max_time_drift_seconds"] = max(match[2] for match in matches)
        reconciled_left = list(left_words)
        reconciled_right = list(right_words)
        for left_index, right_index, _drift in matches:
            reconciled = _merge_matching_words(
                reconciled_left[left_index],
                reconciled_right[right_index],
                boundary=boundary,
            )
            reconciled_left[left_index] = reconciled
            reconciled_right[right_index] = reconciled
        splice_left, splice_right, _ = min(
            matches,
            key=lambda match: (
                abs(
                    (
                        _word_midpoint(left_words[match[0]])
                        + _word_midpoint(right_words[match[1]])
                    )
                    / 2.0
                    - boundary
                ),
                match[2],
            ),
        )
        merged = [
            *reconciled_left[:splice_left],
            reconciled_left[splice_left],
            *reconciled_right[splice_right + 1 :],
        ]
        return merged, {
            **base_report,
            "status": "aligned" if len(matches) >= 2 else "weak_alignment",
            "removed_words": max(len(left_words) + len(right_words) - len(merged), 0),
        }

    merged = [
        *(word for word in left_words if _word_midpoint(word) < boundary),
        *(word for word in right_words if _word_midpoint(word) >= boundary),
    ]
    return merged, {
        **base_report,
        "status": "trusted_boundary",
        "removed_words": max(len(left_words) + len(right_words) - len(merged), 0),
    }


def _window_overlap(
    left_manifest: dict[str, Any],
    right_manifest: dict[str, Any],
) -> tuple[float, float]:
    left_start = float(left_manifest.get("start", 0.0))
    left_end = left_start + max(float(left_manifest.get("duration", 0.0)), 0.0)
    right_start = float(right_manifest.get("start", 0.0))
    right_end = right_start + max(float(right_manifest.get("duration", 0.0)), 0.0)
    return max(left_start, right_start), min(left_end, right_end)


def _trusted_boundary(
    left_manifest: dict[str, Any],
    right_manifest: dict[str, Any],
    *,
    overlap_start: float,
    overlap_end: float,
) -> float:
    left_start = float(left_manifest.get("start", 0.0))
    left_default_end = left_start + max(float(left_manifest.get("duration", 0.0)), 0.0)
    right_start = float(right_manifest.get("start", 0.0))
    left_trusted_end = float(left_manifest.get("trusted_end", left_default_end))
    right_trusted_start = float(right_manifest.get("trusted_start", right_start))
    boundary = (left_trusted_end + right_trusted_start) / 2.0
    if overlap_end > overlap_start:
        return max(overlap_start, min(boundary, overlap_end))
    return boundary


def _overlap_candidates(
    words: list[dict[str, Any]],
    overlap_start: float,
    overlap_end: float,
) -> list[tuple[int, dict[str, Any]]]:
    lower = overlap_start - _OVERLAP_CANDIDATE_PADDING_SECONDS
    upper = overlap_end + _OVERLAP_CANDIDATE_PADDING_SECONDS
    return [
        (index, word)
        for index, word in enumerate(words)
        if lower <= _word_midpoint(word) <= upper
    ]


def _align_word_candidates(
    left: list[tuple[int, dict[str, Any]]],
    right: list[tuple[int, dict[str, Any]]],
) -> list[tuple[int, int, float]]:
    paths: list[list[tuple[int, float, tuple[tuple[int, int, float], ...]]]] = [
        [(0, 0.0, ()) for _ in range(len(right) + 1)]
        for _ in range(len(left) + 1)
    ]
    for left_offset, (left_index, left_word) in enumerate(left):
        for right_offset, (right_index, right_word) in enumerate(right):
            best = _better_alignment_path(
                paths[left_offset][right_offset + 1],
                paths[left_offset + 1][right_offset],
            )
            left_token = _normalize_comparison_token(str(left_word.get("text") or ""))
            right_token = _normalize_comparison_token(str(right_word.get("text") or ""))
            drift = abs(_word_midpoint(left_word) - _word_midpoint(right_word))
            if (
                left_token
                and left_token == right_token
                and drift <= _OVERLAP_ALIGNMENT_MAX_DRIFT_SECONDS
            ):
                previous = paths[left_offset][right_offset]
                matched = (
                    previous[0] + 1,
                    previous[1] + drift,
                    (*previous[2], (left_index, right_index, drift)),
                )
                best = _better_alignment_path(best, matched)
            paths[left_offset + 1][right_offset + 1] = best
    return list(paths[-1][-1][2])


def _better_alignment_path(
    left: tuple[int, float, tuple[tuple[int, int, float], ...]],
    right: tuple[int, float, tuple[tuple[int, int, float], ...]],
) -> tuple[int, float, tuple[tuple[int, int, float], ...]]:
    if right[0] > left[0]:
        return right
    if right[0] == left[0] and right[1] < left[1] - 1e-9:
        return right
    return left


def _normalize_comparison_token(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    lexical = "".join(
        char
        for char in normalized
        if unicodedata.category(char)[:1] in {"L", "M", "N"}
    )
    if lexical:
        return lexical
    return "".join(char for char in normalized if not char.isspace())


def _merge_matching_words(
    left: dict[str, Any],
    right: dict[str, Any],
    *,
    boundary: float,
) -> dict[str, Any]:
    def preference(word: dict[str, Any], *, prefer_right: bool) -> tuple[float, ...]:
        text = str(word.get("text") or "")
        punctuation = sum(
            1 for char in text if unicodedata.category(char).startswith("P")
        )
        confidence = word.get("confidence")
        confidence_score = float(confidence) if isinstance(confidence, (int, float)) else -1.0
        return (
            float(punctuation),
            float(len(text)),
            confidence_score,
            -abs(_word_midpoint(word) - boundary),
            1.0 if prefer_right else 0.0,
        )

    chosen = right if preference(right, prefer_right=True) > preference(left, prefer_right=False) else left
    merged = copy.deepcopy(chosen)
    source_metas: list[dict[str, Any]] = []
    for word in (left, right):
        for meta in word.get(_WORD_SOURCE_METAS, []):
            if meta not in source_metas:
                source_metas.append(copy.deepcopy(meta))
    window_indices = sorted(
        {
            int(index)
            for word in (left, right)
            for index in word.get(_WORD_WINDOW_INDICES, [])
        }
    )
    merged[_WORD_SOURCE_METAS] = source_metas
    merged[_WORD_WINDOW_INDICES] = window_indices
    return merged


def _word_group_meta(
    group: list[dict[str, Any]],
    *,
    base_meta: dict[str, Any] | None,
    overlap_merged: bool,
) -> dict[str, Any]:
    meta = copy.deepcopy(base_meta or {})
    source_metas = [
        source_meta
        for word in group
        for source_meta in word.get(_WORD_SOURCE_METAS, [])
        if isinstance(source_meta, dict)
    ]
    if source_metas:
        shared_keys = set(source_metas[0])
        for source_meta in source_metas[1:]:
            shared_keys.intersection_update(source_meta)
        for key in sorted(shared_keys):
            if key in _WORD_META_EXCLUDED_FIELDS:
                continue
            first_value = source_metas[0][key]
            if all(source_meta[key] == first_value for source_meta in source_metas[1:]):
                meta[key] = copy.deepcopy(first_value)

    meta["timeline_source"] = "response.words"
    meta["word_segmentation"] = "punctuation_pause_duration_v1"
    meta["word_timestamps"] = [_public_word(word) for word in group]
    if overlap_merged:
        meta["word_overlap_merged"] = True

    window_indices = sorted(
        {
            int(index)
            for word in group
            for index in word.get(_WORD_WINDOW_INDICES, [])
        }
    )
    if len(window_indices) == 1:
        meta["asr_window_index"] = window_indices[0]
    elif window_indices:
        meta["asr_window_indices"] = window_indices

    generation_ids = sorted(
        {
            str(source_meta.get("generation_id") or "").strip()
            for source_meta in source_metas
            if str(source_meta.get("generation_id") or "").strip()
        }
    )
    if len(generation_ids) > 1:
        meta.pop("generation_id", None)
        meta["generation_ids"] = generation_ids

    for field in ("speaker", "channel", "channel_index"):
        values = [word[field] for word in group if word.get(field) is not None]
        if values and all(value == values[0] for value in values[1:]):
            meta[field] = copy.deepcopy(values[0])
        else:
            meta.pop(field, None)
    return meta


def _public_word(word: dict[str, Any]) -> dict[str, Any]:
    return {
        field: copy.deepcopy(word[field])
        for field in _WORD_PUBLIC_FIELDS
        if field in word
    }


def _segment_words(words: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    groups: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []

    def flush(count: int | None = None) -> None:
        nonlocal current
        cut = len(current) if count is None else max(0, min(count, len(current)))
        if cut:
            groups.append(current[:cut])
            current = current[cut:]

    for index, word in enumerate(words):
        if current and _word_stream_changed(current[-1], word):
            flush()

        while current and _word_hard_limit_exceeded([*current, word]):
            flush(_preferred_word_cut(current))

        current.append(word)
        next_word = words[index + 1] if index + 1 < len(words) else None
        duration = _word_group_duration(current)
        gap = _word_gap(word, next_word) if next_word is not None else 0.0
        text = str(word["text"])

        if next_word is not None and _word_stream_changed(word, next_word):
            flush()
        elif gap >= _WORD_SEGMENT_HARD_PAUSE_SECONDS:
            flush()
        elif _word_has_strong_ending(text) and (
            duration >= _WORD_SEGMENT_MIN_SECONDS
            or gap >= _WORD_SEGMENT_SOFT_PAUSE_SECONDS
        ):
            flush()
        elif duration >= _WORD_SEGMENT_TARGET_SECONDS and (
            _word_has_weak_ending(text)
            or gap >= _WORD_SEGMENT_SOFT_PAUSE_SECONDS
            or visual_width(_join_word_text(current)) >= _WORD_SEGMENT_TARGET_VISUAL_WIDTH
        ):
            flush()

    flush()
    return groups


def _preferred_word_cut(words: list[dict[str, Any]]) -> int | None:
    if len(words) < 2:
        return None
    start = float(words[0]["start"])
    candidates: list[tuple[float, int]] = []
    for index in range(1, len(words)):
        previous = words[index - 1]
        current = words[index]
        duration = float(previous["end"]) - start
        if duration < _WORD_SEGMENT_MIN_SECONDS:
            continue
        gap = _word_gap(previous, current)
        strong = _word_has_strong_ending(str(previous["text"]))
        weak = _word_has_weak_ending(str(previous["text"]))
        if not strong and not weak and gap < _WORD_SEGMENT_SOFT_PAUSE_SECONDS:
            continue
        score = abs(duration - _WORD_SEGMENT_TARGET_SECONDS)
        if strong:
            score -= 2.0
        elif gap >= _WORD_SEGMENT_HARD_PAUSE_SECONDS:
            score -= 1.5
        elif weak:
            score -= 0.75
        candidates.append((score, index))
    if not candidates:
        return None
    return min(candidates, key=lambda item: (item[0], -item[1]))[1]


def _word_hard_limit_exceeded(words: list[dict[str, Any]]) -> bool:
    if not words:
        return False
    return (
        _word_group_duration(words) > _WORD_SEGMENT_MAX_SECONDS
        or visual_width(_join_word_text(words)) > _WORD_SEGMENT_MAX_VISUAL_WIDTH
    )


def _word_group_duration(words: list[dict[str, Any]]) -> float:
    if not words:
        return 0.0
    return max(float(item["end"]) for item in words) - float(words[0]["start"])


def _word_gap(left: dict[str, Any], right: dict[str, Any] | None) -> float:
    if right is None:
        return 0.0
    return max(0.0, float(right["start"]) - float(left["end"]))


def _word_stream_changed(left: dict[str, Any], right: dict[str, Any]) -> bool:
    for field in ("speaker", "channel", "channel_index"):
        left_value = left.get(field)
        right_value = right.get(field)
        if left_value is not None and right_value is not None and left_value != right_value:
            return True
    return False


def _word_has_strong_ending(text: str) -> bool:
    normalized = text.strip().rstrip(_WORD_TRAILING_CLOSERS)
    return normalized.endswith(_WORD_STRONG_ENDINGS)


def _word_has_weak_ending(text: str) -> bool:
    normalized = text.strip().rstrip(_WORD_TRAILING_CLOSERS)
    return normalized.endswith(_WORD_WEAK_ENDINGS)


def _join_word_text(words: list[dict[str, Any]]) -> str:
    text = ""
    for item in words:
        token = str(item.get("text") or "").strip()
        if not token:
            continue
        if text and _word_needs_space(text[-1], token[0]):
            text += " "
        text += token
    return text.strip()


def _word_needs_space(left: str, right: str) -> bool:
    if right in _WORD_NO_SPACE_BEFORE or left in _WORD_NO_SPACE_AFTER:
        return False
    if _is_compact_asian_script(left) or _is_compact_asian_script(right):
        return False
    return True


def _is_compact_asian_script(char: str) -> bool:
    codepoint = ord(char)
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x3040 <= codepoint <= 0x30FF
        or 0x31F0 <= codepoint <= 0x31FF
    )


def _word_midpoint(word: dict[str, Any]) -> float:
    return (float(word["start"]) + float(word["end"])) / 2.0


def _finite_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None
