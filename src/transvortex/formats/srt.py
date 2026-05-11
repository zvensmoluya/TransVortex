from __future__ import annotations

import re
from pathlib import Path

from ..app.models import Segment


SRT_TIME_RE = re.compile(
    r"(?P<start>\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*"
    r"(?P<end>\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})"
)


def parse_srt_time(value: str) -> float:
    normalized = value.strip().replace(",", ".")
    hh, mm, rest = normalized.split(":", 2)
    ss, ms = rest.split(".", 1)
    ms = (ms + "000")[:3]
    return int(hh) * 3600 + int(mm) * 60 + int(ss) + int(ms) / 1000


def parse_srt_text(text: str) -> list[Segment]:
    segments: list[Segment] = []
    normalized = text.replace("\ufeff", "").replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n\s*\n", normalized.strip())
    next_id = 1
    for block in blocks:
        lines = [line.rstrip() for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        time_index = next((idx for idx, line in enumerate(lines) if "-->" in line), -1)
        if time_index < 0:
            continue
        match = SRT_TIME_RE.search(lines[time_index])
        if not match:
            continue
        body = "\n".join(line.strip() for line in lines[time_index + 1 :] if line.strip()).strip()
        if not body:
            continue
        start = parse_srt_time(match.group("start"))
        end = parse_srt_time(match.group("end"))
        if end <= start:
            continue
        segments.append(Segment(id=next_id, start=start, end=end, text_src=body))
        next_id += 1
    return segments


def parse_srt_file(path: Path) -> list[Segment]:
    return parse_srt_text(path.read_text(encoding="utf-8-sig"))
