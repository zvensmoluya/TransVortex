from __future__ import annotations

import json
from typing import Any

import pytest

from transvortex.core.word_timeline import (
    build_word_timeline_rows,
    merge_word_timeline_windows,
)


def _rows(words: list[dict[str, Any]], generation_id: str) -> list[dict[str, Any]]:
    return build_word_timeline_rows(
        words,
        base_meta={
            "provider": "openrouter_asr",
            "protocol": "openrouter_stt",
            "source": "asr",
            "generation_id": generation_id,
        },
    )


def _manifest(index: int, start: float, end: float, boundary: float) -> dict[str, Any]:
    return {
        "segment_index": index,
        "start": start,
        "duration": end - start,
        "trusted_start": start if index == 0 else boundary,
        "trusted_end": end if index == 1 else boundary,
    }


def _flatten_words(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        word
        for row in rows
        for word in row["meta"]["word_timestamps"]
    ]


def test_word_overlap_aligns_jittered_repeated_words_and_keeps_punctuation() -> None:
    left_words = [
        {"text": "we", "start": 6.4, "end": 6.7},
        {"text": "really", "start": 7.3, "end": 7.6},
        {"text": "very", "start": 7.9, "end": 8.2},
        {"text": "very", "start": 8.4, "end": 8.7},
        {"text": "today.", "start": 8.9, "end": 9.3},
    ]
    right_words = [
        {"text": "really", "start": 7.38, "end": 7.68},
        {"text": "very", "start": 7.98, "end": 8.28},
        {"text": "very", "start": 8.48, "end": 8.78},
        {"text": "today", "start": 8.98, "end": 9.38},
        {"text": "continue", "start": 9.7, "end": 10.1},
    ]

    rows, report = merge_word_timeline_windows(
        [
            (_manifest(0, 0.0, 10.0, 8.5), _rows(left_words, "gen-left")),
            (_manifest(1, 7.0, 17.0, 8.5), _rows(right_words, "gen-right")),
        ]
    )

    words = _flatten_words(rows)
    assert [word["text"] for word in words] == [
        "we",
        "really",
        "very",
        "very",
        "today.",
        "continue",
    ]
    assert report["summary"]["aligned"] == 1
    assert report["summary"]["fallback_seams"] == 0
    assert report["seams"][0]["matched_words"] == 4
    assert report["input_word_count"] == 10
    assert report["output_word_count"] == 6
    assert "really" not in json.dumps(report)
    assert all(row["meta"]["word_overlap_merged"] is True for row in rows)


def test_word_overlap_falls_back_to_trusted_boundary_without_fuzzy_deletion() -> None:
    left_words = [
        {"text": "alpha", "start": 7.1, "end": 7.4},
        {"text": "left-only", "start": 8.0, "end": 8.3},
        {"text": "discard-left", "start": 9.0, "end": 9.3},
    ]
    right_words = [
        {"text": "discard-right", "start": 7.2, "end": 7.5},
        {"text": "right-only", "start": 8.7, "end": 9.0},
        {"text": "future", "start": 9.3, "end": 9.6},
    ]

    rows, report = merge_word_timeline_windows(
        [
            (_manifest(0, 0.0, 10.0, 8.5), _rows(left_words, "gen-left")),
            (_manifest(1, 7.0, 17.0, 8.5), _rows(right_words, "gen-right")),
        ]
    )

    assert [word["text"] for word in _flatten_words(rows)] == [
        "alpha",
        "left-only",
        "right-only",
        "future",
    ]
    assert report["summary"]["trusted_boundary"] == 1
    assert report["summary"]["fallback_seams"] == 1
    assert report["seams"][0]["matched_words"] == 0


def test_word_overlap_uses_time_to_align_repeated_tokens_monotonically() -> None:
    left_words = [
        {"text": "很", "start": 7.4, "end": 7.6},
        {"text": "很", "start": 8.1, "end": 8.3},
        {"text": "好", "start": 8.8, "end": 9.0},
    ]
    right_words = [
        {"text": "很", "start": 7.48, "end": 7.68},
        {"text": "很", "start": 8.18, "end": 8.38},
        {"text": "好", "start": 8.88, "end": 9.08},
        {"text": "。", "start": 9.1, "end": 9.2},
    ]

    rows, report = merge_word_timeline_windows(
        [
            (_manifest(0, 0.0, 10.0, 8.5), _rows(left_words, "gen-left")),
            (_manifest(1, 7.0, 17.0, 8.5), _rows(right_words, "gen-right")),
        ]
    )

    assert [word["text"] for word in _flatten_words(rows)] == ["很", "很", "好", "。"]
    assert "".join(row["text"] for row in rows) == "很很好。"
    assert report["seams"][0]["matched_words"] == 3


def test_word_overlap_rejects_rows_without_word_metadata() -> None:
    with pytest.raises(RuntimeError, match="word_timeline_metadata_missing"):
        merge_word_timeline_windows(
            [
                (
                    _manifest(0, 0.0, 10.0, 10.0),
                    [{"start": 0.0, "end": 1.0, "text": "coarse"}],
                )
            ]
        )
