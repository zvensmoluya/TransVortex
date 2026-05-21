from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

from .schema import ALIAS_KINDS, MEMORY_CONSTRAINTS, MEMORY_TYPES
from .selector import is_generic_form


MemoryValidationMode = Literal["bootstrap", "patch"]

_WEAK_TRANSLATION_POLICIES = {"", "recognize_only", "context_only"}
_SOURCE_ONLY_BOOTSTRAP_TYPES = {"entity", "term", "phrase", "asr_correction", "concept_hint"}


@dataclass
class MemoryEvidence:
    source_by_id: dict[int, str] = field(default_factory=dict)
    target_by_id: dict[int, str] = field(default_factory=dict)


@dataclass
class MemoryValidationResult:
    payload: dict[str, Any]
    rejected: list[dict[str, Any]] = field(default_factory=list)


def _target_too_long(target: str) -> bool:
    target = str(target or "").strip()
    return bool(target and len(target) > 32)


def _float_value(value: Any) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _contains_text(haystack: str, needle: str) -> bool:
    haystack = str(haystack or "")
    needle = str(needle or "").strip()
    return bool(needle and needle in haystack)


def _evidence_text_by_ids(text_by_id: dict[int, str], evidence_ids: list[int]) -> str:
    return "\n".join(str(text_by_id.get(evidence_id) or "") for evidence_id in evidence_ids)


def _evidence_ids(row: dict[str, Any], evidence: MemoryEvidence | None) -> list[int]:
    ids: list[int] = []
    known = set(evidence.source_by_id) if evidence is not None else set()
    for item in row.get("evidence_ids", []) or []:
        try:
            evidence_id = int(item)
        except (TypeError, ValueError):
            continue
        if evidence is not None and evidence_id not in known:
            continue
        if evidence_id not in ids:
            ids.append(evidence_id)
    return ids


def _has_source_evidence(
    source: str,
    aliases: list[dict[str, Any]],
    variants: list[dict[str, Any]],
    evidence: MemoryEvidence | None,
    evidence_ids: list[int],
) -> bool:
    if evidence is None:
        return True
    forms = [source]
    forms.extend(str(item.get("source") or "").strip() for item in aliases)
    forms.extend(str(item.get("source") or "").strip() for item in variants)
    source_text = _evidence_text_by_ids(evidence.source_by_id, evidence_ids)
    return any(_contains_text(source_text, form) for form in forms)


def _has_target_evidence(
    target: str,
    variants: list[dict[str, Any]],
    evidence: MemoryEvidence | None,
    evidence_ids: list[int],
) -> bool:
    if evidence is None:
        return True
    forms = [target]
    forms.extend(str(item.get("target") or "").strip() for item in variants)
    forms = [form for form in forms if form]
    if not forms:
        return True
    target_text = _evidence_text_by_ids(evidence.target_by_id, evidence_ids)
    return any(_contains_text(target_text, form) for form in forms)


def _clean_alias_details(row: dict[str, Any]) -> list[dict[str, Any]]:
    aliases: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for item in row.get("alias_details", []) or []:
        if not isinstance(item, dict):
            continue
        source = str(item.get("source") or "").strip()
        kind = str(item.get("kind") or "spelling").strip().lower()
        if not source or is_generic_form(source) or kind not in ALIAS_KINDS:
            continue
        key = (" ".join(source.casefold().split()), kind)
        if key in seen:
            continue
        seen.add(key)
        aliases.append({"source": source, "kind": kind})
    return aliases


def _clean_legacy_aliases(row: dict[str, Any]) -> list[str]:
    aliases: list[str] = []
    for item in row.get("aliases", []) or []:
        source = str(item or "").strip()
        if source and not is_generic_form(source) and source not in aliases:
            aliases.append(source)
    return aliases


