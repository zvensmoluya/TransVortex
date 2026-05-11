from __future__ import annotations

from pathlib import Path

from transvortex.core.aligner import apply_translations
from transvortex.core.chunking import number_and_chunk_segments
from transvortex.formats.exporter import export_srt
from transvortex.app.models import Segment
from transvortex.utils import read_jsonl


FIXTURE = Path(__file__).parent / "fixtures" / "asr_segments_dialogue.jsonl"


def _load_fixture_segments() -> list[Segment]:
    return [Segment(**row) for row in read_jsonl(FIXTURE)]


def test_asr_fixture_loads_like_raw_segment_jsonl() -> None:
    segments = _load_fixture_segments()
    assert len(segments) == 12
    assert segments[0].id == 1
    assert segments[0].text_src == "hey wait up"
    assert segments[-1].start > segments[0].start


def test_asr_fixture_can_drive_chunk_translate_align_export(tmp_path: Path) -> None:
    segments = _load_fixture_segments()
    chunks = number_and_chunk_segments(segments, batch_size=5)
    assert [chunk.segment_ids for chunk in chunks] == [
        [1, 2, 3, 4, 5],
        [6, 7, 8, 9, 10],
        [11, 12],
    ]

    translated_rows = []
    for chunk in chunks:
        translated_rows.append(
            {
                "chunk_id": chunk.chunk_id,
                "provider": "fixture",
                "model": "manual",
                "rows": [
                    {"id": seg_id, "text_tgt": f"translated line {seg_id}"}
                    for seg_id in chunk.segment_ids
                ],
            }
        )

    final_segments = apply_translations(segments, translated_rows)
    assert [seg.text_tgt for seg in final_segments[:3]] == [
        "translated line 1",
        "translated line 2",
        "translated line 3",
    ]

    output = tmp_path / "fixture.srt"
    export_srt(final_segments, output, bilingual=True)
    body = output.read_text(encoding="utf-8")
    assert "hey wait up" in body
    assert "translated line 12" in body
    assert "00:00:00,320 --> 00:00:01,480" in body
