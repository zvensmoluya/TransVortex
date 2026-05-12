from __future__ import annotations

from pathlib import Path
from typing import Any

from ..utils import append_jsonl, read_json, to_plain, utc_now_iso, write_json
from .schema import MemoryDocument, MemoryEntry, entry_from_dict


class MemoryStore:
    def __init__(self, memory_dir: Path) -> None:
        self.memory_dir = memory_dir

    @property
    def memory_file(self) -> Path:
        return self.memory_dir / "translation_memory.json"

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
        if not self.memory_file.exists():
            self.save(MemoryDocument())

    def ensure_with_seed(self, seed_file: Path | None = None) -> None:
        self.memory_dir.mkdir(parents=True, exist_ok=True)
        self.snapshots_dir.mkdir(parents=True, exist_ok=True)
        self.patches_file.touch(exist_ok=True)
        self.conflicts_file.touch(exist_ok=True)
        self.decisions_file.touch(exist_ok=True)
        self.issues_file.touch(exist_ok=True)
        if self.memory_file.exists():
            return
        if seed_file is not None and seed_file.exists():
            data = read_json(seed_file)
            entries = [entry_from_dict(row) for row in data.get("entries", []) if isinstance(row, dict)]
            self.save(MemoryDocument(version=int(data.get("version") or 1), entries=entries))
            return
        self.save(MemoryDocument())

    def load(self) -> MemoryDocument:
        self.ensure()
        data = read_json(self.memory_file)
        entries = [entry_from_dict(row) for row in data.get("entries", []) if isinstance(row, dict)]
        return MemoryDocument(version=int(data.get("version") or 1), entries=entries)

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


def seed_memory_document(entries: list[MemoryEntry] | None = None) -> MemoryDocument:
    return MemoryDocument(version=1, entries=list(entries or []))