def _clean_target_variants(row: dict[str, Any]) -> list[dict[str, Any]]:
    variants: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for item in row.get("target_variants", []) or []:
        if not isinstance(item, dict):
            continue
        source = str(item.get("source") or "").strip()
        target = str(item.get("target") or "").strip()
        kind = str(item.get("kind") or "nickname").strip().lower()
        if not source or not target or is_generic_form(source) or _target_too_long(target):
            continue
        if kind not in ALIAS_KINDS:
            kind = "nickname"
        cleaned = {"source": source, "target": target, "kind": kind}
        try:
            cleaned["confidence"] = float(item.get("confidence") or 0.0)
        except (TypeError, ValueError):
            cleaned["confidence"] = 0.0
        if isinstance(item.get("speaker_scope"), dict):
            cleaned["speaker_scope"] = dict(item["speaker_scope"])
        if item.get("notes"):
            cleaned["notes"] = str(item.get("notes") or "")
        key = (" ".join(source.casefold().split()), target, kind)
        if key in seen:
            continue
        seen.add(key)
        variants.append(cleaned)
    return variants


def _translation_policy(row: dict[str, Any]) -> str:
    policy = row.get("enforcement_policy")
    if not isinstance(policy, dict):
        return ""
    return str(policy.get("translation") or "").strip().lower()


def _source_only_bootstrap_decision(row: dict[str, Any], evidence_ids: list[int]) -> tuple[bool, str]:
    memory_type = str(row.get("memory_type") or "").strip().lower()
    if memory_type == "concept_hint":
        return True, "concept_hint_allowed"
    if memory_type not in _SOURCE_ONLY_BOOTSTRAP_TYPES:
        return False, "unsupported_source_only_memory_type"
    if _translation_policy(row) not in _WEAK_TRANSLATION_POLICIES:
        return False, "source_only_requires_weak_policy"

    confidence = _float_value(row.get("confidence"))
    evidence_count = len(evidence_ids)
    has_note = bool(str(row.get("notes") or "").strip())

    if memory_type == "entity":
        accepted = (confidence >= 0.8 and evidence_count >= 1) or (confidence >= 0.6 and evidence_count >= 2 and has_note)
        return accepted, "source_only_entity_below_threshold"
    if memory_type == "phrase":
        return confidence >= 0.65 and evidence_count >= 2 and has_note, "source_only_phrase_below_threshold"
    if memory_type == "asr_correction":
        return confidence >= 0.65 and evidence_count >= 2, "source_only_asr_correction_below_threshold"
    accepted = (confidence >= 0.65 and evidence_count >= 2 and has_note) or (
        confidence >= 0.55 and evidence_count >= 4 and has_note
    )
    return accepted, "source_only_term_below_threshold"


def _memory_value_decision(
    row: dict[str, Any],
    *,
    mode: MemoryValidationMode,
    aliases: list[dict[str, Any]],
    variants: list[dict[str, Any]],
    evidence_ids: list[int],
) -> tuple[bool, str]:
    if row.get("target"):
        return True, "has_target"
    if aliases:
        return True, "has_alias"
    if variants:
        return True, "has_target_variant"
    if mode == "bootstrap":
        return _source_only_bootstrap_decision(row, evidence_ids)
    if row.get("memory_type") == "concept_hint":
        return True, "concept_hint_allowed"
    return False, "source_only_patch_requires_target_alias_or_variant"


