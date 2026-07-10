from __future__ import annotations

from pathlib import Path

from transvortex.formats.exporter import export_ass, export_lrc, export_srt, export_vtt, subtitle_delivery_report
from transvortex.app.models import AssStyleConfig, Segment
from transvortex.formats.presentation import build_render_plan, resolve_ass_style
from transvortex.core.subtitle_quality import (
    clean_subtitle_text,
    format_subtitle_lines,
    prepare_segments_for_export,
    subtitle_line_width,
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
    assert all(subtitle_line_width(line) <= 12 for line in lines)
    assert "".join(lines) == text


def test_wrap_cjk_keeps_closing_punctuation_with_previous_line() -> None:
    lines = wrap_subtitle_text(
        "\u5c45\u7136\u51fa\u8fd9\u79cd\u4e0d\u77e5\u9053\u548c\u6211\u4e00\u6837\u7684\u661f\u7a7a\u5c31\u89e3\u4e0d\u5f00\u7684\u9898\u3002",
        max_line_width=42,
    )

    assert lines == ["\u5c45\u7136\u51fa\u8fd9\u79cd\u4e0d\u77e5\u9053\u548c\u6211\u4e00\u6837\u7684\u661f\u7a7a\u5c31\u89e3\u4e0d\u5f00\u7684\u9898\u3002"]


def test_wrap_mixed_cjk_english_keeps_ascii_word_with_context() -> None:
    lines = wrap_subtitle_text(
        "这是一条较长的中文字幕，用来检查双语排版、English 混排和 2026 这种数字不会挤在一起。",
        max_line_width=42,
    )

    assert all(line != "English" for line in lines)
    assert all(subtitle_line_width(line) <= 42 for line in lines)
    assert "".join(line.replace(" ", "") for line in lines) == "这是一条较长的中文字幕，用来检查双语排版、English混排和2026这种数字不会挤在一起。"


def test_wrap_cjk_balances_two_lines_at_phrase_boundary() -> None:
    lines = wrap_subtitle_text(
        "但因为一开始做了普通的忏悔，结果大声说话的部分就变少了。",
        max_line_width=42,
    )

    assert lines == ["但因为一开始做了普通的忏悔，", "结果大声说话的部分就变少了。"]


def test_wrap_cjk_avoids_orphaned_pronoun_line_start() -> None:
    lines = wrap_subtitle_text("今天晚上我想让你慢慢放松下来", max_line_width=20)

    assert lines == ["今天晚上我想让你", "慢慢放松下来"]
    assert all(subtitle_line_width(line) <= 20 for line in lines)


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
    assert out_file.read_bytes().startswith(b"\xef\xbb\xbf")
    body = out_file.read_text(encoding="utf-8")
    assert "1\n00:00:00,000 --> 00:00:00,099" in body
    assert "2\n00:00:00,100 --> 00:00:00,450" in body
    assert "This is a long subtitle line that should\nwrap cleanly at word boundaries" in body


def test_export_srt_style_prefers_single_line_when_within_hard_width(tmp_path: Path) -> None:
    out_file = tmp_path / "single.srt"
    target = "这是一条长度适中的中文字幕，默认应该尽量保持单行。"

    export_srt(
        [Segment(id=1, start=0.0, end=2.0, text_src="short source", text_tgt=target)],
        out_file,
        bilingual=False,
        style=AssStyleConfig(target_max_width=28, hard_max_width=64, prefer_single_line=True),
    )

    cue_lines = out_file.read_text(encoding="utf-8").splitlines()[2:]
    assert cue_lines == [target]


def test_export_srt_style_orders_bilingual_lines_and_keeps_source_single_line(tmp_path: Path) -> None:
    out_file = tmp_path / "bilingual.srt"
    source = "これはとても長い原文字幕なので普通に折り返すと二行になってしまいます"

    export_srt(
        [Segment(id=1, start=0.0, end=2.0, text_src=source, text_tgt="放松下来")],
        out_file,
        bilingual=True,
        style=AssStyleConfig(
            target_max_width=16,
            source_max_width=16,
            hard_max_width=16,
            bilingual_order="target_source",
        ),
    )

    cue_lines = out_file.read_text(encoding="utf-8").splitlines()[2:]
    assert cue_lines == ["放松下来", source]


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
    assert "Style: Target,Arial,36" in body
    assert "Style: Source,Yu Gothic,25" in body
    assert "Dialogue: 0,0:00:00.00,0:00:01.25,Source" in body
    assert "Dialogue: 1,0:00:00.00,0:00:01.25,Target" in body
    assert "你好" in body
    assert "Hello \\{world\\}" in body


def test_export_ass_target_only_omits_source_dialogue(tmp_path: Path) -> None:
    out_file = tmp_path / "target.ass"
    export_ass(
        [Segment(id=1, start=0.0, end=1.0, text_src="Hello", text_tgt="你好")],
        out_file,
        bilingual=False,
    )
    body = out_file.read_text(encoding="utf-8-sig")
    assert "Dialogue: 1,0:00:00.00,0:00:01.00,Target" in body
    assert ",Source" not in "\n".join(line for line in body.splitlines() if line.startswith("Dialogue:"))


def test_export_ass_bilingual_order_swaps_visual_margins(tmp_path: Path) -> None:
    segment = Segment(id=1, start=0.0, end=1.0, text_src="Hello", text_tgt="你好")
    target_source = tmp_path / "target_source.ass"
    source_target = tmp_path / "source_target.ass"
    export_ass(
        [segment],
        target_source,
        bilingual=True,
        style=AssStyleConfig(font_name="Arial", margin_v=48, source_margin_v=104, bilingual_order="target_source"),
    )
    export_ass(
        [segment],
        source_target,
        bilingual=True,
        style=AssStyleConfig(font_name="Arial", margin_v=48, source_margin_v=104, bilingual_order="source_target"),
    )
    target_source_body = target_source.read_text(encoding="utf-8-sig")
    source_target_body = source_target.read_text(encoding="utf-8-sig")
    assert "Style: Target,Arial,39,&H00F6F1EA,&H000000FF,&H8A000000,&H82000000,0,0,0,0,100,100,0,0,1,1.35,0.18,2,120,120,114,1" in target_source_body
    assert "Style: Source,Yu Gothic,25,&H00D2CBC2,&H000000FF,&H96000000,&H84000000,0,0,0,0,100,100,0,0,1,1.05,0.14,2,120,120,48,1" in target_source_body
    assert "Dialogue: 1,0:00:00.00,0:00:01.00,Target,,0,0,104,,你好" in target_source_body
    assert "Dialogue: 0,0:00:00.00,0:00:01.00,Source,,0,0,48,,Hello" in target_source_body
    assert "Style: Target,Arial,39,&H00F6F1EA,&H000000FF,&H8A000000,&H82000000,0,0,0,0,100,100,0,0,1,1.35,0.18,2,120,120,48,1" in source_target_body
    assert "Style: Source,Yu Gothic,25,&H00D2CBC2,&H000000FF,&H96000000,&H84000000,0,0,0,0,100,100,0,0,1,1.05,0.14,2,120,120,144,1" in source_target_body
    assert "Dialogue: 0,0:00:00.00,0:00:01.00,Source,,0,0,104,,Hello" in source_target_body
    assert "Dialogue: 1,0:00:00.00,0:00:01.00,Target,,0,0,48,,你好" in source_target_body


def test_ass_presentation_plan_wraps_long_bilingual_text_without_changing_segment_text() -> None:
    segment = Segment(
        id=1,
        start=0.0,
        end=3.0,
        text_src="This English source line mixes Tokyo 2026, AI, and a very long explanation for layout.",
        text_tgt="这是一条用于正式观看的中文字幕，它需要自动换行并保持双语层级清楚。",
    )
    plan = build_render_plan(
        [segment],
        output_format="ass",
        bilingual=True,
        style=AssStyleConfig(target_max_width=28, source_max_width=34),
    )

    cue = plan.cues[0]
    assert 1 <= len(cue.target.lines) <= 2
    assert cue.source is not None
    assert 1 <= len(cue.source.lines) <= 2
    assert segment.text_tgt == "这是一条用于正式观看的中文字幕，它需要自动换行并保持双语层级清楚。"


def test_ass_presentation_keeps_source_single_line_in_bilingual_mode() -> None:
    source = "これはとても長い原文字幕なので普通に折り返すと二行になってしまいます"
    plan = build_render_plan(
        [Segment(id=1, start=0.0, end=3.0, text_src=source, text_tgt="放松下来")],
        output_format="ass",
        bilingual=True,
        style=AssStyleConfig(source_max_width=16, hard_max_width=16),
    )

    cue = plan.cues[0]
    assert cue.source is not None
    assert cue.source.lines == [source]
    assert cue.source.max_line_width > 16


def test_ass_presentation_never_clamps_text_content() -> None:
    target = "这是一条非常非常长的中文字幕，它会超过两行，但表现层必须完整保留每一个字，不能为了样式把语义内容截断。"
    source = "This is a very long source subtitle that can exceed two rendered lines, but the renderer must keep the full text."
    plan = build_render_plan(
        [Segment(id=1, start=0.0, end=4.0, text_src=source, text_tgt=target)],
        output_format="ass",
        bilingual=True,
        style=AssStyleConfig(target_max_width=20, source_max_width=24, hard_max_width=28),
    )

    cue = plan.cues[0]
    assert "".join(cue.target.lines) == target
    assert cue.source is not None
    assert " ".join(cue.source.lines) == source
    assert any(issue["code"] == "target_too_many_lines" for issue in cue.issues)


def test_ass_default_style_has_cjk_font_candidates_and_delivery_report() -> None:
    style = resolve_ass_style(AssStyleConfig())
    report = subtitle_delivery_report(
        [
            Segment(
                id=1,
                start=0.0,
                end=2.0,
                text_src="Hello world",
                text_tgt="你好，世界",
            )
        ],
        output_format="ass",
        bilingual=True,
        style=style,
    )

    assert style.preset == "cinematic"
    assert style.bilingual_order == "target_source"
    assert style.prefer_single_line is True
    assert "Microsoft YaHei" in style.font_fallbacks
    assert report["summary"]["renderer"] == "presentation"
    assert report["summary"]["fonts"]["target"].startswith("Noto Sans SC")
    assert report["summary"]["status"] == "PASS"


def test_delivery_report_summarizes_line_layout() -> None:
    report = subtitle_delivery_report(
        [
            Segment(id=1, start=0.0, end=1.0, text_src="short", text_tgt="短句"),
            Segment(id=2, start=1.2, end=3.2, text_src="longer", text_tgt="今天晚上我想让你慢慢放松下来"),
        ],
        output_format="srt",
        bilingual=False,
        style=AssStyleConfig(target_max_width=20, hard_max_width=20, prefer_single_line=False),
    )

    target_layout = report["summary"]["line_layout"]["target"]
    assert target_layout["one_line"] == 1
    assert target_layout["two_lines"] == 1
    assert target_layout["over_two_lines"] == 0
    assert target_layout["awkward_breaks"] == 0
    assert report["segments"][1]["target_lines"] == 2


def test_ass_preset_keeps_user_overrides() -> None:
    style = resolve_ass_style(AssStyleConfig(preset="cinematic", font_name="Arial", font_size=52))

    assert style.preset == "cinematic"
    assert style.font_name == "Arial"
    assert style.font_size == 52
    assert style.primary_color == "&H00F6F1EA"


def test_ass_prefer_single_line_uses_hard_width_before_wrapping() -> None:
    target = "这是一条长度适中的中文字幕，默认应该尽量保持单行。"
    segment = Segment(id=1, start=0.0, end=2.0, text_src="short source", text_tgt=target)

    prefer_plan = build_render_plan(
        [segment],
        output_format="ass",
        bilingual=False,
        style=AssStyleConfig(target_max_width=28, hard_max_width=64, prefer_single_line=True),
    )
    conservative_plan = build_render_plan(
        [segment],
        output_format="ass",
        bilingual=False,
        style=AssStyleConfig(target_max_width=28, hard_max_width=64, prefer_single_line=False),
    )

    assert prefer_plan.cues[0].target.lines == [target]
    assert len(conservative_plan.cues[0].target.lines) > 1


def test_delivery_report_flags_invalid_ass_style() -> None:
    report = subtitle_delivery_report(
        [Segment(id=1, start=0.0, end=1.0, text_src="Hello", text_tgt="你好")],
        output_format="ass",
        bilingual=False,
        style=AssStyleConfig(primary_color="white"),
    )

    assert report["summary"]["status"] == "FAIL"
    assert report["summary"]["issue_counts"]["invalid_ass_color"] == 1


def test_delivery_report_requires_eight_digit_ass_colors() -> None:
    report = subtitle_delivery_report(
        [Segment(id=1, start=0.0, end=1.0, text_src="Hello", text_tgt="你好")],
        output_format="ass",
        bilingual=False,
        style=AssStyleConfig(primary_color="&HFFFFFF"),
    )

    assert report["summary"]["status"] == "FAIL"
    assert report["summary"]["issue_counts"]["invalid_ass_color"] == 1


def test_export_vtt_writes_webvtt_without_bom_and_escapes_html(tmp_path: Path) -> None:
    out_file = tmp_path / "out.vtt"
    export_vtt(
        [
            Segment(
                id=1,
                start=0.0,
                end=1.2,
                text_src="Hello <world>",
                text_tgt="你好 & 再见",
            )
        ],
        out_file,
        bilingual=True,
    )

    body = out_file.read_text(encoding="utf-8")
    assert body.startswith("WEBVTT\n\n")
    assert "Kind: captions" not in body
    assert "Language: und" not in body
    assert not out_file.read_bytes().startswith(b"\xef\xbb\xbf")
    assert "00:00:00.000 --> 00:00:01.200" in body
    assert "Hello &lt;world&gt;" in body
    assert "你好 &amp; 再见" in body


def test_export_lrc_writes_lyrics_timestamps_and_single_line_text(tmp_path: Path) -> None:
    out_file = tmp_path / "out.lrc"
    export_lrc(
        [
            Segment(
                id=1,
                start=62.346,
                end=64.0,
                text_src="Hello\nworld",
                text_tgt="你好\n世界",
            ),
            Segment(id=2, start=65.0, end=66.0, text_src="Only source", text_tgt=""),
        ],
        out_file,
        bilingual=True,
    )

    body = out_file.read_text(encoding="utf-8")
    assert not out_file.read_bytes().startswith(b"\xef\xbb\xbf")
    assert "[01:02.35]你好 世界 / Hello world" in body
    assert "[01:05.00]Only source" in body
