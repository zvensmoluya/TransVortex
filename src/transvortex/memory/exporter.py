from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from ..artifacts.task_store import TaskStore
from ..utils import read_jsonl, to_plain, utc_now_iso, write_json
from .presets import load_preset_bundle, presets_dir
from .schema import MEMORY_STATUS_ORDER, MemoryDocument, MemoryEntry, normalize_source_key, normalize_status
from .store import MemoryStore


EXPORTABLE_STATUSES = {"locked", "confirmed", "proposed"}


@dataclass
class MemoryPresetExportOptions:
    task_id: str
    preset_id: str
    name: str = ""
    description: str = ""
    default_status: str = "proposed"
    overwrite: bool = False
    dry_run: bool = False


@dataclass
class MemoryPresetExportReport:
    exported: int = 0
    skipped: list[dict[str, Any]] = field(default_factory=list)
    duplicates: list[dict[str, Any]] = field(default_factory=list)
    conflicts: list[dict[str, Any]] = field(default_factory=list)


class MemoryPresetExportError(RuntimeError):
    pass


def _status_rank(status: str) -> int:
    return MEMORY_STATUS_ORDER.get(status, 99)


def _entry_sort_key(entry: MemoryEntry) -> tuple[int, float, int, str]:
    return (
        _status_rank(entry.status),
        -float(entry.confidence),
        -int(entry.priority),
        entry.source.casefold(),
    )


def _dedupe_entries(entries: list[MemoryEntry], report: MemoryPresetExportReport) -> list[MemoryEntry]:
    selected: dict[str, MemoryEntry] = {}
    for entry in sorted(entries, key=_entry_sort_key):
        key = normalize_source_key(entry.source)
        if not key:
            continue
        existing = selected.get(key)
        if existing is None:
            selected[key] = entry
            continue
        if existing.target != entry.target:
            report.conflicts.append(
                {
                    "source": entry.source,
                    "existing_target": existing.target,
                    "proposed_target": entry.target,
                    "existing_status": existing.status,
                    "proposed_status": entry.status,
                    "reason": "duplicate_source_different_target",
                }
            )
        report.duplicates.append(
            {
                "source": entry.source,
                "target": entry.target,
                "kept_source": existing.source,
                "kept_target": existing.target,
                "reason": "duplicate_source",
            }
        )
    return sorted(selected.values(), key=_entry_sort_key)


def _clean_runtime_entries(document: MemoryDocument, report: MemoryPresetExportReport) -> list[MemoryEntry]:
    cleaned: list[MemoryEntry] = []
    for entry in document.entries:
        source = entry.source.strip()
        target = entry.target.strip()
        if not source:
            report.skipped.append({"reason": "empty_source", "target": entry.target})
            continue
        if not target:
            report.skipped.append({"reason": "empty_target", "source": entry.source})
            continue
        status = normalize_status(entry.status)
        if status not in EXPORTABLE_STATUSES:
            report.skipped.append({"reason": "status_not_exportable", "source": entry.source, "status": status})
            continue
        cleaned.append(replace(entry, source=source, target=target, status=status))
    return _dedupe_entries(cleaned, report)


def _conflict_notes(conflicts: list[dict[str, Any]]) -> dict[str, list[str]]:
    notes: dict[str, list[str]] = {}
    for conflict in conflicts:
        if not isinstance(conflict, dict):
            continue
        source = str(conflict.get("source") or "").strip()
        if not source:
            continue
        key = normalize_source_key(source)
        existing = str(conflict.get("existing_target") or "").strip()
        proposed = str(conflict.get("proposed_target") or "").strip()
        reason = str(conflict.get("reason") or "conflict").strip()
        detail = f"Conflict recorded: {reason}"
        if existing or proposed:
            detail = f"{detail}; existing={existing or '-'}; proposed={proposed or '-'}"
        notes.setdefault(key, [])
        if detail not in notes[key]:
            notes[key].append(detail)
    return notes


def _append_conflict_notes(entries: list[MemoryEntry], conflicts: list[dict[str, Any]]) -> list[MemoryEntry]:
    by_source = _conflict_notes(conflicts)
    out: list[MemoryEntry] = []
    for entry in entries:
        notes = list(by_source.get(normalize_source_key(entry.source), []))
        if not notes:
            out.append(entry)
            continue
        existing_notes = entry.notes.strip()
        merged_notes = "\n".join([item for item in [existing_notes, *notes] if item])
        out.append(replace(entry, notes=merged_notes))
    return out


