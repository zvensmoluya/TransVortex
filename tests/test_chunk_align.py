from __future__ import annotations

from transvortex.aligner import apply_translations, dedupe_overlap_segments, normalize_timeline, validate_segments
from transvortex.chunking import number_and_chunk_segments
from transvortex.models import Segment


def test_chunk_and_align_mapping() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="A"),
        Segment(id=2, start=1.0, end=2.0, text_src="B"),
        Segment(id=3, start=2.0, end=3.0, text_src="C"),
    ]
    chunks = number_and_chunk_segments(segments, batch_size=2)
    assert chunks[0].segment_ids == [1, 2]
    assert chunks[1].segment_ids == [3]

    translated = [
        {
            "chunk_id": "c00000",
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": 1, "text_tgt": "甲"}, {"id": 2, "text_tgt": "乙"}],
        },
        {
            "chunk_id": "c00001",
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": 3, "text_tgt": "丙"}],
        },
    ]
    done = apply_translations(segments, translated)
    assert done[0].text_tgt == "甲"
    assert done[1].text_tgt == "乙"
    assert done[2].text_tgt == "丙"


def test_overlap_dedupe_reassigns_ids() -> None:
    segments = [
        Segment(id=10, start=0.0, end=1.0, text_src="Hello"),
        Segment(id=11, start=0.9, end=1.4, text_src=" hello "),
        Segment(id=12, start=2.0, end=3.0, text_src="World"),
    ]
    out = dedupe_overlap_segments(segments)
    assert [seg.text_src for seg in out] == ["Hello", "World"]
    assert [seg.id for seg in out] == [1, 2]


def test_timeline_normalization_and_quality_warnings() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="A", text_tgt="short"),
        Segment(id=2, start=0.5, end=0.4, text_src="B", text_tgt="x" * 80),
    ]
    normalized = normalize_timeline(segments)
    assert normalized[1].start > normalized[0].end
    assert normalized[1].end > normalized[1].start
    errors, warnings = validate_segments(normalized, max_cps=20, max_line_chars=42)
    assert errors == []
    assert any("max cps" in warning for warning in warnings)
    assert any("line too long" in warning for warning in warnings)
