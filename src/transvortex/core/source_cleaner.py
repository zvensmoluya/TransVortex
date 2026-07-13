from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, replace
from typing import Any

from ..app.models import Segment


_SPACE_RE = re.compile(r"\s+")
_TOKEN_SPLIT_RE = re.compile(r"[,，、/／|｜;；:：\n]+")
_PUNCT_ONLY_RE = re.compile(r"^[\W_]+$", re.UNICODE)
_WRAPPER_PAIRS = {
    "(": ")",
    "[": "]",
    "{": "}",
    "（": "）",
    "【": "】",
    "「": "」",
    "『": "』",
    "〈": "〉",
    "《": "》",
}
_EDGE_CHARS = " \t\r\n,，、.。!！?？…:：;；-—~〜～・"

_EN_SOUND_TERMS = {
    "applause",
    "breath",
    "breathing",
    "breathing sound",
    "clapping",
    "crosstalk",
    "footstep",
    "footsteps",
    "gasp",
    "gasps",
    "inaudible",
    "laugh",
    "laughs",
    "laughter",
    "music",
    "noise",
    "silence",
    "sigh",
    "sighs",
    "sound effect",
    "thunder",
    "whisper",
    "whispering",
}
_CJK_SOUND_TERMS = {
    "囁き声",
    "ささやき声",
    "吐息",
    "息遣い",
    "呼吸音",
    "呼吸声",
    "耳かき音",
    "耳掻き音",
    "耳かき",
    "耳掻き",
    "リップ音",
    "キス音",
    "咀嚼音",
    "タッピング音",
    "衣擦れ",
    "水音",
    "音楽",
    "拍手",
    "笑い声",
    "雑音",
    "無音",
    "聞き取れない",
    "悄悄话",
    "低语声",
    "呼吸声",
    "喘息声",
    "吐息声",
    "掏耳声",
    "采耳声",
    "耳搔声",
    "耳勺声",
    "舔舐声",
    "吸吮声",
    "亲吻声",
    "咀嚼声",
    "拟声词",
    "擬聲詞",
    "音效",
    "音乐",
    "掌声",
    "笑声",
    "杂音",
    "噪声",
    "静音",
    "听不清",
}
_NORMALIZED_SOUND_TERMS = {item.lower() for item in [*_EN_SOUND_TERMS, *_CJK_SOUND_TERMS]}
_CJK_SOUND_ROOTS = {
    "囁き",
    "ささやき",
    "吐息",
    "息遣い",
    "呼吸",
    "耳かき",
    "耳掻き",
    "掏耳",
    "采耳",
    "舔舐",
    "吸吮",
    "亲吻",
    "咀嚼",
    "リップ",
    "キス",
    "タッピング",
}
_CJK_SOUND_SUFFIXES = ("音", "声", "聲")
_SENTENCE_MARKERS = set("。.!！？?ですますました了吗呢吧か")


@dataclass(frozen=True)
class SourceTextClassification:
    action: str
    reasons: list[str]
    clean_text: str
    flags: list[str]


@dataclass(frozen=True)
class SourceCleaningResult:
    segments: list[Segment]
    report: dict[str, Any]


def normalize_source_text(value: str | None) -> str:
    text = str(value or "").replace("\u3000", " ")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [_SPACE_RE.sub(" ", line).strip() for line in text.split("\n")]
    return "\n".join(line for line in lines if line)


def _strip_wrappers(value: str) -> str:
    text = value.strip(_EDGE_CHARS)
    changed = True
    while changed and len(text) >= 2:
        changed = False
        for left, right in _WRAPPER_PAIRS.items():
            if text.startswith(left) and text.endswith(right):
                text = text[1:-1].strip(_EDGE_CHARS)
                changed = True
                break
    return text.strip(_EDGE_CHARS)


def _canonical_token(value: str) -> str:
    return _SPACE_RE.sub(" ", _strip_wrappers(value)).strip().lower()


def _split_tokens(text: str) -> list[str]:
    body = _strip_wrappers(text)
    tokens = [_canonical_token(item) for item in _TOKEN_SPLIT_RE.split(body)]
    return [item for item in tokens if item]


