from __future__ import annotations

import hashlib
from dataclasses import replace
from typing import Any

from ..utils import to_plain, utc_now_iso
from .schema import (
    MEMORY_STATUS_ORDER,
    MemoryAlias,
    MemoryConflict,
    MemoryDocument,
    MemoryEntry,
    MemoryPatch,
    MemoryPatchAction,
    MemoryTargetVariant,
    normalize_source_key,
    patch_action_from_dict,
)
from .store import MemoryStore


def _memory_id(source: str, category: str) -> str:
    digest = hashlib.sha1(f"{category}:{source}".encode("utf-8")).hexdigest()[:10]
    return f"mem_{digest}"


def _merge_lists(a: list, b: list) -> list:
    out = []
    for item in [*a, *b]:
        if item not in out:
            out.append(item)
    return out


def _merge_alias_details(a: list[MemoryAlias], b: list[MemoryAlias]) -> list[MemoryAlias]:
    out: list[MemoryAlias] = []
    seen: set[tuple[str, str]] = set()
    for item in [*a, *b]:
        key = (normalize_source_key(item.source), item.kind)
        if not key[0] or key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _merge_target_variants(a: list[MemoryTargetVariant], b: list[MemoryTargetVariant]) -> list[MemoryTargetVariant]:
    out: list[MemoryTargetVariant] = []
    seen: set[tuple[str, str, str]] = set()
    for item in [*a, *b]:
        key = (normalize_source_key(item.source), item.target, item.kind)
        if not key[0] or not item.target or key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _merge_dict(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    return {**b, **a}


def _merge_dict_lists(a: list[dict[str, Any]], b: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in [*a, *b]:
        key = repr(sorted(item.items()))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _action_has_memory_value(action: MemoryPatchAction) -> bool:
    return bool(
        action.source.strip()
        and (
            action.target.strip()
            or action.alias_details
            or action.target_variants
            or action.memory_type in {"asr_correction", "concept_hint"}
            or action.constraint == "hint"
            or action.notes.strip()
        )
    )


def patch_from_payload(payload: dict[str, Any]) -> MemoryPatch:
    return MemoryPatch(
        chunk_ids=[str(item) for item in payload.get("chunk_ids", []) or []],
        actions=[
            patch_action_from_dict(row)
            for row in payload.get("actions", []) or []
            if isinstance(row, dict)
        ],
        provider=str(payload.get("provider") or ""),
        model=str(payload.get("model") or ""),
        raw_text=str(payload.get("raw_text") or ""),
    )


def merge_patch(
    document: MemoryDocument,
    patch: MemoryPatch,
    *,
    store: MemoryStore | None = None,
    protected_entries: list[MemoryEntry] | None = None,
    auto_confirm_high_confidence: bool = False,
) -> tuple[MemoryDocument, list[MemoryConflict]]:
    entries = list(document.entries)
    by_key = {normalize_source_key(entry.source): entry for entry in entries}
    protected_by_key = {
        normalize_source_key(entry.source): entry
        for entry in (protected_entries or [])
        if normalize_source_key(entry.source)
    }
    conflicts: list[MemoryConflict] = []
    for action in patch.actions:
        if action.action not in {"upsert", "add", "update"}:
            continue
        if not _action_has_memory_value(action):
            continue
        status = action.status
        key = normalize_source_key(action.source)
        protected = protected_by_key.get(key)
        if protected is not None:
            if not action.target or protected.target == action.target:
                continue
            conflict = MemoryConflict(
                source=action.source,
                existing_target=protected.target,
                proposed_target=action.target,
                existing_status=protected.status,
                proposed_status=status,
                chunk_ids=patch.chunk_ids,
                reason="preset entry cannot be overwritten",
            )
            conflicts.append(conflict)
            if store is not None:
                store.append_conflict(to_plain(conflict))
            continue
        existing = by_key.get(key)
        if existing is None:
            entry = replace(
                action_to_entry(action),
                id=_memory_id(action.source, action.category),
                status=status,
                updated_at=utc_now_iso(),
            )
            entries.append(entry)
            by_key[key] = entry
            continue
        if action.target and existing.target and existing.target != action.target:
            conflict = MemoryConflict(
                source=action.source,
                existing_target=existing.target,
                proposed_target=action.target,
                existing_status=existing.status,
                proposed_status=status,
                chunk_ids=patch.chunk_ids,
                reason="locked entry cannot be overwritten" if existing.status == "locked" else "different target proposed",
            )
            conflicts.append(conflict)
            if store is not None:
                store.append_conflict(to_plain(conflict))
            continue
        stronger_status = min(
            [existing.status, status],
            key=lambda item: MEMORY_STATUS_ORDER.get(item, 99),
        )
        merged = replace(
            existing,
            target=existing.target or action.target,
            category=existing.category or action.category,
            status=stronger_status,
            aliases=_merge_lists(existing.aliases, action.aliases),
            alias_details=_merge_alias_details(existing.alias_details, action.alias_details),
            target_variants=_merge_target_variants(existing.target_variants, action.target_variants),
            constraint=existing.constraint or action.constraint,
            memory_type=existing.memory_type or action.memory_type,
            evidence_ids=_merge_lists(existing.evidence_ids, action.evidence_ids),
            confidence=max(float(existing.confidence), float(action.confidence)),
            confidence_breakdown=_merge_dict(existing.confidence_breakdown, action.confidence_breakdown),
            provenance=_merge_dict_lists(existing.provenance, action.provenance),
            scope=_merge_dict(existing.scope, action.scope),
            variant_of=existing.variant_of or action.variant_of,
            variant_of_entry_id=existing.variant_of_entry_id or action.variant_of_entry_id,
            enforcement_policy=_merge_dict(existing.enforcement_policy, action.enforcement_policy),
            notes=existing.notes or action.notes,
            updated_at=utc_now_iso(),
        )
        idx = entries.index(existing)
        entries[idx] = merged
        by_key[key] = merged
    return MemoryDocument(version=document.version, entries=entries), conflicts


def action_to_entry(action: MemoryPatchAction):
    from .schema import MemoryEntry

    return MemoryEntry(
        id="",
        source=action.source,
        target=action.target,
        category=action.category,
        status=action.status,
        origin=action.origin,
        priority=50,
        aliases=action.aliases,
        alias_details=action.alias_details,
        target_variants=action.target_variants,
        constraint=action.constraint,
        memory_type=action.memory_type,
        notes=action.notes,
        confidence=action.confidence,
        confidence_breakdown=action.confidence_breakdown,
        provenance=action.provenance,
        scope=action.scope,
        variant_of=action.variant_of,
        variant_of_entry_id=action.variant_of_entry_id,
        enforcement_policy=action.enforcement_policy,
        evidence_ids=action.evidence_ids,
        created_by="model",
    )
