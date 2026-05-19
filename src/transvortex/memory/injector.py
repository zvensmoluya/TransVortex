from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Any

from ..app.models import MemoryInjectConfig
from .schema import MemoryAlias, MemoryEntry, entry_alias_details


ADDRESS_ALIAS_KINDS = {"nickname", "honorific"}
ASR_ALIAS_KINDS = {"asr_error"}
HINT_ALIAS_KINDS = {"phrase_fragment", "broad_hint"}


@dataclass
class _RenderLimits:
    max_prompt_chars: int
    max_proposed_entries: int
    max_context_only_entries: int
    max_notes_chars: int


def _policy(entry: MemoryEntry, *, variant: bool = False) -> str:
    explicit = entry.enforcement_policy.get("translation") if isinstance(entry.enforcement_policy, dict) else ""
    if explicit:
        return str(explicit)
    if variant:
        return "style_sensitive"
    if entry.memory_type == "concept_hint":
        return "context_only"
    if entry.constraint == "must_use" or entry.status == "locked":
        return "exact"
    if entry.constraint == "preferred" or entry.status == "confirmed":
        return "preferred"
    return "recognize_only"


def _note(entry: MemoryEntry, max_chars: int) -> str:
    note = str(entry.notes or "").strip().replace("\n", " ")
    if not note or max_chars <= 0:
        return ""
    if len(note) > max_chars:
        note = note[: max(0, max_chars - 1)].rstrip() + "..."
    return f" | note: {note}"


def _hard_aliases(entry: MemoryEntry) -> list[str]:
    return [alias.source for alias in entry_alias_details(entry) if alias.kind in {"spelling", "full_name"}]


def _asr_aliases(entry: MemoryEntry) -> list[str]:
    return [alias.source for alias in entry_alias_details(entry) if alias.kind in ASR_ALIAS_KINDS]


def _hint_aliases(entry: MemoryEntry) -> list[MemoryAlias]:
    return [alias for alias in entry_alias_details(entry) if alias.kind in HINT_ALIAS_KINDS]


def _address_alias_sources(entry: MemoryEntry) -> list[str]:
    variant_sources = {variant.source for variant in entry.target_variants}
    return [
        alias.source
        for alias in entry_alias_details(entry)
        if alias.kind in ADDRESS_ALIAS_KINDS and alias.source not in variant_sources
    ]


def _format_core(entry: MemoryEntry, limits: _RenderLimits) -> str:
    target = entry.target or "(unresolved)"
    bits = [f"- {entry.source} -> {target}"]
    aliases = _hard_aliases(entry)
    if aliases:
        bits.append("aliases: " + ", ".join(aliases))
    asr = _asr_aliases(entry)
    if asr:
        bits.append("asr: " + ", ".join(asr))
    bits.append(f"policy: {_policy(entry)}")
    if entry.memory_type:
        bits.append(f"type: {entry.memory_type}")
    return " | ".join(bits) + _note(entry, limits.max_notes_chars)


def _format_address(entry: MemoryEntry, limits: _RenderLimits) -> list[str]:
    rows: list[str] = []
    variants = defaultdict(list)
    for variant in entry.target_variants:
        variants[(variant.target, variant.kind)].append(variant.source)
    for (target, kind), sources in variants.items():
        scope_bits: list[str] = []
        for variant in entry.target_variants:
            if variant.target == target and variant.kind == kind and variant.speaker_scope:
                scope = ", ".join(f"{k}={v}" for k, v in variant.speaker_scope.items())
                scope_bits.append(scope)
        scope = f" | speaker_scope: {'; '.join(scope_bits)}" if scope_bits else ""
        rows.append(
            f"- {entry.source} -> {entry.target or '(unresolved)'} | variant: "
            f"{'/'.join(sources)} -> {target} | kind: {kind} | policy: style_sensitive, do not flatten{scope}"
        )
    for source in _address_alias_sources(entry):
        rows.append(
            f"- {entry.source} -> {entry.target or '(unresolved)'} | variant: {source} -> (unresolved) "
            "| policy: preserve address tone, do not blindly force canonical target"
        )
    return [row + _note(entry, limits.max_notes_chars) for row in rows]


