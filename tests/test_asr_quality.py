from __future__ import annotations

from types import SimpleNamespace

from transvortex.app.models import Segment
from transvortex.core.asr_quality import detect_asr_boundary_risks


def test_detect_asr_boundary_risks_marks_expected_codes_and_summary() -> None:
    segments = [
        Segment(
            id=1,
            start=0.0,
            end=11.5,
            text_src="第一句。第二句！第三句？" + "很长" * 40,
            meta={"source": "asr"},
        ),
        Segment(id=2, start=11.48, end=12.0, text_src="短句", meta={"source": "asr"}),
        Segment(id=3, start=13.0, end=14.0, text_src="manual subtitle", meta={"source": "srt"}),
    ]

    marked, report = detect_asr_boundary_risks(
        segments,
        provider=SimpleNamespace(name="funasr_sensevoice_local", protocol="funasr_openai", model="sensevoice"),
    )

    first_risk = marked[0].meta["asr_risk"]
    assert first_risk["level"] == "error"
    assert first_risk["retryable"] is True
    assert first_risk["suggested_action"] == "retry_with_shorter_window"
    assert first_risk["codes"] == [
        "long_duration",
        "long_text",
        "multiple_sentence_endings",
        "overlap_next",
    ]
    assert first_risk["metrics"]["duration"] == 11.5
    assert first_risk["metrics"]["sentence_endings"] == 3

    assert "asr_risk" not in marked[2].meta
    assert report["provider"] == {
        "name": "funasr_sensevoice_local",
        "protocol": "funasr_openai",
        "model": "sensevoice",
    }
    assert report["total_asr_segments"] == 2
    assert report["risk_segments"] == 1
    assert report["level_counts"] == {"error": 1}
    assert report["code_counts"]["long_duration"] == 1
    assert report["code_counts"]["overlap_next"] == 1
    assert report["top_risks"][0]["id"] == 1


def test_detect_asr_boundary_risks_marks_gap_dense_and_missing_timestamps() -> None:
    dense = "a" * 30
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="正常", meta={"source": "asr"}),
        Segment(id=2, start=1.05, end=2.05, text_src=dense, meta={"source": "asr"}),
        Segment(
            id=3,
            start=3.0,
            end=9.0,
            text_src="Whole fallback text",
            meta={"source": "asr", "warning": "missing_segment_timestamps"},
        ),
    ]

    marked, report = detect_asr_boundary_risks(segments)

    assert marked[0].meta["asr_risk"]["level"] == "info"
    assert marked[0].meta["asr_risk"]["codes"] == ["tiny_gap_to_next"]
    assert marked[1].meta["asr_risk"]["level"] == "error"
    assert marked[1].meta["asr_risk"]["codes"] == ["dense_text"]
    assert marked[2].meta["asr_risk"]["level"] == "error"
    assert marked[2].meta["asr_risk"]["codes"] == ["missing_segment_timestamps"]
    assert report["level_counts"] == {"error": 2, "info": 1}


def test_detect_asr_boundary_risks_keeps_clean_asr_segment_unmarked() -> None:
    segments = [
        Segment(id=1, start=0.0, end=2.0, text_src="これは短い文です", meta={"source": "asr"}),
        Segment(id=2, start=3.0, end=4.0, text_src="次の文です", meta={"source": "asr"}),
    ]

    marked, report = detect_asr_boundary_risks(segments)

    assert all("asr_risk" not in seg.meta for seg in marked)
    assert report["risk_segments"] == 0
    assert report["code_counts"] == {}
    assert report["top_risks"] == []
