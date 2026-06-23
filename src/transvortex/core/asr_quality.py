from __future__ import annotations

import re
from collections import Counter
from dataclasses import replace
from typing import Any

from ..app.models import Segment
from .subtitle_quality import clean_subtitle_text


_SENTENCE_END_RE = re.compile(r"[。.!！？?]+")
_LEVEL_RANK = {"info": 0, "warn": 1, "error": 2}


def _visible_text_length(value: str) -> int:
    return len(re.sub(r"\s+", "", value or ""))


def _is_asr_segment(segment: Segment) -> bool:
    meta = segment.meta if isinstance(segment.meta, dict) else {}
    return meta.get("source") == "asr" or "asr_window_index" in meta


def _risk_level(codes: list[str]) -> str:
    if any(code in {"missing_segment_timestamps"} for code in codes):
        return "error"
    if any(code == "long_duration_error" for code in codes):
        return "error"
    if any(code == "dense_text_error" for code in codes):
        return "error"
    if any(code in {"long_duration", "long_text", "multiple_sentence_endings", "dense_text", "overlap_next"} for code in codes):
        return "warn"
    return "info"


def _public_codes(codes: list[str]) -> list[str]:
    out: list[str] = []
    for code in codes:
        public = {
            "long_duration_error": "long_duration",
            "dense_text_error": "dense_text",
        }.get(code, code)
        if public not in out:
            out.append(public)
    return out


def _suggested_action(codes: list[str]) -> str:
    public = set(_public_codes(codes))
    if "missing_segment_timestamps" in public:
        return "retry_with_timestamp_segments"
    if public & {"long_duration", "multiple_sentence_endings", "dense_text", "long_text"}:
        return "retry_with_shorter_window"
    if public & {"overlap_next", "tiny_gap_to_next"}:
        return "review_boundary"
    return "review_asr_segment"


def _risk_for_segment(segment: Segment, next_segment: Segment | None) -> dict[str, Any] | None:
    text = clean_subtitle_text(segment.text_src)
    duration = max(float(segment.end) - float(segment.start), 0.0)
    text_length = _visible_text_length(text)
    source_cps = text_length / max(duration, 0.001)
    sentence_endings = len(_SENTENCE_END_RE.findall(text))
    gap_to_next = None
    if next_segment is not None:
        gap_to_next = float(next_segment.start) - float(segment.end)

    raw_codes: list[str] = []
    meta = segment.meta if isinstance(segment.meta, dict) else {}
    if meta.get("warning") == "missing_segment_timestamps":
        raw_codes.append("missing_segment_timestamps")
    if duration > 10.0:
        raw_codes.append("long_duration_error")
    elif duration > 6.0:
        raw_codes.append("long_duration")
    if text_length > 80:
        raw_codes.append("long_text")
    if sentence_endings > 2:
        raw_codes.append("multiple_sentence_endings")
    if source_cps > 26.0:
        raw_codes.append("dense_text_error")
    elif source_cps > 18.0:
        raw_codes.append("dense_text")
    if gap_to_next is not None:
        if gap_to_next < -0.001:
            raw_codes.append("overlap_next")
        elif gap_to_next < 0.08:
            raw_codes.append("tiny_gap_to_next")

    if not raw_codes:
        return None

    public_codes = _public_codes(raw_codes)
    level = _risk_level(raw_codes)
    return {
        "level": level,
        "codes": public_codes,
        "retryable": level in {"warn", "error"},
        "suggested_action": _suggested_action(raw_codes),
        "metrics": {
            "duration": round(duration, 3),
            "text_length": text_length,
            "source_cps": round(source_cps, 3),
            "sentence_endings": sentence_endings,
            "gap_to_next": None if gap_to_next is None else round(gap_to_next, 3),
        },
    }


def _provider_payload(provider: Any | None) -> dict[str, Any]:
    if provider is None:
        return {"name": "", "protocol": "", "model": ""}
    return {
        "name": str(getattr(provider, "name", "") or ""),
        "protocol": str(getattr(provider, "protocol", "") or ""),
        "model": str(getattr(provider, "model", "") or ""),
    }


def _top_risk_rows(segments: list[Segment], *, limit: int = 20) -> list[dict[str, Any]]:
    risky = []
    for seg in segments:
        risk = seg.meta.get("asr_risk") if isinstance(seg.meta, dict) else None
        if not isinstance(risk, dict):
            continue
        metrics = risk.get("metrics") if isinstance(risk.get("metrics"), dict) else {}
        risky.append(
            {
                "id": int(seg.id),
                "start": float(seg.start),
                "end": float(seg.end),
                "level": str(risk.get("level") or ""),
                "codes": list(risk.get("codes") or []),
                "suggested_action": str(risk.get("suggested_action") or ""),
                "text_preview": clean_subtitle_text(seg.text_src)[:120],
                "metrics": metrics,
            }
        )
    risky.sort(
        key=lambda row: (
            -_LEVEL_RANK.get(str(row.get("level") or ""), 0),
            -len(row.get("codes") or []),
            -float((row.get("metrics") or {}).get("duration") or 0.0),
            int(row.get("id") or 0),
        )
    )
    return risky[:limit]


def detect_asr_boundary_risks(
    segments: list[Segment],
    *,
    provider: Any | None = None,
) -> tuple[list[Segment], dict[str, Any]]:
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    out: list[Segment] = []
    asr_count = 0
    for idx, segment in enumerate(ordered):
        if not _is_asr_segment(segment):
            out.append(segment)
            continue
        asr_count += 1
        next_segment = None
        for candidate in ordered[idx + 1 :]:
            if _is_asr_segment(candidate):
                next_segment = candidate
                break
        risk = _risk_for_segment(segment, next_segment)
        if risk is None:
            out.append(segment)
            continue
        meta = dict(segment.meta or {})
        meta["asr_risk"] = risk
        out.append(replace(segment, meta=meta))

    risks = [
        seg.meta.get("asr_risk")
        for seg in out
        if isinstance(seg.meta, dict) and isinstance(seg.meta.get("asr_risk"), dict)
    ]
    code_counts: Counter[str] = Counter()
    level_counts: Counter[str] = Counter()
    for risk in risks:
        level_counts[str(risk.get("level") or "")] += 1
        code_counts.update(str(code) for code in risk.get("codes") or [])
    report = {
        "version": 1,
        "provider": _provider_payload(provider),
        "total_asr_segments": asr_count,
        "risk_segments": len(risks),
        "code_counts": dict(sorted(code_counts.items())),
        "level_counts": dict(sorted(level_counts.items())),
        "top_risks": _top_risk_rows(out),
    }
    return out, report


def asr_risk_level(segment: Segment) -> str:
    risk = segment.meta.get("asr_risk") if isinstance(segment.meta, dict) else None
    if not isinstance(risk, dict):
        return ""
    return str(risk.get("level") or "")


def has_high_asr_risk(segment: Segment) -> bool:
    return asr_risk_level(segment) in {"warn", "error"}


def has_error_asr_risk(segment: Segment) -> bool:
    return asr_risk_level(segment) == "error"
