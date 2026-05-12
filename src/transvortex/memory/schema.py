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
    scope: dict[str, Any] = field(default_factory=lambda: {"type": "global"})
    notes: str = ""
    confidence: float = 0.0
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
    notes: str = ""
    origin: str = "model_patch"


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


def normalize_status(value: str) -> str:
    value = str(value or "proposed").strip().lower()
    return value if value in MEMORY_STATUS_ORDER else "proposed"


def normalize_source_key(value: str) -> str:
    return " ".join(str(value or "").strip().casefold().split())


def entry_from_dict(row: dict[str, Any]) -> MemoryEntry:
    return MemoryEntry(
        id=str(row.get("id") or ""),
        source=str(row.get("source") or ""),
        target=str(row.get("target") or ""),
        category=str(row.get("category") or "term"),
        status=normalize_status(str(row.get("status") or "proposed")),
        origin=str(row.get("origin") or "model_patch"),
        priority=int(row.get("priority") or 50),
        aliases=[str(item) for item in row.get("aliases", []) or []],
        scope=dict(row.get("scope") or {"type": "global"}),
        notes=str(row.get("notes") or ""),
        confidence=float(row.get("confidence") or 0.0),
        evidence_ids=[int(item) for item in row.get("evidence_ids", []) or [] if str(item).isdigit()],
        created_by=str(row.get("created_by") or "system"),
        updated_at=str(row.get("updated_at") or ""),
    )


def patch_action_from_dict(row: dict[str, Any]) -> MemoryPatchAction:
    return MemoryPatchAction(
        action=str(row.get("action") or "upsert"),
        source=str(row.get("source") or ""),
        target=str(row.get("target") or ""),
        category=str(row.get("category") or "term"),
        status=normalize_status(str(row.get("status") or "proposed")),
        confidence=float(row.get("confidence") or 0.0),
        evidence_ids=[int(item) for item in row.get("evidence_ids", []) or [] if str(item).isdigit()],
        aliases=[str(item) for item in row.get("aliases", []) or []],
        notes=str(row.get("notes") or ""),
        origin=str(row.get("origin") or "model_patch"),
    )

