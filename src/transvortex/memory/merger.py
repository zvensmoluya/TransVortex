from __future__ import annotations

import hashlib
from dataclasses import replace
from typing import Any

from ..utils import to_plain, utc_now_iso
from .schema import (
    MEMORY_STATUS_ORDER,
    MemoryConflict,
    MemoryDocument,
    MemoryPatch,
    MemoryPatchAction,
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
    auto_confirm_high_confidence: bool = False,
) -> tuple[MemoryDocument, list[MemoryConflict]]:
    entries = list(document.entries)
    by_key = {normalize_source_key(entry.source): entry for entry in entries}
    conflicts: list[MemoryConflict] = []
    for action in patch.actions:
        if action.action not in {"upsert", "add", "update"}:
            continue
        if not action.source.strip() or not action.target.strip():
            continue
        status = action.status
        if auto_confirm_high_confidence and status == "proposed" and action.confidence >= 0.9:
            status = "confirmed"
        key = normalize_source_key(action.source)
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
        if existing.target and existing.target != action.target:
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
            evidence_ids=_merge_lists(existing.evidence_ids, action.evidence_ids),
            confidence=max(float(existing.confidence), float(action.confidence)),
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
        notes=action.notes,
        confidence=action.confidence,
        evidence_ids=action.evidence_ids,
        created_by="model",
    )

