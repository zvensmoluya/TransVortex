from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..app.models import Segment
from ..core.source_cleaner import classify_source_text, source_text_for_model
from ..utils import write_json


_PUNCT_ONLY_RE = re.compile(r"^[\W_]+$", re.UNICODE)
_LEADING_FILLER_RE = re.compile(r"^(?:(?:uh+|um+|er+|ah+|hmm+|mm+|mhm+)[,\s.?!-]+)+", re.IGNORECASE)
_FILLER_TOKEN_RE = re.compile(r"\b(?:uh+|um+|er+|ah+|hmm+|mm+|mhm+)\b", re.IGNORECASE)
_REPEATED_PUNCT_RE = re.compile(r"([!?。！？,，.])\1{2,}")
_ASCII_TERM_RE = re.compile(r"\b(?:[A-Z][a-z]+(?:[-'][A-Z]?[a-z]+)*|[A-Z]{2,})\b")
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]{2,}")
_GENERIC_RECURRING_WORDS = {
    "the",
    "and",
    "that",
    "this",
    "you",
    "your",
    "are",
    "was",
    "were",
    "for",
    "with",
    "not",
    "but",
    "have",
    "has",
    "had",
    "what",
    "when",
    "where",
    "why",
    "how",
}


@dataclass
class BootstrapInputLine:
    id: int
    start: float
    end: float
    duration: float
    gap_before: float | None
    raw: str
    clean: str
    flags: list[str] = field(default_factory=list)
    confidence: float | None = None


@dataclass
class BootstrapInputView:
    version: int
    kind: str
    stats: dict[str, Any]
    lines: list[BootstrapInputLine]


def _format_seconds(value: float) -> str:
    total_ms = max(0, int(round(value * 1000)))
    ms = total_ms % 1000
    total_seconds = total_ms // 1000
    seconds = total_seconds % 60
    total_minutes = total_seconds // 60
    minutes = total_minutes % 60
    hours = total_minutes // 60
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{ms:03d}"
    return f"{minutes:02d}:{seconds:02d}.{ms:03d}"


def _normalize_text(text: str) -> str:
    normalized = str(text or "").replace("\u3000", " ")
    normalized = re.sub(r"\s+", " ", normalized).strip()
    normalized = _REPEATED_PUNCT_RE.sub(r"\1\1", normalized)
    return normalized


def _clean_text(raw: str, *, is_sound_effect: bool) -> str:
    text = _normalize_text(raw)
    if is_sound_effect:
        return ""
    text = _LEADING_FILLER_RE.sub("", text).strip()
    return text


