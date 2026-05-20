from __future__ import annotations

from dataclasses import dataclass

from ..app.models import MemoryInjectConfig
from .schema import MemoryEntry
from .selector import MemoryFormMatch, SelectedMemoryEntry


TRANSLATE_ZONE = "lines"
CONTEXT_ZONES = {"context_before", "context_after"}
WEAK_POLICIES = {"context_only", "recognize_only"}
UNRESOLVED_ADDRESS_HINT = (
    "infer natural Chinese address flavor from source/context; "
    "do not blindly flatten to canonical"
)


@dataclass
class _RenderLimits:
    intensity: str
    max_prompt_chars: int
    max_context_rows: int | None
    max_background_rows: int | None
    max_weak_rows: int | None
    max_notes_chars: int


def _normalized_intensity(value: str) -> str:
    value = str(value or "high").strip().lower()
    return value if value in {"none", "low", "auto", "high", "max"} else "high"


def _section_caps(intensity: str) -> tuple[int | None, int | None, int | None]:
    if intensity == "none":
        return 0, 0, 0
    if intensity == "low":
        return 0, 0, 0
    if intensity == "auto":
        return 16, 16, 8
    if intensity == "max":
        return None, None, None
    return 48, 48, 24


def _limits(inject_config: MemoryInjectConfig | None) -> _RenderLimits:
    if inject_config is None:
        context_rows, background_rows, weak_rows = _section_caps("high")
        return _RenderLimits(
            intensity="high",
            max_prompt_chars=2400 * 4,
            max_context_rows=context_rows,
            max_background_rows=background_rows,
            max_weak_rows=weak_rows,
            max_notes_chars=60,
        )
    intensity = _normalized_intensity(inject_config.intensity)
    context_rows, background_rows, weak_rows = _section_caps(intensity)
    return _RenderLimits(
        intensity=intensity,
        max_prompt_chars=max(1, int(inject_config.max_prompt_tokens or 2400)) * 4,
        max_context_rows=context_rows,
        max_background_rows=background_rows,
        max_weak_rows=weak_rows,
        max_notes_chars=max(0, int(inject_config.max_notes_chars_per_entry or 0)),
    )


def _can_add_limited(current_count: int, limit: int | None) -> bool:
    return limit is None or current_count < limit


def _note(entry: MemoryEntry, max_chars: int) -> str:
    note = str(entry.notes or "").strip().replace("\n", " ")
    if not note or max_chars <= 0:
        return ""
    if len(note) > max_chars:
        note = note[: max(0, max_chars - 1)].rstrip() + "..."
    return f" | note: {note}"


def _text_note(label: str, text: str, max_chars: int) -> str:
    note = str(text or "").strip().replace("\n", " ")
    if not note or max_chars <= 0:
        return ""
    if len(note) > max_chars:
        note = note[: max(0, max_chars - 1)].rstrip() + "..."
    return f" | {label}: {note}"


def _core_policy(entry: MemoryEntry) -> str:
    explicit = entry.enforcement_policy.get("translation") if isinstance(entry.enforcement_policy, dict) else ""
    if explicit:
        return str(explicit)
    if entry.memory_type == "concept_hint" or entry.constraint == "hint":
        return "context_only"
    if entry.constraint == "must_use" or entry.status == "locked":
        return "exact"
    if entry.constraint == "preferred" or entry.status == "confirmed":
        return "preferred"
    return "recognize_only"


def _match_row(selected: SelectedMemoryEntry, match: MemoryFormMatch, limits: _RenderLimits) -> str:
    entry = selected.entry
    target = match.resolved_target or entry.target or "(unresolved)"
    bits = [
        f"- matched: {match.form}",
        f"kind: {match.kind}",
        f"canonical: {entry.source}",
        f"{match.target_role}: {target}",
        f"policy: {match.policy}",
    ]
    if match.has_target_variant:
        bits.append("target_variant: true")
    elif match.target_variant_status == "missing":
        bits.append("target_variant: missing")
        bits.append(UNRESOLVED_ADDRESS_HINT)
    if entry.memory_type:
        bits.append(f"type: {entry.memory_type}")
    return (
        " | ".join(bits)
        + _text_note("variant_note", match.variant_notes, limits.max_notes_chars)
        + _note(entry, limits.max_notes_chars)
    )


def _background_row(selected: SelectedMemoryEntry, limits: _RenderLimits) -> str:
    entry = selected.entry
    target = entry.target or "(unresolved)"
    bits = [f"- {entry.source} -> {target}", f"policy: {_core_policy(entry)}"]
    if entry.memory_type:
        bits.append(f"type: {entry.memory_type}")
    return " | ".join(bits) + _note(entry, limits.max_notes_chars)


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


def _is_background(selected: SelectedMemoryEntry) -> bool:
    if selected.matches:
        return False
    entry = selected.entry
    if entry.status == "locked" or entry.constraint == "must_use":
        return True
    if entry.status == "confirmed" or entry.constraint == "preferred":
        return True
    return False


def build_memory_prompt(selected_entries: list[SelectedMemoryEntry], inject_config: MemoryInjectConfig | None = None) -> str:
    if not selected_entries:
        return ""
    limits = _limits(inject_config)
    if limits.intensity == "none":
        return ""
    translate_rows: list[str] = []
    context_rows: list[str] = []
    background_rows: list[str] = []
    weak_rows: list[str] = []
    background_count = 0
    weak_count = 0
    context_count = 0

    for selected in selected_entries:
        for match in selected.matches:
            row = _match_row(selected, match, limits)
            if match.zone == TRANSLATE_ZONE and match.policy not in {"context_only"}:
                translate_rows.append(row)
            elif match.policy in WEAK_POLICIES or match.kind in {"phrase_fragment", "broad_hint"}:
                if _can_add_limited(weak_count, limits.max_weak_rows):
                    weak_rows.append(row + " | do not force exact wording")
                    weak_count += 1
            elif match.zone in CONTEXT_ZONES:
                if _can_add_limited(context_count, limits.max_context_rows):
                    context_rows.append(row)
                    context_count += 1
            else:
                if _can_add_limited(context_count, limits.max_context_rows):
                    context_rows.append(row)
                    context_count += 1
        if _is_background(selected):
            if _can_add_limited(background_count, limits.max_background_rows):
                background_rows.append(_background_row(selected, limits))
                background_count += 1

    parts = [
        "TRANSLATION MEMORY\n"
        "Use matched rows according to policy. exact is mandatory; preferred is stable but natural; "
        "style_sensitive preserves nickname/address flavor; style_sensitive_unresolved means infer a natural "
        "address form from source/context without blindly flattening to canonical; recognize_only/context_only "
        "are weak hints."
    ]
    _append_budgeted(parts, "MATCHED_IN_TRANSLATE_ONLY", translate_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "MATCHED_IN_CONTEXT", context_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "BACKGROUND_MEMORY", background_rows, limits.max_prompt_chars)
    _append_budgeted(parts, "WEAK_HINTS", weak_rows, limits.max_prompt_chars)
    return "\n\n".join(parts)
