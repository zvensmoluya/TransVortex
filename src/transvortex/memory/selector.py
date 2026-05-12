from __future__ import annotations

import re

from ..app.models import Chunk, MemoryInjectConfig
from .schema import MEMORY_STATUS_ORDER, MemoryDocument, MemoryEntry


def _entry_terms(entry: MemoryEntry) -> list[str]:
    return [term for term in [entry.source, *entry.aliases] if term.strip()]


def term_matches_text(term: str, text: str) -> bool:
    term = term.strip()
    if not term:
        return False
    if len(term) <= 2 and term.isascii() and term.isalnum():
        return False
    pattern = re.compile(rf"(?<![\w]){re.escape(term)}(?![\w])", re.IGNORECASE)
    return bool(pattern.search(text))


def entry_matches_text(entry: MemoryEntry, text: str) -> bool:
    return any(term_matches_text(term, text) for term in _entry_terms(entry))


def select_memory_entries(
    document: MemoryDocument,
    chunk: Chunk,
    inject_config: MemoryInjectConfig,
) -> list[MemoryEntry]:
    text = "\n".join([*chunk.context_before, *chunk.lines, *chunk.context_after])
    allowed = set()
    if inject_config.locked:
        allowed.add("locked")
    if inject_config.confirmed:
        allowed.add("confirmed")
    if inject_config.proposed:
        allowed.add("proposed")
    matches = [
        entry
        for entry in document.entries
        if entry.status in allowed and entry.source.strip() and entry_matches_text(entry, text)
    ]
    matches.sort(
        key=lambda entry: (
            MEMORY_STATUS_ORDER.get(entry.status, 99),
            -int(entry.priority),
            -float(entry.confidence),
            entry.source.casefold(),
        )
    )
    return matches[: max(0, inject_config.max_entries_per_chunk)]
