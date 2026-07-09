from __future__ import annotations

from pathlib import Path

from ..app.models import AssStyleConfig, Segment
from ..core.subtitle_quality import clean_subtitle_text, prepare_segments_for_export
from .presentation import (
    ass_style_name,
    ass_text,
    build_render_plan,
    delivery_quality_report,
    format_font_stack_for_notes,
    plain_srt_lines,
    resolve_ass_style,
    vtt_text,
)


def _srt_time(seconds: float) -> str:
    ms_total = int(round(max(seconds, 0) * 1000))
    h = ms_total // 3_600_000
    ms_total %= 3_600_000
    m = ms_total // 60_000
    ms_total %= 60_000
    s = ms_total // 1000
    ms = ms_total % 1000
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def export_srt(
    segments: list[Segment],
    output: Path,
    bilingual: bool,
    *,
    style: AssStyleConfig | None = None,
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    prepared_segments = prepare_segments_for_export(segments)
    for idx, seg in enumerate(prepared_segments, start=1):
        lines.append(str(idx))
        lines.append(f"{_srt_time(seg.start)} --> {_srt_time(seg.end)}")
        lines.extend(plain_srt_lines(seg, bilingual=bilingual, style=style))
        lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8-sig")
    return output


def _ass_time(seconds: float) -> str:
    cs_total = int(round(max(seconds, 0) * 100))
    h = cs_total // 360_000
    cs_total %= 360_000
    m = cs_total // 6_000
    cs_total %= 6_000
    s = cs_total // 100
    cs = cs_total % 100
    return f"{h}:{m:02}:{s:02}.{cs:02}"


def _vtt_time(seconds: float) -> str:
    ms_total = int(round(max(seconds, 0) * 1000))
    h = ms_total // 3_600_000
    ms_total %= 3_600_000
    m = ms_total // 60_000
    ms_total %= 60_000
    s = ms_total // 1000
    ms = ms_total % 1000
    return f"{h:02}:{m:02}:{s:02}.{ms:03}"


def _lrc_time(seconds: float) -> str:
    cs_total = int(round(max(seconds, 0) * 100))
    minutes = cs_total // 6000
    cs_total %= 6000
    s = cs_total // 100
    cs = cs_total % 100
    return f"{minutes:02}:{s:02}.{cs:02}"


def _ass_float(value: float | int) -> str:
    number = float(value)
    return str(int(number)) if number.is_integer() else f"{number:.2f}".rstrip("0").rstrip(".")


def _ass_style_line(
    name: str,
    *,
    font_name: str,
    font_size: int,
    color: str,
    secondary_color: str,
    outline_color: str,
    back_color: str,
    bold: int,
    outline: float,
    shadow: float,
    border_style: int,
    margin_l: int,
    margin_r: int,
    margin_v: int,
) -> str:
    return (
        f"Style: {ass_style_name(name)},"
        f"{font_name},{font_size},{color},{secondary_color},{outline_color},{back_color},"
        f"{bold},0,0,0,100,100,0,0,{border_style},{_ass_float(outline)},{_ass_float(shadow)},"
        f"2,{margin_l},{margin_r},{margin_v},1"
    )


def _visual_margins(style: AssStyleConfig, *, bilingual: bool) -> tuple[int, int]:
    if not bilingual:
        return style.margin_v, style.margin_v
    target_height = int(round(style.font_size * style.line_spacing * max(1, style.max_target_lines)))
    source_height = int(round(style.source_font_size * style.line_spacing * max(1, style.max_source_lines)))
    if style.bilingual_order == "source_target":
        return style.margin_v, max(style.source_margin_v, style.margin_v + target_height + style.bilingual_gap)
    return max(style.source_margin_v, style.margin_v + source_height + style.bilingual_gap), style.margin_v


def _block_height(line_count: int, font_size: int, line_spacing: float) -> int:
    if line_count <= 0:
        return 0
    return int(round(line_count * max(1, font_size) * max(1.0, float(line_spacing))))


def _cue_visual_margins(cue, style: AssStyleConfig, *, bilingual: bool) -> tuple[int, int]:
    target_margin = style.margin_v
    source_margin = style.margin_v
    if not bilingual or cue.source is None:
        return target_margin, source_margin
    target_height = _block_height(len(cue.target.lines), style.font_size, style.line_spacing)
    source_height = _block_height(len(cue.source.lines), style.source_font_size, style.line_spacing)
    if style.bilingual_order == "source_target":
        source_margin = max(style.source_margin_v, target_margin + target_height + style.bilingual_gap)
    else:
        target_margin = max(style.source_margin_v, source_margin + source_height + style.bilingual_gap)
    return target_margin, source_margin


def export_ass(
    segments: list[Segment],
    output: Path,
    *,
    bilingual: bool,
    style: AssStyleConfig | None = None,
) -> Path:
    style = resolve_ass_style(style)
    target_margin_v, source_margin_v = _visual_margins(style, bilingual=bilingual)
    output.parent.mkdir(parents=True, exist_ok=True)
    prepared_segments = prepare_segments_for_export(segments)
    plan = build_render_plan(prepared_segments, output_format="ass", bilingual=bilingual, style=style)
    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        "WrapStyle: 2",
        "ScaledBorderAndShadow: yes",
        f"PlayResX: {plan.canvas.width}",
        f"PlayResY: {plan.canvas.height}",
        "YCbCr Matrix: TV.709",
        f"; TransVortex preset: {style.preset}",
        f"; Target font candidates: {format_font_stack_for_notes(style)}",
        f"; Source font candidates: {format_font_stack_for_notes(style, source=True)}",
        f"; Safe area: x={plan.canvas.safe_margin_x}, y={plan.canvas.safe_margin_y}",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        _ass_style_line(
            "Target",
            font_name=style.font_name,
            font_size=style.font_size,
            color=style.primary_color,
            secondary_color=style.secondary_color,
            outline_color=style.outline_color,
            back_color=style.back_color,
            bold=style.bold,
            outline=style.outline,
            shadow=style.shadow,
            border_style=style.border_style,
            margin_l=style.margin_l,
            margin_r=style.margin_r,
            margin_v=target_margin_v,
        ),
        _ass_style_line(
            "Source",
            font_name=style.source_font_name or style.font_name,
            font_size=style.source_font_size,
            color=style.source_primary_color,
            secondary_color=style.secondary_color,
            outline_color=style.source_outline_color,
            back_color=style.source_back_color,
            bold=style.source_bold,
            outline=style.source_outline,
            shadow=style.source_shadow,
            border_style=style.border_style,
            margin_l=style.margin_l,
            margin_r=style.margin_r,
            margin_v=source_margin_v,
        ),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    for cue in plan.cues:
        target = ass_text(cue.target.text)
        source = ass_text(cue.source.text) if cue.source else ""
        cue_target_margin_v, cue_source_margin_v = _cue_visual_margins(cue, style, bilingual=bilingual)
        if bilingual and style.bilingual_order == "source_target" and source:
            lines.append(f"Dialogue: 0,{_ass_time(cue.start)},{_ass_time(cue.end)},Source,,0,0,{cue_source_margin_v},,{source}")
            lines.append(f"Dialogue: 1,{_ass_time(cue.start)},{_ass_time(cue.end)},Target,,0,0,{cue_target_margin_v},,{target}")
        else:
            lines.append(f"Dialogue: 1,{_ass_time(cue.start)},{_ass_time(cue.end)},Target,,0,0,{cue_target_margin_v},,{target}")
            if bilingual and source:
                lines.append(f"Dialogue: 0,{_ass_time(cue.start)},{_ass_time(cue.end)},Source,,0,0,{cue_source_margin_v},,{source}")
    output.write_text("\n".join(lines), encoding="utf-8-sig")
    return output


def export_vtt(
    segments: list[Segment],
    output: Path,
    bilingual: bool,
    *,
    style: AssStyleConfig | None = None,
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    prepared_segments = prepare_segments_for_export(segments)
    lines = ["WEBVTT", "Kind: captions", "Language: und", ""]
    for idx, seg in enumerate(prepared_segments, start=1):
        lines.append(str(idx))
        lines.append(f"{_vtt_time(seg.start)} --> {_vtt_time(seg.end)} align:center position:50% line:90%")
        lines.extend(vtt_text(line) for line in plain_srt_lines(seg, bilingual=bilingual, style=style))
        lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")
    return output


def export_lrc(
    segments: list[Segment],
    output: Path,
    bilingual: bool,
    *,
    style: AssStyleConfig | None = None,
) -> Path:
    resolved = resolve_ass_style(style)
    output.parent.mkdir(parents=True, exist_ok=True)
    prepared_segments = prepare_segments_for_export(segments)
    lines: list[str] = []
    for segment in prepared_segments:
        target = _lrc_line_text(segment.text_tgt or segment.text_src)
        source = _lrc_line_text(segment.text_src)
        parts = [target]
        if bilingual and source and source != target:
            parts = [source, target] if resolved.bilingual_order == "source_target" else [target, source]
        text = " / ".join(part for part in parts if part)
        if text:
            lines.append(f"[{_lrc_time(segment.start)}]{text}")
    output.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return output


def _lrc_line_text(value: str | None) -> str:
    return " ".join(clean_subtitle_text(value).splitlines())


def subtitle_delivery_report(
    segments: list[Segment],
    *,
    output_format: str,
    bilingual: bool,
    style: AssStyleConfig | None = None,
) -> dict:
    normalized = str(output_format or "srt").lower()
    if normalized == "webvtt":
        normalized = "vtt"
    if normalized not in {"srt", "ass", "vtt"}:
        normalized = "srt"
    prepared_segments = prepare_segments_for_export(segments)
    plan = build_render_plan(prepared_segments, output_format=normalized, bilingual=bilingual, style=style)
    report = delivery_quality_report(plan)
    report["summary"]["renderer"] = {
        "srt": "compatibility",
        "ass": "presentation",
        "vtt": "web_html5",
    }[normalized]
    return report
