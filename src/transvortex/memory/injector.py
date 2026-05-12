from __future__ import annotations

from collections import defaultdict

from .schema import MemoryEntry


SECTION_TITLES = {
    "locked": "LOCKED GLOSSARY",
    "confirmed": "CONFIRMED MEMORY",
    "proposed": "PROPOSED HINTS",
}


def _format_entry(entry: MemoryEntry) -> str:
    target = entry.target or "(unresolved)"
    suffix = f" ({entry.notes})" if entry.notes else ""
    aliases = f"; aliases: {', '.join(entry.aliases)}" if entry.aliases else ""
    return f"- {entry.source} => {target}{aliases}{suffix}"


def build_memory_prompt(entries: list[MemoryEntry]) -> str:
    if not entries:
        return ""
    grouped: dict[str, list[MemoryEntry]] = defaultdict(list)
    for entry in entries:
        if entry.status in SECTION_TITLES:
            grouped[entry.status].append(entry)
    parts: list[str] = []
    if grouped.get("locked"):
        parts.append(
            "LOCKED GLOSSARY\n"
            "These translations are mandatory and must not be changed.\n"
            + "\n".join(_format_entry(entry) for entry in grouped["locked"])
        )
    if grouped.get("confirmed"):
        parts.append(
            "CONFIRMED MEMORY\n"
            "Use these translations consistently unless the source text clearly refers to something else.\n"
            + "\n".join(_format_entry(entry) for entry in grouped["confirmed"])
        )
    if grouped.get("proposed"):
        parts.append(
            "PROPOSED HINTS\n"
            "Use these as weak context only; do not force them when context disagrees.\n"
            + "\n".join(_format_entry(entry) for entry in grouped["proposed"])
        )
    return "\n\n".join(parts)

