from __future__ import annotations

import re
import unicodedata
from dataclasses import replace

from ..app.models import Segment


_INLINE_SPACE_RE = re.compile(r"[ \t\f\v]+")
_NO_LINE_START_CHARS = set("，。！？；：、,.!?;:)]}）】〕〉》」』”’")
_NO_LINE_END_CHARS = set("([{（【〔〈《「『“‘")
_PREFERRED_LINE_END_CHARS = set("，。！？；：、,.!?;:")
_ASCII_WORD_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+#%&'-]*")


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


def _has_cjk_width(text: str) -> bool:
    return any(unicodedata.east_asian_width(ch) in {"F", "W"} for ch in text)


def _mixed_tokens(line: str) -> list[str]:
    tokens: list[str] = []
    idx = 0
    while idx < len(line):
        match = _ASCII_WORD_RE.match(line, idx)
        if match:
            tokens.append(match.group(0))
            idx = match.end()
            continue
        ch = line[idx]
        if ch.isspace():
            if not tokens or tokens[-1] != " ":
                tokens.append(" ")
        else:
            tokens.append(ch)
        idx += 1
    return tokens


def _wrap_mixed_line(line: str, max_width: int) -> list[str]:
    if max_width <= 0:
        return [line]
    lines: list[str] = []
    current = ""
    pending_space = False
    for token in _mixed_tokens(line):
        if token == " ":
            if current:
                pending_space = True
            continue
        prefix = " " if pending_space and current else ""
        candidate = f"{current}{prefix}{token}"
        if current and visual_width(candidate) > max_width:
            if token in _NO_LINE_START_CHARS:
                current = candidate
                pending_space = False
                continue
            lines.append(current.strip())
            current = token
            pending_space = False
            continue
        if not current and visual_width(token) > max_width:
            split = _split_by_visual_width(token, max_width)
            lines.extend(split[:-1])
            current = split[-1] if split else ""
            pending_space = False
            continue
        current = candidate
        pending_space = False
    if current.strip():
        lines.append(current.strip())
    return [item for item in lines if item]


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


def _balanced_two_line_split(line: str, max_width: int) -> list[str] | None:
    if max_width <= 0 or visual_width(line) > max_width * 2:
        return None
    best: tuple[float, str, str] | None = None
    for idx in range(1, len(line)):
        left = line[:idx].strip()
        right = line[idx:].strip()
        if not left or not right:
            continue
        if right[0] in _NO_LINE_START_CHARS or left[-1] in _NO_LINE_END_CHARS:
            continue
        if line[idx - 1].isalnum() and line[idx].isalnum():
            continue
        left_width = visual_width(left)
        right_width = visual_width(right)
        if left_width > max_width or right_width > max_width:
            continue
        score = abs(left_width - right_width)
        if left[-1] in _PREFERRED_LINE_END_CHARS:
            score -= 6
        if min(left_width, right_width) < max_width * 0.45:
            score += 10
        score += abs(idx - (len(line) / 2)) * 0.05
        if best is None or score < best[0]:
            best = (score, left, right)
    if best is None:
        return None
    return [best[1], best[2]]


def _rebalance_two_line_wrap(original: str, lines: list[str], max_width: int) -> list[str]:
    if len(lines) != 2 or not _has_cjk_width(original):
        return lines
    balanced = _balanced_two_line_split(original, max_width)
    return balanced or lines


def wrap_subtitle_text(text: str | None, *, max_line_width: int = 42) -> list[str]:
    cleaned = clean_subtitle_text(text)
    if not cleaned:
        return []
    wrapped: list[str] = []
    for line in cleaned.splitlines():
        if visual_width(line) <= max_line_width:
            wrapped.append(line)
        elif " " in line and not _has_cjk_width(line):
            wrapped.extend(_wrap_words(line, max_line_width))
        elif " " in line:
            wrapped.extend(_rebalance_two_line_wrap(line, _wrap_mixed_line(line, max_line_width), max_line_width))
        else:
            wrapped.extend(_rebalance_two_line_wrap(line, _split_by_visual_width(line, max_line_width), max_line_width))
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
