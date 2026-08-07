from __future__ import annotations

import hashlib
import json
import re
import uuid
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from ..utils import FileLock, read_json, to_plain, utc_now_iso, write_json
from .schema import (
    MEMORY_STATUS_ORDER,
    MemoryEntry,
    entry_from_dict,
    normalize_source_key,
)


MEMORY_COLLECTION_SCHEMA_VERSION = 1
MEMORY_COLLECTION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MEMORY_COLLECTION_EDITABLE_STATUSES = set(MEMORY_STATUS_ORDER)


class MemoryCollectionError(ValueError):
    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = details or {}


@dataclass
class MemoryCollection:
    id: str
    name: str
    description: str = ""
    language_pairs: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    revision: int = 1
    entries: list[MemoryEntry] = field(default_factory=list)
    created_at: str = ""
    updated_at: str = ""
    created_by: str = "user"
    updated_by: str = "user"


def memory_collections_dir(*, root_dir: Path, artifacts_dir: Path) -> Path:
    """Resolve mutable user memory next to the task workspace, never the app install."""

    artifacts = artifacts_dir.expanduser().resolve()
    if artifacts.name.casefold() == "tasks":
        return artifacts.parent / "Memory"
    return root_dir.expanduser().resolve() / "memory" / "collections"


def collection_store_for_config(*, root_dir: Path, config: Any) -> "MemoryCollectionStore":
    return MemoryCollectionStore(
        memory_collections_dir(
            root_dir=root_dir,
            artifacts_dir=Path(config.pipeline.artifacts_dir),
        )
    )


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    result: list[str] = []
    for item in value:
        text = str(item or "").strip()
        if text and text not in result:
            result.append(text)
    return result


def _normalized_language_pairs(value: Any) -> list[str]:
    return [item.casefold() for item in _string_list(value)]


def _collection_id(value: str = "") -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return f"memcol_{uuid.uuid4().hex[:12]}"
    if not MEMORY_COLLECTION_ID_PATTERN.fullmatch(candidate):
        raise MemoryCollectionError(
            "memory_collection_id_invalid",
            "collection id must contain only letters, numbers, dot, underscore, or hyphen",
            details={"collection_id": candidate},
        )
    return candidate


def _entry_id(value: str = "") -> str:
    candidate = str(value or "").strip()
    return candidate or f"mem_{uuid.uuid4().hex[:12]}"


def _entry_has_value(entry: MemoryEntry) -> bool:
    return bool(
        entry.source.strip()
        and (
            entry.target.strip()
            or entry.notes.strip()
            or entry.aliases
            or entry.alias_details
            or entry.target_variants
        )
    )


def _entry_from_payload(
    payload: dict[str, Any],
    *,
    existing: MemoryEntry | None = None,
    actor: str,
) -> MemoryEntry:
    merged = to_plain(existing) if existing is not None else {}
    merged.update(payload)
    explicit_status = str(merged.get("status") or "confirmed").strip().lower()
    if explicit_status not in MEMORY_COLLECTION_EDITABLE_STATUSES:
        raise MemoryCollectionError(
            "memory_entry_status_invalid",
            f"unsupported memory entry status: {explicit_status}",
            details={"status": explicit_status},
        )
    merged["id"] = _entry_id(str(merged.get("id") or ""))
    merged["status"] = explicit_status
    merged["origin"] = str(merged.get("origin") or "manual")
    merged["created_by"] = str(merged.get("created_by") or actor or "user")
    merged["updated_at"] = utc_now_iso()
    try:
        entry = entry_from_dict(merged)
    except (TypeError, ValueError) as exc:
        raise MemoryCollectionError("memory_entry_invalid", str(exc)) from exc
    if not _entry_has_value(entry):
        raise MemoryCollectionError(
            "memory_entry_invalid",
            "memory entry requires source and a target, note, alias, or target variant",
        )
    return entry


