from __future__ import annotations

from collections import defaultdict

from .schema import MemoryAlias, MemoryEntry, entry_alias_details


SECTION_TITLES = {
    "locked": "LOCKED TERMS",
    "confirmed": "CONFIRMED MEMORY",
    "proposed": "PROPOSED HINTS",
}

HARD_ALIAS_KINDS = {"spelling", "full_name"}
ADDRESS_ALIAS_KINDS = {"nickname", "honorific"}
ASR_ALIAS_KINDS = {"asr_error"}
HINT_ALIAS_KINDS = {"phrase_fragment", "broad_hint"}


def _format_entry(entry: MemoryEntry) -> str:
    target = entry.target or "(unresolved)"
    suffix = f" ({entry.notes})" if entry.notes else ""
    hard_aliases = [
        alias.source
        for alias in entry_alias_details(entry)
        if alias.kind in HARD_ALIAS_KINDS
    ]
    aliases = f"; aliases: {', '.join(hard_aliases)}" if hard_aliases else ""
    constraint = f"; constraint: {entry.constraint}" if entry.constraint else ""
    memory_type = f"; type: {entry.memory_type}" if entry.memory_type else ""
    return f"- {entry.source} => {target}{aliases}{constraint}{memory_type}{suffix}"


def _format_alias(alias: MemoryAlias, entry: MemoryEntry) -> str:
    target = entry.target or "(unresolved)"
    suffix = f" ({entry.notes})" if entry.notes else ""
    return f"- {alias.source} => {target}; canonical: {entry.source}; kind: {alias.kind}{suffix}"


def _format_variant(entry: MemoryEntry) -> list[str]:
    rows = []
    for variant in entry.target_variants:
        rows.append(
            f"- {variant.source} => {variant.target}; canonical: {entry.source} => {entry.target}; kind: {variant.kind}"
        )
    for alias in entry_alias_details(entry):
        if alias.kind in ADDRESS_ALIAS_KINDS:
            rows.append(f"- {alias.source}: same entity as {entry.source}; preserve address tone when translating")
    return rows


def build_memory_prompt(entries: list[MemoryEntry]) -> str:
    if not entries:
        return ""
    grouped: dict[str, list[MemoryEntry]] = defaultdict(list)
    address_rows: list[str] = []
    asr_rows: list[str] = []
    concept_rows: list[str] = []
    for entry in entries:
        if entry.status in SECTION_TITLES:
            grouped[entry.status].append(entry)
        address_rows.extend(_format_variant(entry))
        for alias in entry_alias_details(entry):
            if alias.kind in ASR_ALIAS_KINDS:
                asr_rows.append(_format_alias(alias, entry))
            elif alias.kind in HINT_ALIAS_KINDS:
                concept_rows.append(_format_alias(alias, entry))
        if entry.memory_type == "concept_hint":
            concept_rows.append(_format_entry(entry))
    parts: list[str] = []
    if grouped.get("locked"):
        parts.append(
            "LOCKED TERMS\n"
            "These translations are mandatory and must not be changed.\n"
            + "\n".join(_format_entry(entry) for entry in grouped["locked"])
        )
    if address_rows:
        parts.append(
            "ADDRESS VARIANTS\n"
            "These refer to the same entity but may need different address tone in the translation.\n"
            + "\n".join(address_rows)
        )
    if asr_rows:
        parts.append(
            "ASR CORRECTION HINTS\n"
            "These source variants may be ASR errors. Use them to recognize the intended canonical term; do not translate the error literally.\n"
            + "\n".join(asr_rows)
        )
    if concept_rows:
        parts.append(
            "CONCEPT HINTS\n"
            "Use these as weak semantic context only; do not force the exact target wording when a natural translation differs.\n"
            + "\n".join(concept_rows)
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

