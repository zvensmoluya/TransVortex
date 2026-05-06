from __future__ import annotations

from pathlib import Path

from .models import Segment
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
