from __future__ import annotations

from pathlib import Path

from .models import AssStyleConfig, Segment
from .subtitle_quality import format_subtitle_lines, prepare_segments_for_export


def _srt_time(seconds: float) -> str:
    ms_total = int(round(max(seconds, 0) * 1000))
    h = ms_total // 3_600_000
    ms_total %= 3_600_000
    m = ms_total // 60_000
    ms_total %= 60_000
    s = ms_total // 1000
    ms = ms_total % 1000
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def export_srt(segments: list[Segment], output: Path, bilingual: bool) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    prepared_segments = prepare_segments_for_export(segments)
    for idx, seg in enumerate(prepared_segments, start=1):
        lines.append(str(idx))
        lines.append(f"{_srt_time(seg.start)} --> {_srt_time(seg.end)}")
        lines.extend(format_subtitle_lines(seg, bilingual=bilingual))
        lines.append("")
    output.write_text("\n".join(lines), encoding="utf-8")
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


def _ass_text(value: str) -> str:
    return value.replace("\\", r"\\").replace("{", r"\{").replace("}", r"\}").replace("\n", r"\N")


def _ass_dialogue_text(seg: Segment, *, bilingual: bool, style: AssStyleConfig) -> str:
    src = _ass_text(seg.text_src.strip())
    tgt = _ass_text((seg.text_tgt or "").strip())
    if not bilingual:
        return tgt or src
    if not tgt:
        return src
    if style.bilingual_order == "source_target":
        return f"{src}\\N{tgt}"
    return f"{tgt}\\N{src}"


def export_ass(
    segments: list[Segment],
    output: Path,
    *,
    bilingual: bool,
    style: AssStyleConfig | None = None,
) -> Path:
    style = style or AssStyleConfig()
    output.parent.mkdir(parents=True, exist_ok=True)
    prepared_segments = prepare_segments_for_export(segments)
    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        "WrapStyle: 2",
        "ScaledBorderAndShadow: yes",
        "PlayResX: 1920",
        "PlayResY: 1080",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        "Style: Default,"
        f"{style.font_name},{style.font_size},{style.primary_color},&H000000FF,{style.outline_color},{style.back_color},"
        f"0,0,0,0,100,100,0,0,1,{style.outline},{style.shadow},2,60,60,{style.margin_v},1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    for seg in prepared_segments:
        text = _ass_dialogue_text(seg, bilingual=bilingual, style=style)
        lines.append(f"Dialogue: 0,{_ass_time(seg.start)},{_ass_time(seg.end)},Default,,0,0,0,,{text}")
    output.write_text("\n".join(lines), encoding="utf-8-sig")
    return output