def _is_sound_token(token: str) -> bool:
    canonical = _canonical_token(token)
    if not canonical:
        return False
    if canonical in _NORMALIZED_SOUND_TERMS:
        return True
    if len(canonical) <= 16 and any(root.lower() in canonical for root in _CJK_SOUND_ROOTS):
        return any(suffix in canonical for suffix in _CJK_SOUND_SUFFIXES) or canonical in {"耳かき", "耳掻き"}
    return False


def _visible_len(text: str) -> int:
    return len(re.sub(r"\s+", "", text))


def _has_sentence_shape(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    if any(marker in stripped for marker in _SENTENCE_MARKERS):
        return True
    return bool(re.search(r"[A-Za-z]{3,}\s+[A-Za-z]{3,}\s+[A-Za-z]{3,}", stripped))


def _dominant_periodic_repetition(text: str) -> bool:
    compact = re.sub(r"[\s\W_]+", "", _strip_wrappers(text), flags=re.UNICODE)
    if len(compact) < 24:
        return False
    required_span = max(24, int(len(compact) * 0.6))
    max_unit = min(12, len(compact) // 6)
    for unit_len in range(1, max_unit + 1):
        for start in range(0, len(compact) - unit_len * 6 + 1):
            unit = compact[start : start + unit_len]
            cursor = start + unit_len
            repeats = 1
            while compact[cursor : cursor + unit_len] == unit:
                repeats += 1
                cursor += unit_len
            if repeats >= 6 and repeats * unit_len >= required_span:
                return True
    return False


def compact_periodic_repetition(text: str, *, visible_repeats: int = 4) -> str | None:
    """Build a bounded model/display form while preserving the source text."""
    clean_text = normalize_source_text(text)
    body = _strip_wrappers(clean_text)
    if len(body) < 24:
        return None
    required_span = max(24, int(len(body) * 0.6))
    best: tuple[int, int, str, int] | None = None
    max_unit = min(12, len(body) // 6)
    for unit_len in range(1, max_unit + 1):
        for start in range(0, len(body) - unit_len * 6 + 1):
            unit = body[start : start + unit_len]
            cursor = start + unit_len
            repeats = 1
            while body[cursor : cursor + unit_len] == unit:
                repeats += 1
                cursor += unit_len
            span = repeats * unit_len
            if repeats < 6 or span < required_span:
                continue
            candidate = (start, cursor, unit, repeats)
            if best is None or span > (best[1] - best[0]):
                best = candidate
    if best is None:
        return None
    start, end, unit, repeats = best
    bounded_count = min(max(2, int(visible_repeats)), repeats)
    suffix = body[end:]
    if suffix and len(suffix) < len(unit) and unit.startswith(suffix):
        suffix = ""
    compacted = f"{body[:start]}{unit * bounded_count}…{suffix}"
    return compacted if compacted != body else None


def source_text_for_model(segment: Segment) -> str:
    meta = segment.meta if isinstance(segment.meta, dict) else {}
    return str(meta.get("source_text_for_model") or segment.text_src or "")


def source_text_for_display(segment: Segment) -> str:
    meta = segment.meta if isinstance(segment.meta, dict) else {}
    return str(meta.get("source_text_for_display") or segment.text_src or "")


def classify_source_text(value: str | None) -> SourceTextClassification:
    clean_text = normalize_source_text(value)
    if not clean_text:
        return SourceTextClassification(action="drop", reasons=["empty_text"], clean_text="", flags=["empty"])
    body = _strip_wrappers(clean_text)
    if body and set(body) <= {"♪", "♫", "♬", " ", "\t", "\n"}:
        return SourceTextClassification(
            action="drop",
            reasons=["music_symbols"],
            clean_text=clean_text,
            flags=["sound_effect", "noise"],
        )
    if not body or _PUNCT_ONLY_RE.fullmatch(body):
        return SourceTextClassification(
            action="drop",
            reasons=["non_speech_symbols"],
            clean_text=clean_text,
            flags=["noise"],
        )

    tokens = _split_tokens(clean_text)
    if not tokens:
        tokens = [_canonical_token(body)]
    sound_tokens = [token for token in tokens if _is_sound_token(token)]
    token_counts = Counter(tokens)
    most_token, most_count = token_counts.most_common(1)[0]
    repeated_sound = _is_sound_token(most_token) and most_count >= 3
    sound_ratio = len(sound_tokens) / max(len(tokens), 1)

    reasons: list[str] = []
    flags: list[str] = []
    if repeated_sound:
        reasons.append("repeated_sound_effect")
    if sound_tokens and sound_ratio >= 1.0:
        reasons.append("sound_effect")
    elif len(sound_tokens) >= 2 and sound_ratio >= 0.66 and not _has_sentence_shape(clean_text):
        reasons.append("sound_effect_sequence")
    elif sound_tokens:
        reasons.append("mixed_sound_effect")

    if repeated_sound or any(reason in reasons for reason in ("sound_effect", "sound_effect_sequence")):
        flags.extend(["sound_effect", "noise"])
        return SourceTextClassification(action="drop", reasons=list(dict.fromkeys(reasons)), clean_text=clean_text, flags=flags)
    if "mixed_sound_effect" in reasons:
        flags.extend(["sound_effect", "suspicious"])
        return SourceTextClassification(action="warn", reasons=reasons, clean_text=clean_text, flags=flags)
    if _dominant_periodic_repetition(clean_text):
        return SourceTextClassification(
            action="warn",
            reasons=["periodic_repetition"],
            clean_text=clean_text,
            flags=["suspicious", "repetition"],
        )
    if most_count >= 6 and (_visible_len(most_token) * most_count) >= _visible_len(clean_text) * 0.7:
        return SourceTextClassification(
            action="warn",
            reasons=["repeated_phrase"],
            clean_text=clean_text,
            flags=["suspicious"],
        )
    return SourceTextClassification(action="keep", reasons=[], clean_text=clean_text, flags=[])


def _is_asr_segment(segment: Segment) -> bool:
    meta = segment.meta if isinstance(segment.meta, dict) else {}
    return meta.get("source") == "asr" or "asr_window_index" in meta


def _report_row(segment: Segment, classification: SourceTextClassification) -> dict[str, Any]:
    return {
        "id": int(segment.id),
        "start": float(segment.start),
        "end": float(segment.end),
        "text_src": str(segment.text_src or ""),
        "reasons": list(classification.reasons),
        "flags": list(classification.flags),
    }


def clean_source_segments(
    segments: list[Segment],
    *,
    only_asr: bool = True,
    renumber: bool = True,
) -> SourceCleaningResult:
    output: list[Segment] = []
    dropped: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    reason_counts: Counter[str] = Counter()
    action_counts: Counter[str] = Counter()

    for segment in segments:
        if only_asr and not _is_asr_segment(segment):
            output.append(segment)
            action_counts["skipped_non_asr"] += 1
            continue
        classification = classify_source_text(segment.text_src)
        action_counts[classification.action] += 1
        reason_counts.update(classification.reasons)
        if classification.action == "drop":
            dropped.append(_report_row(segment, classification))
            continue
        meta = dict(segment.meta or {})
        if classification.action == "warn":
            existing = list(meta.get("source_cleaning_warnings") or [])
            meta["source_cleaning_warnings"] = list(dict.fromkeys([*existing, *classification.reasons]))
            if "periodic_repetition" in classification.reasons:
                compacted = compact_periodic_repetition(classification.clean_text)
                if compacted:
                    meta["source_text_for_model"] = compacted
                    meta["source_text_for_display"] = compacted
                    meta["source_text_compaction"] = {
                        "reason": "periodic_repetition",
                        "original_length": len(classification.clean_text),
                        "compacted_length": len(compacted),
                    }
            warnings.append(_report_row(segment, classification))
        output.append(replace(segment, text_src=classification.clean_text, meta=meta))

    if renumber:
        renumbered: list[Segment] = []
        for new_id, segment in enumerate(output, start=1):
            if int(segment.id) == new_id:
                renumbered.append(segment)
                continue
            meta = dict(segment.meta or {})
            meta.setdefault("source_cleaning_original_id", int(segment.id))
            renumbered.append(replace(segment, id=new_id, meta=meta))
        output = renumbered

    report = {
        "version": 1,
        "mode": "asr_only" if only_asr else "all_sources",
        "input_segments": len(segments),
        "output_segments": len(output),
        "dropped_segments": len(dropped),
        "warning_segments": len(warnings),
        "action_counts": dict(sorted(action_counts.items())),
        "reason_counts": dict(sorted(reason_counts.items())),
        "dropped": dropped,
        "warnings": warnings,
    }
    return SourceCleaningResult(segments=output, report=report)
