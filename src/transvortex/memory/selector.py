from __future__ import annotations

import re
from dataclasses import dataclass

from ..app.models import Chunk, MemoryInjectConfig
from .schema import MEMORY_STATUS_ORDER, MemoryDocument, MemoryEntry, entry_alias_details


@dataclass
class MemoryFormMatch:
    form: str
    kind: str
    zone: str
    resolved_target: str = ""
    policy: str = "recognize_only"
    has_target_variant: bool = False
    target_role: str = "target"
    target_variant_status: str = "none"
    variant_notes: str = ""


@dataclass
class SelectedMemoryEntry:
    entry: MemoryEntry
    matches: list[MemoryFormMatch]
    score: int

    @property
    def source(self) -> str:
        return self.entry.source

    @property
    def target(self) -> str:
        return self.entry.target


GENERIC_FORMS = {
    "ここ",
    "そこ",
    "あそこ",
    "これ",
    "それ",
    "あれ",
    "この塔",
    "その塔",
    "あの塔",
    "この場所",
    "その場所",
    "彼",
    "彼女",
    "this place",
    "that place",
    "this tower",
    "that tower",
    "here",
    "there",
}

STATUS_SCORE = {"locked": 1000, "confirmed": 700, "proposed": 120}
CONSTRAINT_SCORE = {"must_use": 400, "preferred": 180, "hint": 30}
ZONE_SCORE = {"lines": 1.0, "context_before": 0.45, "context_after": 0.35}
KIND_SCORE = {
    "source": 320,
    "nickname": 340,
    "honorific": 340,
    "asr_error": 280,
    "spelling": 240,
    "full_name": 240,
    "phrase_fragment": 60,
    "broad_hint": 40,
}
ADDRESS_ALIAS_KINDS = {"nickname", "honorific"}


def _entry_terms(entry: MemoryEntry) -> list[tuple[str, str, bool]]:
    terms: list[tuple[str, str, bool]] = []
    if entry.source.strip():
        terms.append((entry.source, "source", False))
    for alias in entry_alias_details(entry):
        terms.append((alias.source, alias.kind, False))
    for variant in entry.target_variants:
        terms.append((variant.source, variant.kind, True))
    return [term for term in terms if term[0].strip()]


def _translation_policy(
    entry: MemoryEntry,
    *,
    kind: str = "",
    has_target_variant: bool = False,
    target_variant_status: str = "none",
    zone: str = "",
) -> str:
    if kind in ADDRESS_ALIAS_KINDS:
        if target_variant_status == "missing":
            return "style_sensitive_unresolved"
        return "style_sensitive"
    if has_target_variant:
        return "style_sensitive"
    explicit = entry.enforcement_policy.get("translation") if isinstance(entry.enforcement_policy, dict) else ""
    if explicit:
        return str(explicit)
    if kind in {"phrase_fragment", "broad_hint"} or entry.memory_type == "concept_hint":
        return "context_only"
    if kind == "asr_error":
        return "recognize_only"
    if entry.constraint == "must_use" or entry.status == "locked":
        return "exact"
    if entry.constraint == "preferred" or entry.status == "confirmed":
        return "preferred"
    return "recognize_only"


def _variant_for_form(entry: MemoryEntry, form: str):
    for variant in entry.target_variants:
        if variant.source == form:
            return variant
    return None


def _resolved_target(entry: MemoryEntry, form: str, kind: str, has_variant: bool) -> tuple[str, bool, str, str, str]:
    variant = _variant_for_form(entry, form)
    if variant is not None and variant.target:
        return variant.target, True, "target", "matched", variant.notes
    if kind in ADDRESS_ALIAS_KINDS:
        return entry.target, False, "canonical_target", "missing", ""
    return entry.target, bool(has_variant), "target", "none", ""


def is_generic_form(term: str) -> bool:
    return " ".join(str(term or "").strip().casefold().split()) in GENERIC_FORMS


def term_matches_text(term: str, text: str) -> bool:
    term = term.strip()
    if not term or is_generic_form(term):
        return False
    if len(term) <= 2 and term.isascii() and term.isalnum():
        return False
    if not term.isascii():
        if len(term) <= 1:
            return False
        return term.casefold() in text.casefold()
    pattern = re.compile(rf"(?<![\w]){re.escape(term)}(?![\w])", re.IGNORECASE)
    return bool(pattern.search(text))


def entry_matches_text(entry: MemoryEntry, text: str) -> bool:
    return any(term_matches_text(term, text) for term, _kind, _has_variant in _entry_terms(entry))


