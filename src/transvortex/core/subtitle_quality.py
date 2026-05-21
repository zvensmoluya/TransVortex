from __future__ import annotations

import re
import unicodedata
from dataclasses import replace

from ..app.models import Segment


_INLINE_SPACE_RE = re.compile(r"[ \t\f\v]+")
_NO_LINE_START_CHARS = set("，。！？；：、,.!?;:)]}）】〕〉》」』”’")


def clean_subtitle_text(value: str | None) -> str:
    if not value:
        return ""
    text = str(value).replace("\r\n", "\n").replace("\r", "\n")
    lines: list[str] = []
    for raw_line in text.split("\n"):
        line = _INLINE_SPACE_RE.sub(" ", raw_line).strip()
        if line:
            lines.append(line)
    return "\n".join(lines)


def _char_width(ch: str) -> int:
    return 2 if unicodedata.east_asian_width(ch) in {"F", "W"} else 1


def visual_width(text: str) -> int:
    return sum(_char_width(ch) for ch in text)


def subtitle_line_width(text: str) -> int:
    return visual_width(text.rstrip("".join(_NO_LINE_START_CHARS)))


def _split_by_visual_width(text: str, max_width: int) -> list[str]:
    if max_width <= 0:
        return [text]
    lines: list[str] = []
    buf: list[str] = []
    width = 0
    for ch in text:
        ch_width = _char_width(ch)
        if buf and width + ch_width > max_width:
            if ch in _NO_LINE_START_CHARS:
                buf.append(ch)
                width += ch_width
                continue
            lines.append("".join(buf).strip())
            buf = []
            width = 0
        buf.append(ch)
        width += ch_width
    if buf:
        lines.append("".join(buf).strip())
    return [line for line in lines if line]


def _wrap_words(line: str, max_width: int) -> list[str]:
    lines: list[str] = []
    current = ""
    for word in line.split(" "):
        if not word:
            continue
        if visual_width(word) > max_width:
            if current:
                lines.append(current)
                current = ""
            lines.extend(_split_by_visual_width(word, max_width))
            continue
        candidate = word if not current else f"{current} {word}"
        if visual_width(candidate) <= max_width:
            current = candidate
            continue
        if current:
            lines.append(current)
        current = word
    if current:
        lines.append(current)
    return lines


def wrap_subtitle_text(text: str | None, *, max_line_width: int = 42) -> list[str]:
    cleaned = clean_subtitle_text(text)
    if not cleaned:
        return []
    wrapped: list[str] = []
    for line in cleaned.splitlines():
        if visual_width(line) <= max_line_width:
            wrapped.append(line)
        elif " " in line:
            wrapped.extend(_wrap_words(line, max_line_width))
        else:
            wrapped.extend(_split_by_visual_width(line, max_line_width))
    return wrapped


def format_subtitle_lines(
    segment: Segment,
    *,
    bilingual: bool,
    max_line_width: int = 42,
    source_first: bool = True,
) -> list[str]:
    source_lines = wrap_subtitle_text(segment.text_src, max_line_width=max_line_width)
    target_lines = wrap_subtitle_text(segment.text_tgt, max_line_width=max_line_width)
    if not bilingual:
        return target_lines
    return source_lines + target_lines if source_first else target_lines + source_lines


def prepare_segments_for_export(
    segments: list[Segment],
    *,
    min_gap_seconds: float = 0.001,
    min_duration_seconds: float = 0.35,
) -> list[Segment]:
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    prepared: list[Segment] = []
    previous_end = 0.0
    for index, seg in enumerate(ordered):
        start = max(0.0, float(seg.start))
        if prepared and start < previous_end + min_gap_seconds:
            start = previous_end + min_gap_seconds

        end = max(float(seg.end), start + min_duration_seconds)
        if index + 1 < len(ordered):
            next_start = max(0.0, float(ordered[index + 1].start))
            cap = next_start - min_gap_seconds
            if start < cap < end:
                end = cap
        if end <= start:
            end = start + min_duration_seconds

        prepared.append(replace(seg, start=start, end=end))
        previous_end = end
    return prepared
