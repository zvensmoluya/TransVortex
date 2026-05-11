from __future__ import annotations

from transvortex.app.models import Segment, SubtitleQualityConfig
from transvortex.core.subtitle_optimizer import optimize_subtitles


def test_optimizer_extends_segment_when_gap_allows() -> None:
    result = optimize_subtitles(
        [
            Segment(id=1, start=0.0, end=0.2, text_src="hello", text_tgt="这是一条偏长的字幕"),
            Segment(id=2, start=2.0, end=3.0, text_src="next", text_tgt="下一条"),
        ],
        SubtitleQualityConfig(target_cps=10, hard_max_cps=12, min_duration_seconds=0.8),
    )
    assert result.segments[0].end >= 0.8
    row = result.report["segments"][0]
    assert "extend_min_duration" in row["actions"]


def test_optimizer_does_not_extend_into_next_segment() -> None:
    result = optimize_subtitles(
        [
            Segment(id=1, start=0.0, end=0.2, text_src="hello", text_tgt="这是一条偏长的字幕"),
            Segment(id=2, start=0.5, end=1.0, text_src="next", text_tgt="下一条"),
        ],
        SubtitleQualityConfig(target_cps=10, hard_max_cps=12, min_duration_seconds=0.8, min_gap_seconds=0.04),
    )
    assert result.segments[0].end <= result.segments[1].start - 0.04


def test_optimizer_merges_short_adjacent_segments_when_safe() -> None:
    result = optimize_subtitles(
        [
            Segment(id=10, start=0.0, end=0.3, text_src="a", text_tgt="一"),
            Segment(id=20, start=0.32, end=1.2, text_src="b", text_tgt="二"),
        ],
        SubtitleQualityConfig(target_cps=10, hard_max_cps=12, min_duration_seconds=0.8),
    )
    assert len(result.segments) == 1
    assert result.segments[0].id == 10
    assert result.segments[0].meta["source_ids"] == [10, 20]
    assert "merge_next" in result.report["segments"][0]["actions"]


def test_optimizer_reports_unfixed_high_cps() -> None:
    result = optimize_subtitles(
        [Segment(id=1, start=0.0, end=0.5, text_src="a", text_tgt="这是一条非常非常非常长的字幕")],
        SubtitleQualityConfig(target_cps=5, hard_max_cps=6, max_duration_seconds=0.5, min_duration_seconds=0.5),
    )
    assert result.report["summary"]["issue_counts"]["cps_too_high"] == 1


def test_optimizer_off_keeps_segments_unchanged() -> None:
    original = [Segment(id=1, start=0.0, end=0.2, text_src=" a ", text_tgt=" b ")]
    result = optimize_subtitles(original, SubtitleQualityConfig(enabled=False, mode="off"))
    assert result.segments[0].start == 0.0
    assert result.segments[0].end == 0.2
    assert result.segments[0].text_tgt == " b "
    assert result.report["summary"]["mode"] == "off"
