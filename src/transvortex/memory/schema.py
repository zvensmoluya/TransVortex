from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


MEMORY_STATUS_ORDER = {
    "locked": 0,
    "confirmed": 1,
    "proposed": 2,
    "rejected": 3,
    "deprecated": 4,
}

STRONG_MEMORY_STATUSES = {"locked", "confirmed"}
INJECTABLE_MEMORY_STATUSES = {"locked", "confirmed", "proposed"}

MEMORY_CONSTRAINTS = {"must_use", "preferred", "hint"}
MEMORY_TYPES = {"entity", "term", "phrase", "asr_correction", "concept_hint"}
ALIAS_KINDS = {
    "asr_error",
    "nickname",
    "honorific",
    "spelling",
    "full_name",
    "phrase_fragment",
    "broad_hint",
}


@dataclass
class MemoryAlias:
    source: str
    kind: str = "spelling"


@dataclass
class MemoryTargetVariant:
    source: str
    target: str
    kind: str = "nickname"
    confidence: float = 0.0
    speaker_scope: dict[str, Any] = field(default_factory=dict)
    notes: str = ""


@dataclass
class MemoryEntry:
    id: str
    source: str
    target: str = ""
    category: str = "term"
    status: str = "proposed"
    origin: str = "model_patch"
    priority: int = 50
    aliases: list[str] = field(default_factory=list)
    alias_details: list[MemoryAlias] = field(default_factory=list)
    target_variants: list[MemoryTargetVariant] = field(default_factory=list)
    constraint: str = ""
    memory_type: str = ""
    source_preset: str = ""
    notes: str = ""
    confidence: float = 0.0
    confidence_breakdown: dict[str, float] = field(default_factory=dict)
    provenance: list[dict[str, Any]] = field(default_factory=list)
    scope: dict[str, Any] = field(default_factory=dict)
    variant_of: str = ""
    variant_of_entry_id: str = ""
    enforcement_policy: dict[str, Any] = field(default_factory=dict)
    evidence_ids: list[int] = field(default_factory=list)
    created_by: str = "system"
    updated_at: str = ""


@dataclass
class MemoryDocument:
    version: int = 1
    entries: list[MemoryEntry] = field(default_factory=list)


@dataclass
class MemoryPatchAction:
    action: str
    source: str
    target: str = ""
    category: str = "term"
    status: str = "proposed"
    confidence: float = 0.0
    evidence_ids: list[int] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)
    alias_details: list[MemoryAlias] = field(default_factory=list)
    target_variants: list[MemoryTargetVariant] = field(default_factory=list)
    constraint: str = ""
    memory_type: str = ""
    notes: str = ""
    origin: str = "model_patch"
    confidence_breakdown: dict[str, float] = field(default_factory=dict)
    provenance: list[dict[str, Any]] = field(default_factory=list)
    scope: dict[str, Any] = field(default_factory=dict)
    variant_of: str = ""
    variant_of_entry_id: str = ""
    enforcement_policy: dict[str, Any] = field(default_factory=dict)


@dataclass
class MemoryPatch:
    chunk_ids: list[str] = field(default_factory=list)
    actions: list[MemoryPatchAction] = field(default_factory=list)
    provider: str = ""
    model: str = ""
    raw_text: str = ""


@dataclass
class MemoryConflict:
    source: str
    existing_target: str
    proposed_target: str
    existing_status: str
    proposed_status: str
    chunk_ids: list[str] = field(default_factory=list)
    reason: str = ""


@dataclass
class MemoryConsistencyIssue:
    id: int
    source: str
    expected_target: str
    actual_text: str
    status: str
    category: str
    message: str
    level: str = "warning"
    severity: str = "warning"
    blocking: bool = False
    repairable: bool = True
    issue_type: str = "missing_target"
    constraint: str = ""
    matched_source: str = ""
    matched_kind: str = ""
    expected_variants: list[str] = field(default_factory=list)


def normalize_status(value: str) -> str:
    value = str(value or "proposed").strip().lower()
    return value if value in MEMORY_STATUS_ORDER else "proposed"


def normalize_constraint(value: str, *, status: str = "") -> str:
    value = str(value or "").strip().lower()
    if value in MEMORY_CONSTRAINTS:
        return value
    status = normalize_status(status)
    if status in STRONG_MEMORY_STATUSES:
        return "must_use"
    return "hint"


def normalize_memory_type(value: str, *, category: str = "") -> str:
    value = str(value or "").strip().lower()
    if value in MEMORY_TYPES:
        return value
    category = str(category or "").strip().lower()
    if category in {"name", "place", "organization", "title"}:
        return "entity"
    return "term"


def normalize_alias_kind(value: str) -> str:
    value = str(value or "spelling").strip().lower()
    return value if value in ALIAS_KINDS else "spelling"


def normalize_source_key(value: str) -> str:
    return " ".join(str(value or "").strip().casefold().split())


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        text = str(item or "").strip()
        if text and text not in out:
            out.append(text)
    return out


def _dict_value(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, dict) else {}


