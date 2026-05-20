from __future__ import annotations

from pathlib import Path
from typing import Any

from ..utils import append_jsonl, read_json, to_plain, utc_now_iso, write_json
from .schema import MemoryDocument, MemoryEntry, entry_from_dict, normalize_source_key


class MemoryStore:
    def __init__(self, memory_dir: Path) -> None:
        self.memory_dir = memory_dir

    @property
    def memory_file(self) -> Path:
        return self.memory_dir / "translation_memory.json"

    @property
    def selected_presets_file(self) -> Path:
        return self.memory_dir / "selected_presets.json"

    @property
    def patches_file(self) -> Path:
        return self.memory_dir / "memory_patches.jsonl"

    @property
    def conflicts_file(self) -> Path:
        return self.memory_dir / "conflicts.jsonl"

    @property
    def decisions_file(self) -> Path:
        return self.memory_dir / "decisions.jsonl"

    @property
    def issues_file(self) -> Path:
        return self.memory_dir / "consistency_issues.jsonl"

    @property
    def snapshots_dir(self) -> Path:
        return self.memory_dir / "snapshots"

    def ensure(self) -> None:
        self.memory_dir.mkdir(parents=True, exist_ok=True)
        self.snapshots_dir.mkdir(parents=True, exist_ok=True)
        self.patches_file.touch(exist_ok=True)
        self.conflicts_file.touch(exist_ok=True)
        self.decisions_file.touch(exist_ok=True)
        self.issues_file.touch(exist_ok=True)

    def ensure_runtime_document(self) -> None:
        self.ensure()
        if not self.memory_file.exists():
            self.save(MemoryDocument())

    def load_runtime(self) -> MemoryDocument:
        self.ensure()
        if not self.memory_file.exists():
            return MemoryDocument()
        data = read_json(self.memory_file)
        entries = [entry_from_dict(row) for row in data.get("entries", []) if isinstance(row, dict)]
        return MemoryDocument(version=int(data.get("version") or 1), entries=entries)

    def load(self) -> MemoryDocument:
        return self.load_runtime()

    def save_selected_presets(self, snapshot: dict[str, Any]) -> None:
        write_json(self.selected_presets_file, snapshot)

    def load_selected_presets(self) -> dict[str, Any]:
        self.ensure()
        if not self.selected_presets_file.exists():
            return {
                "version": 1,
                "source_lang": "",
                "target_lang": "",
                "report": {"applied": [], "skipped": [], "errors": [], "entries": 0},
                "entries": [],
            }
        data = read_json(self.selected_presets_file)
        return data if isinstance(data, dict) else {}

    def load_selected_entries(self) -> list[MemoryEntry]:
        snapshot = self.load_selected_presets()
        return [
            entry_from_dict(row)
            for row in snapshot.get("entries", []) or []
            if isinstance(row, dict)
        ]

    def load_effective(self, sources: tuple[str, ...] = ()) -> MemoryDocument:
        source_set = set(sources)
        runtime = self.load_runtime() if "runtime" in source_set else MemoryDocument()
        preset_entries = self.load_selected_entries() if "presets" in source_set else []
        entries: list[MemoryEntry] = []
        seen: set[str] = set()
        for entry in [*preset_entries, *runtime.entries]:
            key = normalize_source_key(entry.source)
            if not key or key in seen:
                continue
            seen.add(key)
            entries.append(entry)
        return MemoryDocument(version=runtime.version, entries=entries)

    def save(self, document: MemoryDocument) -> None:
        payload = {
            "version": document.version,
            "updated_at": utc_now_iso(),
            "entries": [to_plain(entry) for entry in document.entries],
        }
        write_json(self.memory_file, payload)

    def append_patch(self, patch: dict[str, Any]) -> None:
        append_jsonl(self.patches_file, patch)

    def append_conflict(self, conflict: Any) -> None:
        append_jsonl(self.conflicts_file, conflict)

    def append_issue(self, issue: Any) -> None:
        append_jsonl(self.issues_file, issue)

    def write_snapshot(self, document: MemoryDocument, index: int) -> Path:
        self.snapshots_dir.mkdir(parents=True, exist_ok=True)
        path = self.snapshots_dir / f"memory_{index:04d}.json"
        write_json(
            path,
            {
                "version": document.version,
                "snapshot_index": index,
                "created_at": utc_now_iso(),
                "entries": [to_plain(entry) for entry in document.entries],
            },
        )
        return path
