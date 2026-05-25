from __future__ import annotations

from transvortex.app.models import Segment
from transvortex.core.source_cleaner import classify_source_text, clean_source_segments


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
