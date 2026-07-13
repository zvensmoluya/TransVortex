from __future__ import annotations

from transvortex.app.models import Segment
from transvortex.core.source_cleaner import (
    classify_source_text,
    clean_source_segments,
    compact_periodic_repetition,
    source_text_for_display,
    source_text_for_model,
)


def test_classify_source_text_drops_cjk_sound_effect_lines() -> None:
    repeated = "耳かき音、耳かき音、耳かき音、耳かき音"

    assert classify_source_text("（掏耳声）").action == "drop"
    assert classify_source_text("耳かき音").action == "drop"
    assert classify_source_text("♪♪").flags == ["sound_effect", "noise"]
    assert classify_source_text(repeated).reasons == ["repeated_sound_effect", "sound_effect"]


def test_classify_source_text_warns_mixed_sound_effect_line() -> None:
    result = classify_source_text("ちょっと待って、呼吸声")

    assert result.action == "warn"
    assert "mixed_sound_effect" in result.reasons


def test_classify_source_text_warns_delimiter_free_periodic_repetition() -> None:
    result = classify_source_text("コシ" * 48)

    assert result.action == "warn"
    assert result.reasons == ["periodic_repetition"]
    assert result.flags == ["suspicious", "repetition"]


def test_compact_periodic_repetition_preserves_prefix_and_bounds_repeated_run() -> None:
    assert compact_periodic_repetition("コシ" * 48) == "コシコシコシコシ…"
    assert compact_periodic_repetition("コシ" * 48 + "コ") == "コシコシコシコシ…"
    assert compact_periodic_repetition("いつだよ、" + "いち" * 50) == "いつだよ、いちいちいちいち…"
    assert compact_periodic_repetition("これは普通の台詞です。") is None


def test_clean_source_segments_only_drops_asr_by_default() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="耳かき音", meta={"source": "asr"}),
        Segment(id=2, start=1.0, end=2.0, text_src="Hello", meta={"source": "asr"}),
        Segment(id=3, start=2.0, end=3.0, text_src="（掏耳声）", meta={"source": "srt"}),
    ]

    result = clean_source_segments(segments)

    assert [seg.text_src for seg in result.segments] == ["Hello", "（掏耳声）"]
    assert [seg.id for seg in result.segments] == [1, 2]
    assert result.segments[0].meta["source_cleaning_original_id"] == 2
    assert result.report["dropped_segments"] == 1
    assert result.report["action_counts"]["skipped_non_asr"] == 1


def test_clean_source_segments_preserves_but_marks_periodic_asr_text() -> None:
    segments = [
        Segment(id=1, start=0.0, end=20.0, text_src="コシ" * 48, meta={"source": "asr"}),
    ]

    result = clean_source_segments(segments)

    assert len(result.segments) == 1
    segment = result.segments[0]
    assert segment.text_src == "コシ" * 48
    assert segment.meta["source_cleaning_warnings"] == ["periodic_repetition"]
    assert source_text_for_model(segment) == "コシコシコシコシ…"
    assert source_text_for_display(segment) == "コシコシコシコシ…"
    assert segment.meta["source_text_compaction"] == {
        "reason": "periodic_repetition",
        "original_length": 96,
        "compacted_length": 9,
    }
    assert result.report["warning_segments"] == 1
