from __future__ import annotations

from transvortex.aligner import apply_translations
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