def _dict_list(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [dict(item) for item in value if isinstance(item, dict)]


def _float_dict(value: Any) -> dict[str, float]:
    if not isinstance(value, dict):
        return {}
    out: dict[str, float] = {}
    for key, item in value.items():
        try:
            out[str(key)] = float(item)
        except (TypeError, ValueError):
            continue
    return out


def _alias_from_dict(row: Any) -> MemoryAlias | None:
    if isinstance(row, str):
        source = row.strip()
        return MemoryAlias(source=source, kind="spelling") if source else None
    if not isinstance(row, dict):
        return None
    source = str(row.get("source") or row.get("text") or "").strip()
    if not source:
        return None
    return MemoryAlias(source=source, kind=normalize_alias_kind(str(row.get("kind") or "")))


def _alias_details_from_dicts(value: Any) -> list[MemoryAlias]:
    if not isinstance(value, list):
        return []
    out: list[MemoryAlias] = []
    seen: set[tuple[str, str]] = set()
    for item in value:
        alias = _alias_from_dict(item)
        if alias is None:
            continue
        key = (normalize_source_key(alias.source), alias.kind)
        if key in seen:
            continue
        seen.add(key)
        out.append(alias)
    return out


def _variant_from_dict(row: Any) -> MemoryTargetVariant | None:
    if not isinstance(row, dict):
        return None
    source = str(row.get("source") or "").strip()
    target = str(row.get("target") or "").strip()
    if not source or not target:
        return None
    try:
        confidence = float(row.get("confidence") or 0.0)
    except (TypeError, ValueError):
        confidence = 0.0
    return MemoryTargetVariant(
        source=source,
        target=target,
        kind=normalize_alias_kind(str(row.get("kind") or "nickname")),
        confidence=confidence,
        speaker_scope=_dict_value(row.get("speaker_scope")),
        notes=str(row.get("notes") or ""),
    )


def _target_variants_from_dicts(value: Any) -> list[MemoryTargetVariant]:
    if not isinstance(value, list):
        return []
    out: list[MemoryTargetVariant] = []
    seen: set[tuple[str, str, str]] = set()
    for item in value:
        variant = _variant_from_dict(item)
        if variant is None:
            continue
        key = (normalize_source_key(variant.source), variant.target, variant.kind)
        if key in seen:
            continue
        seen.add(key)
        out.append(variant)
    return out


def legacy_alias_details(aliases: list[str]) -> list[MemoryAlias]:
    return [MemoryAlias(source=alias, kind="spelling") for alias in aliases if str(alias or "").strip()]


def entry_alias_details(entry: MemoryEntry) -> list[MemoryAlias]:
    details = list(entry.alias_details)
    seen = {(normalize_source_key(item.source), item.kind) for item in details}
    for alias in legacy_alias_details(entry.aliases):
        key = (normalize_source_key(alias.source), alias.kind)
        if key in seen:
            continue
        seen.add(key)
        details.append(alias)
    return details


def entry_from_dict(row: dict[str, Any]) -> MemoryEntry:
    status = normalize_status(str(row.get("status") or "proposed"))
    category = str(row.get("category") or "term")
    aliases = _string_list(row.get("aliases"))
    return MemoryEntry(
        id=str(row.get("id") or ""),
        source=str(row.get("source") or ""),
        target=str(row.get("target") or ""),
        category=category,
        status=status,
        origin=str(row.get("origin") or "model_patch"),
        priority=int(row.get("priority") or 50),
        aliases=aliases,
        alias_details=_alias_details_from_dicts(row.get("alias_details")),
        target_variants=_target_variants_from_dicts(row.get("target_variants")),
        constraint=normalize_constraint(str(row.get("constraint") or ""), status=status),
        memory_type=normalize_memory_type(str(row.get("memory_type") or ""), category=category),
        source_preset=str(row.get("source_preset") or ""),
        notes=str(row.get("notes") or ""),
        confidence=float(row.get("confidence") or 0.0),
        confidence_breakdown=_float_dict(row.get("confidence_breakdown")),
        provenance=_dict_list(row.get("provenance")),
        scope=_dict_value(row.get("scope")),
        variant_of=str(row.get("variant_of") or ""),
        variant_of_entry_id=str(row.get("variant_of_entry_id") or ""),
        enforcement_policy=_dict_value(row.get("enforcement_policy")),
        evidence_ids=[int(item) for item in row.get("evidence_ids", []) or [] if str(item).isdigit()],
        created_by=str(row.get("created_by") or "system"),
        updated_at=str(row.get("updated_at") or ""),
    )


def patch_action_from_dict(row: dict[str, Any]) -> MemoryPatchAction:
    status = normalize_status(str(row.get("status") or "proposed"))
    category = str(row.get("category") or "term")
    aliases = _string_list(row.get("aliases"))
    return MemoryPatchAction(
        action=str(row.get("action") or "upsert"),
        source=str(row.get("source") or ""),
        target=str(row.get("target") or ""),
        category=category,
        status=status,
        confidence=float(row.get("confidence") or 0.0),
        evidence_ids=[int(item) for item in row.get("evidence_ids", []) or [] if str(item).isdigit()],
        aliases=aliases,
        alias_details=_alias_details_from_dicts(row.get("alias_details")),
        target_variants=_target_variants_from_dicts(row.get("target_variants")),
        constraint=normalize_constraint(str(row.get("constraint") or ""), status=status),
        memory_type=normalize_memory_type(str(row.get("memory_type") or ""), category=category),
        notes=str(row.get("notes") or ""),
        origin=str(row.get("origin") or "model_patch"),
        confidence_breakdown=_float_dict(row.get("confidence_breakdown")),
        provenance=_dict_list(row.get("provenance")),
        scope=_dict_value(row.get("scope")),
        variant_of=str(row.get("variant_of") or ""),
        variant_of_entry_id=str(row.get("variant_of_entry_id") or ""),
        enforcement_policy=_dict_value(row.get("enforcement_policy")),
    )

