from __future__ import annotations

import re

from ..app.models import Chunk, MemoryInjectConfig
from .schema import MEMORY_STATUS_ORDER, MemoryDocument, MemoryEntry, entry_alias_details


def _entry_terms(entry: MemoryEntry) -> list[str]:
    variant_sources = [variant.source for variant in entry.target_variants]
    alias_sources = [alias.source for alias in entry_alias_details(entry)]
    return [term for term in [entry.source, *alias_sources, *variant_sources] if term.strip()]


def term_matches_text(term: str, text: str) -> bool:
    term = term.strip()
    if not term:
        return False
    if len(term) <= 2 and term.isascii() and term.isalnum():
        return False
    if not term.isascii():
        if len(term) <= 1:
            return False
        return term.casefold() in text.casefold()
    pattern = re.compile(rf"(?<![\w]){re.escape(term)}(?![\w])", re.IGNORECASE)
    return bool(pattern.search(text))


def entry_matches_text(entry: MemoryEntry, text: str) -> bool:
    return any(term_matches_text(term, text) for term in _entry_terms(entry))


def _normalized_strategy(value: str) -> str:
    value = str(value or "balanced").strip().lower()
    return value if value in {"balanced", "full", "matched"} else "balanced"


def _allowed_statuses(inject_config: MemoryInjectConfig) -> set[str]:
    allowed = set()
    if inject_config.locked:
        allowed.add("locked")
    if inject_config.confirmed:
        allowed.add("confirmed")
    if inject_config.proposed:
        allowed.add("proposed")
    return allowed


def _should_include_entry(
    entry: MemoryEntry,
    *,
    text: str,
    strategy: str,
    confirmed_count: int,
    max_entries: int,
) -> bool:
    if strategy == "matched":
        return entry_matches_text(entry, text)
    if entry.status == "locked" and strategy in {"balanced", "full"}:
        return True
    if entry.status == "confirmed":
        if strategy == "full":
            return True
        if strategy == "balanced" and confirmed_count <= max_entries:
            return True
    return entry_matches_text(entry, text)


def select_memory_entries(
    document: MemoryDocument,
    chunk: Chunk,
    inject_config: MemoryInjectConfig,
) -> list[MemoryEntry]:
    text = "\n".join([*chunk.context_before, *chunk.lines, *chunk.context_after])
    max_entries = max(0, inject_config.max_entries_per_chunk)
    if max_entries <= 0:
        return []
    strategy = _normalized_strategy(inject_config.strategy)
    allowed = _allowed_statuses(inject_config)
    confirmed_count = sum(1 for entry in document.entries if entry.status == "confirmed" and entry.source.strip())
    matches = [
        entry
        for entry in document.entries
        if entry.status in allowed
        and entry.source.strip()
        and _should_include_entry(
            entry,
            text=text,
            strategy=strategy,
            confirmed_count=confirmed_count,
            max_entries=max_entries,
        )
    ]
    matches.sort(
        key=lambda entry: (
            MEMORY_STATUS_ORDER.get(entry.status, 99),
            -int(entry.priority),
            -float(entry.confidence),
            entry.source.casefold(),
        )
    )
    return matches[:max_entries]