def _allowed_statuses(inject_config: MemoryInjectConfig) -> set[str]:
    allowed = set()
    if inject_config.locked:
        allowed.add("locked")
    if inject_config.confirmed:
        allowed.add("confirmed")
    if inject_config.proposed:
        allowed.add("proposed")
    return allowed


def _normalized_intensity(value: str) -> str:
    value = str(value or "high").strip().lower()
    return value if value in {"none", "low", "auto", "high", "max"} else "high"


def _is_weak_match(match: MemoryFormMatch) -> bool:
    return match.policy == "context_only" or match.kind in {"phrase_fragment", "broad_hint"}


def _is_strong_background(entry: MemoryEntry) -> bool:
    return entry.status in {"locked", "confirmed"} or entry.constraint in {"must_use", "preferred"}


def _chunk_zones(chunk: Chunk) -> dict[str, str]:
    return {
        "lines": "\n".join(chunk.lines),
        "context_before": "\n".join(chunk.context_before),
        "context_after": "\n".join(chunk.context_after),
    }


def _entry_matches(entry: MemoryEntry, chunk: Chunk) -> list[MemoryFormMatch]:
    matches: list[MemoryFormMatch] = []
    seen: set[tuple[str, str, str]] = set()
    for zone, text in _chunk_zones(chunk).items():
        if not text:
            continue
        for term, kind, has_variant in _entry_terms(entry):
            if not term_matches_text(term, text):
                continue
            target, variant_found, target_role, variant_status, variant_notes = _resolved_target(entry, term, kind, has_variant)
            key = (term, kind, zone)
            if key in seen:
                continue
            seen.add(key)
            matches.append(
                MemoryFormMatch(
                    form=term,
                    kind=kind,
                    zone=zone,
                    resolved_target=target,
                    policy=_translation_policy(
                        entry,
                        kind=kind,
                        has_target_variant=variant_found,
                        target_variant_status=variant_status,
                        zone=zone,
                    ),
                    has_target_variant=variant_found,
                    target_role=target_role,
                    target_variant_status=variant_status,
                    variant_notes=variant_notes,
                )
            )
    return matches


def _entry_match_score(entry: MemoryEntry, chunk: Chunk) -> int:
    score = STATUS_SCORE.get(entry.status, 0)
    score += CONSTRAINT_SCORE.get(entry.constraint, 0)
    score += int(entry.priority)
    score += int(float(entry.confidence or 0.0) * 100)
    for zone, text in _chunk_zones(chunk).items():
        if not text:
            continue
        zone_weight = ZONE_SCORE.get(zone, 0.0)
        for term, kind, has_variant in _entry_terms(entry):
            if is_generic_form(term):
                score -= 260
                continue
            if not term_matches_text(term, text):
                continue
            score += int(KIND_SCORE.get(kind, KIND_SCORE["source"]) * zone_weight)
            if has_variant:
                score += int(120 * zone_weight)
            if kind == "asr_error":
                score += int(60 * zone_weight)
            if kind in {"broad_hint", "phrase_fragment"}:
                score -= int(60 * (1.0 - zone_weight))
    if entry.memory_type == "concept_hint":
        score -= 40
    return score


def _should_include_entry(
    entry: MemoryEntry,
    *,
    matches: list[MemoryFormMatch],
    intensity: str,
) -> bool:
    if intensity == "none":
        return False
    if intensity == "low":
        return any(match.zone == "lines" and not _is_weak_match(match) for match in matches)
    if matches:
        return True
    if intensity in {"auto", "high", "max"} and _is_strong_background(entry):
        return True
    return False


def select_memory_entries(
    document: MemoryDocument,
    chunk: Chunk,
    inject_config: MemoryInjectConfig,
) -> list[SelectedMemoryEntry]:
    intensity = _normalized_intensity(inject_config.intensity)
    if intensity == "none":
        return []
    allowed = _allowed_statuses(inject_config)
    selected: list[SelectedMemoryEntry] = []
    for entry in document.entries:
        if entry.status not in allowed or not entry.source.strip():
            continue
        entry_matches = _entry_matches(entry, chunk)
        if not _should_include_entry(
            entry,
            matches=entry_matches,
            intensity=intensity,
        ):
            continue
        selected.append(SelectedMemoryEntry(entry=entry, matches=entry_matches, score=_entry_match_score(entry, chunk)))
    selected.sort(
        key=lambda selected_entry: (
            -selected_entry.score,
            MEMORY_STATUS_ORDER.get(selected_entry.entry.status, 99),
            -int(selected_entry.entry.priority),
            -float(selected_entry.entry.confidence),
            selected_entry.entry.source.casefold(),
        )
    )
    return selected