def _is_low_info_text(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    lowered = stripped.lower()
    if len(stripped) <= 2:
        return True
    if _PUNCT_ONLY_RE.match(stripped):
        return True
    words = [item for item in re.split(r"[\s,，.?!。！？-]+", lowered) if item]
    if words and all(_FILLER_TOKEN_RE.fullmatch(item) for item in words):
        return True
    if len(words) == 1 and words[0] in {"yeah", "yep", "yes", "no", "ok", "okay", "hey"}:
        return True
    return False


def _text_density(text: str, duration_seconds: float) -> float:
    duration = max(duration_seconds, 0.01)
    visible = re.sub(r"\s+", "", text)
    return len(visible) / duration


def _recurring_terms(segments: list[Segment]) -> set[str]:
    counter: Counter[str] = Counter()
    for segment in segments:
        for match in _WORD_RE.findall(source_text_for_model(segment)):
            word = match.strip("'").lower()
            if word and word not in _GENERIC_RECURRING_WORDS:
                counter[word] += 1
    return {word for word, count in counter.items() if count >= 3}


def build_bootstrap_input_view(segments: list[Segment]) -> BootstrapInputView:
    recurring_terms = _recurring_terms(segments)
    seen_clean: Counter[str] = Counter()
    rows: list[BootstrapInputLine] = []
    flag_counts: Counter[str] = Counter()
    previous_end: float | None = None
    for segment in segments:
        raw = _normalize_text(segment.text_src)
        model_text = _normalize_text(source_text_for_model(segment))
        duration = max(0.0, float(segment.end) - float(segment.start))
        gap_before = None if previous_end is None else max(0.0, float(segment.start) - previous_end)
        previous_end = float(segment.end)
        source_classification = classify_source_text(raw)
        is_sound_effect = "sound_effect" in source_classification.flags and source_classification.action == "drop"
        clean = _clean_text(raw, is_sound_effect=is_sound_effect)
        flags: list[str] = []
        if model_text != raw:
            clean = model_text
            flags.append("periodic_repetition_compacted")
        if gap_before is not None and gap_before >= 2.0:
            flags.append("scene_gap")
        if is_sound_effect:
            flags.extend(["sound_effect", "noise"])
        if not raw:
            flags.append("empty")
        if _FILLER_TOKEN_RE.search(raw):
            flags.append("filler")
        if _is_low_info_text(clean):
            flags.append("low_info")
        try:
            if segment.confidence is not None and float(segment.confidence) < -1.0:
                flags.append("low_confidence")
        except (TypeError, ValueError):
            pass
        if duration < 0.4 and len(raw) >= 8:
            flags.append("short_duration")
        if duration > 0.0 and _text_density(raw, duration) > 24:
            flags.append("dense_asr")
        if any(item in flags for item in ("low_confidence", "short_duration", "dense_asr")):
            flags.append("uncertain")
        if _ASCII_TERM_RE.search(raw) or any(word.lower() in recurring_terms for word in _WORD_RE.findall(raw)):
            flags.append("possible_term")
        duplicate_key = clean.lower()
        if duplicate_key:
            seen_clean[duplicate_key] += 1
            if seen_clean[duplicate_key] > 1:
                flags.append("duplicate")
        if not flags:
            flags.append("normal")
        deduped_flags = list(dict.fromkeys(flags))
        flag_counts.update(deduped_flags)
        rows.append(
            BootstrapInputLine(
                id=int(segment.id),
                start=float(segment.start),
                end=float(segment.end),
                duration=round(duration, 3),
                gap_before=None if gap_before is None else round(gap_before, 3),
                raw=raw,
                clean=clean,
                flags=deduped_flags,
                confidence=segment.confidence,
            )
        )
    return BootstrapInputView(
        version=1,
        kind="memory_bootstrap_input",
        stats={
            "segments": len(rows),
            "flag_counts": dict(sorted(flag_counts.items())),
            "soft_cleaning": True,
        },
        lines=rows,
    )


def render_bootstrap_input_text(view: BootstrapInputView) -> str:
    rendered: list[str] = []
    for line in view.lines:
        parts = [
            str(line.id),
            _format_seconds(line.start),
            f"dur={line.duration:.3f}",
        ]
        if line.gap_before is not None:
            parts.append(f"gap={line.gap_before:.3f}")
        if line.confidence is not None:
            try:
                parts.append(f"conf={float(line.confidence):.3f}")
            except (TypeError, ValueError):
                parts.append(f"conf={line.confidence}")
        parts.append("flags=" + ",".join(line.flags))
        rendered_raw = line.clean if "periodic_repetition_compacted" in line.flags else line.raw
        rendered.append(f"[{' | '.join(parts)}]\nraw: {rendered_raw}\nclean: {line.clean}")
    return "\n\n".join(rendered)


def write_bootstrap_input_artifacts(memory_dir: Path, view: BootstrapInputView, rendered_text: str) -> None:
    write_json(memory_dir / "bootstrap_input.json", view)
    text_path = memory_dir / "bootstrap_input.txt"
    text_path.parent.mkdir(parents=True, exist_ok=True)
    text_path.write_text(rendered_text, encoding="utf-8")
