from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

from .schema import ALIAS_KINDS, MEMORY_CONSTRAINTS, MEMORY_TYPES
from .selector import is_generic_form


MemoryValidationMode = Literal["bootstrap", "patch"]


@dataclass
class MemoryEvidence:
    source_by_id: dict[int, str] = field(default_factory=dict)
    target_by_id: dict[int, str] = field(default_factory=dict)


def _target_too_long(target: str) -> bool:
    target = str(target or "").strip()
    return bool(target and len(target) > 32)


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


def validate_memory_payload(
    payload: dict[str, Any],
    *,
    mode: MemoryValidationMode,
    evidence: MemoryEvidence | None = None,
) -> dict[str, Any]:
    actions: list[dict[str, Any]] = []
    for raw_row in payload.get("actions", []) or []:
        if not isinstance(raw_row, dict):
            continue
        row = dict(raw_row)
        source = str(row.get("source") or "").strip()
        if not source or is_generic_form(source):
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
            continue
        row["evidence_ids"] = ids
        if mode == "patch":
            if not _has_source_evidence(source, aliases, variants, evidence, ids):
                continue
            if not _has_target_evidence(target, variants, evidence, ids):
                continue
        if not target and not aliases and not variants and row.get("memory_type") != "concept_hint":
            continue
        actions.append(row)
    out = dict(payload)
    out["actions"] = actions
    return out
