from __future__ import annotations

from pathlib import Path

from transvortex.formats.exporter import export_ass, export_srt
from transvortex.app.models import AssStyleConfig, Segment
from transvortex.core.subtitle_quality import (
    clean_subtitle_text,
    format_subtitle_lines,
    prepare_segments_for_export,
    visual_width,
    wrap_subtitle_text,
)


def test_clean_subtitle_text_collapses_whitespace_and_blank_lines() -> None:
    assert clean_subtitle_text("  hello\t world  \n\n  again  ") == "hello world\nagain"


def test_wrap_english_preserves_words_when_possible() -> None:
    lines = wrap_subtitle_text(
        "This is a long subtitle line that should wrap cleanly at word boundaries",
        max_line_width=22,
    )
    assert len(lines) > 1
    assert all(visual_width(line) <= 22 for line in lines)
    assert " ".join(lines) == "This is a long subtitle line that should wrap cleanly at word boundaries"


def test_wrap_cjk_uses_visual_width() -> None:
    text = "\u8fd9\u662f\u4e00\u4e2a\u5f88\u957f\u5f88\u957f\u7684\u4e2d\u6587\u5b57\u5e55\u7528\u4e8e\u6d4b\u8bd5\u81ea\u52a8\u6362\u884c"
    lines = wrap_subtitle_text(text, max_line_width=12)
    assert len(lines) > 1
    assert all(visual_width(line) <= 12 for line in lines)
    assert "".join(lines) == text


def test_format_bilingual_lines_source_first() -> None:
    seg = Segment(
        id=1,
        start=0.0,
        end=2.0,
        text_src=" Hello   world ",
        text_tgt=" \u4f60\u597d\uff0c\u4e16\u754c ",
    )
    assert format_subtitle_lines(seg, bilingual=True) == ["Hello world", "\u4f60\u597d\uff0c\u4e16\u754c"]
    assert format_subtitle_lines(seg, bilingual=False) == ["\u4f60\u597d\uff0c\u4e16\u754c"]


def test_prepare_segments_for_export_stabilizes_timeline() -> None:
    segments = [
        Segment(id=1, start=-1.0, end=0.1, text_src="a", text_tgt="one"),
        Segment(id=2, start=0.2, end=0.2, text_src="b", text_tgt="two"),
        Segment(id=3, start=0.25, end=1.0, text_src="c", text_tgt="three"),
    ]
    out = prepare_segments_for_export(segments, min_gap_seconds=0.01, min_duration_seconds=0.35)
    assert out[0].start == 0.0
    assert out[0].end <= out[1].start - 0.01
    assert out[1].end <= out[2].start - 0.01
    assert all(seg.end > seg.start for seg in out)
    assert segments[0].start == -1.0


def test_export_srt_wraps_text_and_normalizes_timestamps(tmp_path: Path) -> None:
    out_file = tmp_path / "out.srt"
    export_srt(
        [
            Segment(
                id=1,
                start=0.0,
                end=0.05,
                text_src="source line",
                text_tgt="This is a long subtitle line that should wrap cleanly at word boundaries",
            ),
            Segment(id=2, start=0.1, end=0.2, text_src="src", text_tgt="short"),
        ],
        out_file,
        bilingual=False,
    )
    body = out_file.read_text(encoding="utf-8")
    assert "1\n00:00:00,000 --> 00:00:00,099" in body
    assert "2\n00:00:00,100 --> 00:00:00,450" in body
    assert "This is a long subtitle line that should\nwrap cleanly at word boundaries" in body


def test_export_ass_writes_styles_bilingual_order_and_chinese_path(tmp_path: Path) -> None:
    out_file = tmp_path / "中文输出.ass"
    export_ass(
        [
            Segment(
                id=1,
                start=0.0,
                end=1.25,
                text_src="Hello {world}",
                text_tgt="你好",
            )
        ],
        out_file,
        bilingual=True,
        style=AssStyleConfig(font_name="Arial", font_size=36, bilingual_order="target_source"),
    )
    body = out_file.read_text(encoding="utf-8-sig")
    assert "[V4+ Styles]" in body
    assert "Style: Default,Arial,36" in body
    assert "Dialogue: 0,0:00:00.00,0:00:01.25" in body
    assert "你好\\NHello \\{world\\}" in body