def _apply_default_status(entries: list[MemoryEntry], default_status: str) -> list[MemoryEntry]:
    return [replace(entry, status=default_status, origin=entry.origin or "runtime_memory") for entry in entries]


def _entry_payload(entry: MemoryEntry) -> dict[str, Any]:
    payload = to_plain(entry)
    return {
        key: value
        for key, value in payload.items()
        if key in {
            "id",
            "source",
            "target",
            "category",
            "status",
            "origin",
            "priority",
            "aliases",
            "alias_details",
            "target_variants",
            "constraint",
            "memory_type",
            "notes",
            "confidence",
            "evidence_ids",
            "created_by",
            "updated_at",
        }
        and value not in ("", None)
        and value != []
    }


def _preset_payload(
    *,
    options: MemoryPresetExportOptions,
    source_lang: str,
    target_lang: str,
    entries: list[MemoryEntry],
) -> dict[str, Any]:
    now = utc_now_iso()
    return {
        "id": options.preset_id,
        "version": "1.0.0",
        "name": options.name,
        "description": options.description,
        "scope": {
            "language_pairs": [f"{source_lang}->{target_lang}"] if source_lang and target_lang else [],
            "works": [],
            "tags": [],
        },
        "default_status": normalize_status(options.default_status),
        "generated_from": {
            "task_id": options.task_id,
            "artifact": "translation_memory.json",
            "created_at": now,
        },
        "review": {
            "status": "draft",
            "reviewed_by": None,
            "reviewed_at": None,
        },
        "entries": [_entry_payload(entry) for entry in entries],
    }


def export_runtime_memory_to_preset(
    *,
    root_dir: Path,
    artifacts_dir: Path,
    options: MemoryPresetExportOptions,
) -> dict[str, Any]:
    task_id = options.task_id.strip()
    preset_id = options.preset_id.strip()
    if not task_id:
        raise MemoryPresetExportError("task_id is required")
    if not preset_id:
        raise MemoryPresetExportError("preset_id is required")

    default_status = normalize_status(options.default_status)
    if default_status not in EXPORTABLE_STATUSES:
        raise MemoryPresetExportError(f"default_status must be one of: {', '.join(sorted(EXPORTABLE_STATUSES))}")

    store = TaskStore(artifacts_dir)
    task = store.load_task(task_id)
    memory_store = MemoryStore(store.task_dir(task_id) / "memory")
    if not memory_store.memory_file.exists():
        raise MemoryPresetExportError(f"runtime memory not found: {memory_store.memory_file}")

    target_path = presets_dir(root_dir) / f"{preset_id}.json"
    if target_path.exists() and not options.overwrite and not options.dry_run:
        raise MemoryPresetExportError(f"memory preset already exists: {target_path}")

    report = MemoryPresetExportReport()
    runtime_doc = memory_store.load_runtime()
    file_conflicts = [row for row in read_jsonl(memory_store.conflicts_file) if isinstance(row, dict)]
    entries = _apply_default_status(
        _append_conflict_notes(_clean_runtime_entries(runtime_doc, report), file_conflicts),
        default_status,
    )
    report.exported = len(entries)
    report.conflicts.extend(file_conflicts)
    payload = _preset_payload(
        options=replace(options, preset_id=preset_id, default_status=default_status),
        source_lang=task.source_lang,
        target_lang=task.target_lang,
        entries=entries,
    )
    result = {
        "ok": True,
        "dry_run": options.dry_run,
        "task_id": task_id,
        "preset_id": preset_id,
        "path": str(target_path),
        "report": to_plain(report),
        "preset": payload,
    }
    if options.dry_run:
        return result

    write_json(target_path, payload)
    loaded = load_preset_bundle(target_path)
    if loaded.bundle is None:
        raise MemoryPresetExportError(loaded.error or f"exported preset failed to load: {target_path}")
    result["preset"] = {
        "id": loaded.bundle.id,
        "version": loaded.bundle.version,
        "name": loaded.bundle.name,
        "entries": len(loaded.bundle.entries),
    }
    return result