def collection_from_payload(payload: dict[str, Any]) -> MemoryCollection:
    schema_version = int(payload.get("schema_version") or MEMORY_COLLECTION_SCHEMA_VERSION)
    if schema_version != MEMORY_COLLECTION_SCHEMA_VERSION:
        raise MemoryCollectionError(
            "memory_collection_schema_unsupported",
            f"unsupported memory collection schema version: {schema_version}",
        )
    collection_id = _collection_id(str(payload.get("id") or ""))
    name = str(payload.get("name") or "").strip()
    if not name:
        raise MemoryCollectionError("memory_collection_name_required", "collection name is required")
    raw_entries = payload.get("entries") or []
    if not isinstance(raw_entries, list):
        raise MemoryCollectionError("memory_collection_invalid", "collection entries must be a list")
    entries: list[MemoryEntry] = []
    seen_ids: set[str] = set()
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, dict):
            raise MemoryCollectionError("memory_entry_invalid", "memory entry must be an object")
        try:
            entry = entry_from_dict(raw_entry)
        except (TypeError, ValueError) as exc:
            raise MemoryCollectionError("memory_entry_invalid", str(exc)) from exc
        if not entry.id or not _entry_has_value(entry):
            raise MemoryCollectionError(
                "memory_entry_invalid",
                "stored memory entry requires an id, source, and a target, note, alias, or target variant",
            )
        if entry.id in seen_ids:
            raise MemoryCollectionError(
                "memory_entry_id_duplicate",
                f"duplicate memory entry id: {entry.id}",
            )
        seen_ids.add(entry.id)
        entries.append(entry)
    return MemoryCollection(
        id=collection_id,
        name=name,
        description=str(payload.get("description") or ""),
        language_pairs=_normalized_language_pairs(payload.get("language_pairs")),
        tags=_string_list(payload.get("tags")),
        revision=max(1, int(payload.get("revision") or 1)),
        entries=entries,
        created_at=str(payload.get("created_at") or ""),
        updated_at=str(payload.get("updated_at") or ""),
        created_by=str(payload.get("created_by") or "user"),
        updated_by=str(payload.get("updated_by") or "user"),
    )


def collection_payload(collection: MemoryCollection) -> dict[str, Any]:
    return {
        "schema_version": MEMORY_COLLECTION_SCHEMA_VERSION,
        "id": collection.id,
        "name": collection.name,
        "description": collection.description,
        "language_pairs": list(collection.language_pairs),
        "tags": list(collection.tags),
        "revision": collection.revision,
        "created_at": collection.created_at,
        "updated_at": collection.updated_at,
        "created_by": collection.created_by,
        "updated_by": collection.updated_by,
        "entries": [to_plain(entry) for entry in collection.entries],
    }


def collection_summary(collection: MemoryCollection) -> dict[str, Any]:
    status_counts: dict[str, int] = {}
    for entry in collection.entries:
        status_counts[entry.status] = status_counts.get(entry.status, 0) + 1
    return {
        "id": collection.id,
        "name": collection.name,
        "description": collection.description,
        "language_pairs": list(collection.language_pairs),
        "tags": list(collection.tags),
        "revision": collection.revision,
        "entries": len(collection.entries),
        "status_counts": status_counts,
        "created_at": collection.created_at,
        "updated_at": collection.updated_at,
    }