def _format_asr(entry: MemoryEntry, limits: _RenderLimits) -> list[str]:
    rows: list[str] = []
    for alias in entry_alias_details(entry):
        if alias.kind not in ASR_ALIAS_KINDS:
            continue
        target = entry.target or "(unresolved)"
        variant_target = next(
            (variant.target for variant in entry.target_variants if variant.source == alias.source),
            "",
        )
        if variant_target:
            rows.append(
                f"- observed: {alias.source} | intended: {entry.source} | target: {variant_target} "
                "| policy: recognize ASR as address variant; do not flatten"
            )
        else:
            rows.append(
                f"- observed: {alias.source} | intended: {entry.source} | target: {target} "
                "| policy: recognize source, do not translate ASR literally"
            )
    return [row + _note(entry, limits.max_notes_chars) for row in rows]


def _format_weak(entry: MemoryEntry, limits: _RenderLimits) -> list[str]:
    rows: list[str] = []
    if entry.memory_type == "concept_hint" or entry.constraint == "hint":
        target = entry.target or "(unresolved)"
        rows.append(f"- {entry.source} -> {target} | policy: {_policy(entry)}; do not force exact wording")
    for alias in _hint_aliases(entry):
        target = entry.target or "(unresolved)"
        rows.append(
            f"- hint: {alias.source} | canonical: {entry.source} | target: {target} "
            "| policy: context only; do not force exact wording"
        )
    return [row + _note(entry, limits.max_notes_chars) for row in rows]


def _limits(inject_config: MemoryInjectConfig | None) -> _RenderLimits:
    if inject_config is None:
        return _RenderLimits(
            max_prompt_chars=1200 * 4,
            max_proposed_entries=12,
            max_context_only_entries=10,
            max_notes_chars=60,
        )
    return _RenderLimits(
        max_prompt_chars=max(1, int(inject_config.max_prompt_tokens or 1200)) * 4,
        max_proposed_entries=max(0, int(inject_config.max_proposed_entries or 0)),
        max_context_only_entries=max(0, int(inject_config.max_context_only_entries or 0)),
        max_notes_chars=max(0, int(inject_config.max_notes_chars_per_entry or 0)),
    )


def _append_budgeted(parts: list[str], section: str, rows: list[str], max_chars: int) -> None:
    if not rows:
        return
    text = section + "\n" + "\n".join(rows)
    candidate = "\n\n".join([*parts, text]) if parts else text
    if len(candidate) <= max_chars:
        parts.append(text)
        return
    kept: list[str] = []
    for row in rows:
        trial = section + "\n" + "\n".join([*kept, row])
        candidate = "\n\n".join([*parts, trial]) if parts else trial
        if len(candidate) > max_chars:
            break
        kept.append(row)
    if kept:
        parts.append(section + "\n" + "\n".join(kept))


def build_memory_prompt(entries: list[MemoryEntry], inject_config: MemoryInjectConfig | None = None) -> str:
    if not entries:
        return ""
    limits = _limits(inject_config)
    must_rows: list[str] = []
    preferred_rows: list[str] = []
    address_rows: list[str] = []
    asr_rows: list[str] = []
    weak_rows: list[str] = []
    proposed_count = 0
    weak_count = 0

    for entry in entries:
        address_rows.extend(_format_address(entry, limits))
        asr_rows.extend(_format_asr(entry, limits))
        if entry.status == "locked" or entry.constraint == "must_use":
            must_rows.append(_format_core(entry, limits))
        elif entry.status == "confirmed" or entry.constraint == "preferred":
            preferred_rows.append(_format_core(entry, limits))
        elif entry.status == "proposed":
            if proposed_count < limits.max_proposed_entries:
                preferred_rows.append(_format_core(entry, limits))
                proposed_count += 1
        weak = _format_weak(entry, limits)
        if weak:
            remaining = max(0, limits.max_context_only_entries - weak_count)
            weak_rows.extend(weak[:remaining])
            weak_count += min(len(weak), remaining)

    parts = [
        "TRANSLATION MEMORY\n"
        "Use according to policy. exact is mandatory; preferred is stable but natural; "
        "style_sensitive preserves nickname/address flavor; recognize_only/context_only are weak hints."
    ]
    _append_budgeted(parts, "MUST_USE", must_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "ADDRESS_VARIANTS", address_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "ASR_CORRECTIONS", asr_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "PREFERRED", preferred_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "WEAK_HINTS", weak_rows, limits.max_prompt_chars)
    return "\n\n".join(parts)