def _rejected_candidate(
    row: dict[str, Any],
    *,
    mode: MemoryValidationMode,
    reason: str,
    evidence_ids: list[int] | None = None,
    aliases: list[dict[str, Any]] | None = None,
    variants: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    evidence_ids = list(evidence_ids or [])
    aliases = list(aliases or [])
    variants = list(variants or [])
    confidence_breakdown = row.get("confidence_breakdown") if isinstance(row.get("confidence_breakdown"), dict) else {}
    return {
        "reason": reason,
        "mode": mode,
        "source": str(row.get("source") or "").strip(),
        "target": str(row.get("target") or "").strip(),
        "category": str(row.get("category") or "").strip(),
        "memory_type": str(row.get("memory_type") or "").strip(),
        "constraint": str(row.get("constraint") or "").strip(),
        "confidence": _float_value(row.get("confidence")),
        "confidence_breakdown": confidence_breakdown,
        "evidence_ids": evidence_ids,
        "evidence_count": len(evidence_ids),
        "translation_policy": _translation_policy(row),
        "alias_count": len(aliases),
        "target_variant_count": len(variants),
        "notes": str(row.get("notes") or "").strip(),
    }


def validate_memory_payload_with_report(
    payload: dict[str, Any],
    *,
    mode: MemoryValidationMode,
    evidence: MemoryEvidence | None = None,
) -> MemoryValidationResult:
    actions: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    for raw_row in payload.get("actions", []) or []:
        if not isinstance(raw_row, dict):
            rejected.append({"reason": "invalid_action_row", "mode": mode, "raw_type": type(raw_row).__name__})
            continue
        row = dict(raw_row)
        source = str(row.get("source") or "").strip()
        if not source:
            rejected.append(_rejected_candidate(row, mode=mode, reason="missing_source"))
            continue
        if is_generic_form(source):
            row["source"] = source
            rejected.append(_rejected_candidate(row, mode=mode, reason="generic_source"))
            continue
        row["source"] = source
        row["status"] = "proposed"
        constraint = str(row.get("constraint") or "hint").strip().lower()
        if mode == "bootstrap" or constraint == "must_use" or constraint not in MEMORY_CONSTRAINTS:
            constraint = "hint"
        row["constraint"] = constraint
        memory_type = str(row.get("memory_type") or "").strip().lower()
        row["memory_type"] = memory_type if memory_type in MEMORY_TYPES else "term"
        target = str(row.get("target") or "").strip()
        if _target_too_long(target):
            target = ""
            row["constraint"] = "hint"
        row["target"] = target
        aliases = _clean_alias_details(row)
        variants = _clean_target_variants(row)
        row["alias_details"] = aliases
        row["aliases"] = _clean_legacy_aliases(row)
        row["target_variants"] = variants
        ids = _evidence_ids(row, evidence)
        if evidence is not None and not ids:
            rejected.append(
                _rejected_candidate(
                    row,
                    mode=mode,
                    reason="missing_valid_evidence_ids",
                    evidence_ids=ids,
                    aliases=aliases,
                    variants=variants,
                )
            )
            continue
        row["evidence_ids"] = ids
        if mode == "patch":
            if not _has_source_evidence(source, aliases, variants, evidence, ids):
                rejected.append(
                    _rejected_candidate(
                        row,
                        mode=mode,
                        reason="missing_source_evidence",
                        evidence_ids=ids,
                        aliases=aliases,
                        variants=variants,
                    )
                )
                continue
            if not _has_target_evidence(target, variants, evidence, ids):
                rejected.append(
                    _rejected_candidate(
                        row,
                        mode=mode,
                        reason="missing_target_evidence",
                        evidence_ids=ids,
                        aliases=aliases,
                        variants=variants,
                    )
                )
                continue
        has_value, reason = _memory_value_decision(row, mode=mode, aliases=aliases, variants=variants, evidence_ids=ids)
        if not has_value:
            rejected.append(
                _rejected_candidate(
                    row,
                    mode=mode,
                    reason=reason,
                    evidence_ids=ids,
                    aliases=aliases,
                    variants=variants,
                )
            )
            continue
        actions.append(row)
    out = dict(payload)
    out["actions"] = actions
    return MemoryValidationResult(payload=out, rejected=rejected)


def validate_memory_payload(
    payload: dict[str, Any],
    *,
    mode: MemoryValidationMode,
    evidence: MemoryEvidence | None = None,
) -> dict[str, Any]:
    return validate_memory_payload_with_report(payload, mode=mode, evidence=evidence).payload