class MemoryCollectionStore:
    def __init__(self, root: Path) -> None:
        self.root = root.expanduser().resolve()

    @property
    def lock_file(self) -> Path:
        return self.root / ".collections.lock"

    def collection_file(self, collection_id: str) -> Path:
        return self.root / f"{_collection_id(collection_id)}.json"

    def list(self) -> list[MemoryCollection]:
        if not self.root.exists():
            return []
        collections: list[MemoryCollection] = []
        for path in sorted(self.root.glob("*.json")):
            try:
                collection = collection_from_payload(read_json(path))
            except (OSError, ValueError, TypeError, MemoryCollectionError):
                continue
            if collection.id != path.stem:
                continue
            collections.append(collection)
        collections.sort(key=lambda item: (item.name.casefold(), item.id.casefold()))
        return collections

    def get(self, collection_id: str) -> MemoryCollection:
        path = self.collection_file(collection_id)
        if not path.exists():
            raise MemoryCollectionError(
                "memory_collection_not_found",
                f"memory collection not found: {collection_id}",
                details={"collection_id": collection_id},
            )
        try:
            collection = collection_from_payload(read_json(path))
        except MemoryCollectionError:
            raise
        except (OSError, TypeError, ValueError) as exc:
            raise MemoryCollectionError("memory_collection_invalid", str(exc)) from exc
        if collection.id != path.stem:
            raise MemoryCollectionError(
                "memory_collection_id_mismatch",
                f"memory collection id does not match filename: {collection.id}",
            )
        return collection

    def create(
        self,
        *,
        name: str,
        collection_id: str = "",
        description: str = "",
        language_pairs: list[str] | None = None,
        tags: list[str] | None = None,
        actor: str = "user",
    ) -> MemoryCollection:
        normalized_id = _collection_id(collection_id)
        normalized_name = str(name or "").strip()
        if not normalized_name:
            raise MemoryCollectionError("memory_collection_name_required", "collection name is required")
        with FileLock(self.lock_file):
            path = self.collection_file(normalized_id)
            if path.exists():
                raise MemoryCollectionError(
                    "memory_collection_exists",
                    f"memory collection already exists: {normalized_id}",
                    details={"collection_id": normalized_id},
                )
            now = utc_now_iso()
            collection = MemoryCollection(
                id=normalized_id,
                name=normalized_name,
                description=str(description or ""),
                language_pairs=_normalized_language_pairs(language_pairs or []),
                tags=_string_list(tags or []),
                revision=1,
                created_at=now,
                updated_at=now,
                created_by=actor or "user",
                updated_by=actor or "user",
            )
            write_json(path, collection_payload(collection))
            return collection

    def update(
        self,
        collection_id: str,
        changes: dict[str, Any],
        *,
        expected_revision: int | None = None,
        actor: str = "user",
        dry_run: bool = False,
    ) -> MemoryCollection:
        with FileLock(self.lock_file):
            current = self.get(collection_id)
            self._check_revision(current, expected_revision)
            name = str(changes.get("name", current.name) or "").strip()
            if not name:
                raise MemoryCollectionError("memory_collection_name_required", "collection name is required")
            updated = replace(
                current,
                name=name,
                description=str(changes.get("description", current.description) or ""),
                language_pairs=(
                    _normalized_language_pairs(changes.get("language_pairs"))
                    if "language_pairs" in changes
                    else current.language_pairs
                ),
                tags=_string_list(changes.get("tags")) if "tags" in changes else current.tags,
                revision=current.revision + 1,
                updated_at=utc_now_iso(),
                updated_by=actor or "user",
            )
            if not dry_run:
                write_json(self.collection_file(collection_id), collection_payload(updated))
            return updated

    def delete(self, collection_id: str, *, expected_revision: int | None = None) -> None:
        with FileLock(self.lock_file):
            current = self.get(collection_id)
            self._check_revision(current, expected_revision)
            self.collection_file(collection_id).unlink()

    def upsert_entry(
        self,
        collection_id: str,
        entry_payload: dict[str, Any],
        *,
        expected_revision: int | None = None,
        actor: str = "user",
        dry_run: bool = False,
    ) -> tuple[MemoryCollection, MemoryEntry]:
        with FileLock(self.lock_file):
            current = self.get(collection_id)
            self._check_revision(current, expected_revision)
            requested_id = str(entry_payload.get("id") or "").strip()
            existing = next((entry for entry in current.entries if entry.id == requested_id), None) if requested_id else None
            entry = _entry_from_payload(entry_payload, existing=existing, actor=actor)
            entries = list(current.entries)
            if existing is None:
                entries.append(entry)
            else:
                entries[entries.index(existing)] = entry
            updated = replace(
                current,
                entries=entries,
                revision=current.revision + 1,
                updated_at=utc_now_iso(),
                updated_by=actor or "user",
            )
            if not dry_run:
                write_json(self.collection_file(collection_id), collection_payload(updated))
            return updated, entry

    def delete_entry(
        self,
        collection_id: str,
        entry_id: str,
        *,
        expected_revision: int | None = None,
        actor: str = "user",
        dry_run: bool = False,
    ) -> MemoryCollection:
        with FileLock(self.lock_file):
            current = self.get(collection_id)
            self._check_revision(current, expected_revision)
            entries = [entry for entry in current.entries if entry.id != entry_id]
            if len(entries) == len(current.entries):
                raise MemoryCollectionError(
                    "memory_entry_not_found",
                    f"memory entry not found: {entry_id}",
                    details={"entry_id": entry_id},
                )
            updated = replace(
                current,
                entries=entries,
                revision=current.revision + 1,
                updated_at=utc_now_iso(),
                updated_by=actor or "user",
            )
            if not dry_run:
                write_json(self.collection_file(collection_id), collection_payload(updated))
            return updated

    def promote_entries(
        self,
        collection_id: str,
        entries: list[MemoryEntry],
        *,
        task_id: str,
        status: str = "confirmed",
        expected_revision: int | None = None,
        conflict_policy: str = "skip",
        actor: str = "user",
        dry_run: bool = False,
    ) -> dict[str, Any]:
        normalized_status = str(status or "confirmed").strip().lower()
        if normalized_status not in MEMORY_COLLECTION_EDITABLE_STATUSES:
            raise MemoryCollectionError("memory_entry_status_invalid", f"unsupported memory entry status: {status}")
        if conflict_policy not in {"skip", "replace"}:
            raise MemoryCollectionError(
                "memory_conflict_policy_invalid",
                "conflict policy must be skip or replace",
            )
        with FileLock(self.lock_file):
            current = self.get(collection_id)
            self._check_revision(current, expected_revision)
            next_entries = list(current.entries)
            by_source = {normalize_source_key(item.source): item for item in next_entries}
            applied: list[dict[str, Any]] = []
            skipped: list[dict[str, Any]] = []
            conflicts: list[dict[str, Any]] = []
            for source_entry in entries:
                key = normalize_source_key(source_entry.source)
                if not key or not _entry_has_value(source_entry):
                    skipped.append({"entry_id": source_entry.id, "reason": "invalid_entry"})
                    continue
                existing = by_source.get(key)
                if existing is not None and any(
                    str(item.get("kind") or "") == "task_memory_promotion"
                    and str(item.get("task_id") or "") == task_id
                    and str(item.get("task_entry_id") or "") == source_entry.id
                    for item in existing.provenance
                    if isinstance(item, dict)
                ):
                    skipped.append({"entry_id": source_entry.id, "reason": "already_promoted"})
                    continue
                if existing is not None and existing.target and source_entry.target and existing.target != source_entry.target:
                    conflict = {
                        "source": source_entry.source,
                        "existing_entry_id": existing.id,
                        "existing_target": existing.target,
                        "proposed_target": source_entry.target,
                        "task_entry_id": source_entry.id,
                    }
                    conflicts.append(conflict)
                    if conflict_policy == "skip":
                        skipped.append({"entry_id": source_entry.id, "reason": "target_conflict"})
                        continue
                provenance = list(existing.provenance if existing is not None else source_entry.provenance)
                promotion = {
                    "kind": "task_memory_promotion",
                    "task_id": task_id,
                    "task_entry_id": source_entry.id,
                    "promoted_at": utc_now_iso(),
                    "actor": actor or "user",
                }
                if promotion not in provenance:
                    provenance.append(promotion)
                payload = to_plain(source_entry)
                payload.update(
                    {
                        "id": existing.id if existing is not None else "",
                        "status": normalized_status,
                        "origin": "task_promotion",
                        "created_by": existing.created_by if existing is not None else actor or "user",
                        "provenance": provenance,
                    }
                )
                promoted = _entry_from_payload(payload, existing=existing, actor=actor)
                if existing is None:
                    next_entries.append(promoted)
                else:
                    next_entries[next_entries.index(existing)] = promoted
                by_source[key] = promoted
                applied.append({"entry_id": source_entry.id, "collection_entry_id": promoted.id})
            changed = bool(applied)
            updated = replace(
                current,
                entries=next_entries,
                revision=current.revision + (1 if changed else 0),
                updated_at=utc_now_iso() if changed else current.updated_at,
                updated_by=(actor or "user") if changed else current.updated_by,
            )
            if changed and not dry_run:
                write_json(self.collection_file(collection_id), collection_payload(updated))
            return {
                "ok": True,
                "dry_run": dry_run,
                "task_id": task_id,
                "collection": collection_payload(updated),
                "applied": applied,
                "skipped": skipped,
                "conflicts": conflicts,
            }

    @staticmethod
    def _check_revision(collection: MemoryCollection, expected_revision: int | None) -> None:
        if expected_revision is None:
            return
        if int(expected_revision) != collection.revision:
            raise MemoryCollectionError(
                "memory_collection_revision_conflict",
                "memory collection changed since it was read",
                details={"expected_revision": int(expected_revision), "actual_revision": collection.revision},
            )


def _collection_matches_pair(collection: MemoryCollection, source_lang: str, target_lang: str) -> bool:
    if not collection.language_pairs:
        return True
    source = source_lang.strip().casefold()
    target = target_lang.strip().casefold()
    if source in {"", "auto", "und", "unknown"}:
        return any(
            item in {"*", "*->*"}
            or item.endswith("->*")
            or item.endswith(f"->{target}")
            for item in collection.language_pairs
        )
    pair = f"{source}->{target}"
    source_wildcard = f"{source}->*"
    return any(item in {"*", "*->*", pair, source_wildcard} for item in collection.language_pairs)


def _collection_hash(collection: MemoryCollection) -> str:
    payload = json.dumps(
        collection_payload(collection),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(payload).hexdigest()}"


def build_selected_collections_snapshot(
    *,
    collection_ids: list[str],
    store: MemoryCollectionStore,
    source_lang: str,
    target_lang: str,
) -> dict[str, Any]:
    applied: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    conflicts: list[dict[str, Any]] = []
    entries: list[MemoryEntry] = []
    by_source: dict[str, tuple[str, MemoryEntry]] = {}
    seen_ids: set[str] = set()
    selected_ids: list[str] = []
    for raw_id in collection_ids:
        collection_id = _collection_id(raw_id)
        if collection_id in seen_ids:
            continue
        seen_ids.add(collection_id)
        selected_ids.append(collection_id)
        collection = store.get(collection_id)
        if not _collection_matches_pair(collection, source_lang, target_lang):
            skipped.append(
                {
                    "collection_id": collection.id,
                    "name": collection.name,
                    "reason": "language_pair_mismatch",
                    "language_pairs": collection.language_pairs,
                }
            )
            continue
        added = 0
        for raw_entry in collection.entries:
            entry = replace(
                raw_entry,
                source_preset=f"collection:{collection.id}",
                provenance=[
                    *raw_entry.provenance,
                    {
                        "kind": "memory_collection_snapshot",
                        "collection_id": collection.id,
                        "collection_revision": collection.revision,
                    },
                ],
            )
            key = normalize_source_key(entry.source)
            if not key:
                continue
            owner = by_source.get(key)
            if owner is not None:
                owner_id, existing = owner
                if existing.target != entry.target or existing.status != entry.status:
                    conflicts.append(
                        {
                            "source": entry.source,
                            "kept_collection_id": owner_id,
                            "skipped_collection_id": collection.id,
                            "kept_target": existing.target,
                            "skipped_target": entry.target,
                            "reason": "duplicate_source",
                        }
                    )
                continue
            by_source[key] = (collection.id, entry)
            entries.append(entry)
            added += 1
        applied.append(
            {
                "collection_id": collection.id,
                "name": collection.name,
                "revision": collection.revision,
                "hash": _collection_hash(collection),
                "entries": added,
            }
        )
    return {
        "schema_version": 1,
        "created_at": utc_now_iso(),
        "source_lang": source_lang,
        "target_lang": target_lang,
        "collection_ids": selected_ids,
        "report": {
            "applied": applied,
            "skipped": skipped,
            "conflicts": conflicts,
            "entries": len(entries),
        },
        "entries": [to_plain(entry) for entry in entries],
    }
