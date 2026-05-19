from __future__ import annotations

from ..app.models import Segment
from ..utils import to_plain
from .selector import term_matches_text
from .schema import (
    INJECTABLE_MEMORY_STATUSES,
    MemoryConsistencyIssue,
    MemoryDocument,
    MemoryEntry,
    entry_alias_details,
    normalize_constraint,
)
from .store import MemoryStore


HARD_ALIAS_KINDS = {"spelling", "full_name"}
VARIANT_ALIAS_KINDS = {"nickname", "honorific"}
SUGGESTION_ALIAS_KINDS = {"asr_error", "phrase_fragment", "broad_hint"}


def _contains_any_target(target_text: str, targets: list[str]) -> bool:
    return any(target and target in target_text for target in targets)


def _entry_targets(entry: MemoryEntry) -> list[str]:
    targets = [entry.target, *[variant.target for variant in entry.target_variants]]
    out: list[str] = []
    for target in targets:
        target = str(target or "").strip()
        if target and target not in out:
            out.append(target)
    return out


def _qa_policy(entry: MemoryEntry, *, variant: bool = False, alias_kind: str = "") -> str:
    explicit = entry.enforcement_policy.get("qa") if isinstance(entry.enforcement_policy, dict) else ""
    if explicit:
        return str(explicit)
    constraint = entry.constraint or normalize_constraint("", status=entry.status)
    if entry.memory_type == "concept_hint":
        return "off"
    if constraint == "hint":
        return "off"
    if variant or alias_kind in VARIANT_ALIAS_KINDS:
        return "warning"
    if alias_kind in SUGGESTION_ALIAS_KINDS:
        return "info"
    if entry.status == "locked" or constraint == "must_use":
        return "error"
    return "warning"


def _issue_level(policy: str) -> str:
    if policy == "error":
        return "warning"
    if policy == "warning":
        return "suggestion"
    return "suggestion"


def _accepted_targets_for_alias(entry: MemoryEntry, alias_source: str, alias_kind: str) -> list[str]:
    if alias_kind in {"nickname", "honorific"}:
        targets: list[str] = []
        for variant in entry.target_variants:
            if variant.source == alias_source or variant.kind == alias_kind:
                targets.append(variant.target)
        if not targets:
            targets.append(entry.target)
        out: list[str] = []
        for target in targets:
            if target and target not in out:
                out.append(target)
        return out
    if alias_kind == "asr_error":
        return _entry_targets(entry)
    return [entry.target] if entry.target else []


def _matched_variant_sources(entry: MemoryEntry, source_text: str) -> list[str]:
    return [
        variant.source
        for variant in entry.target_variants
        if term_matches_text(variant.source, source_text)
    ]


def _matched_address_alias_sources(entry: MemoryEntry, source_text: str) -> list[str]:
    return [
        alias.source
        for alias in entry_alias_details(entry)
        if alias.kind in VARIANT_ALIAS_KINDS and term_matches_text(alias.source, source_text)
    ]


def _issue(
    *,
    seg: Segment,
    entry: MemoryEntry,
    expected: str,
    target_text: str,
    level: str,
    issue_type: str,
    matched_source: str,
    matched_kind: str,
    expected_variants: list[str],
) -> MemoryConsistencyIssue:
    return MemoryConsistencyIssue(
        id=seg.id,
        source=entry.source,
        expected_target=expected,
        actual_text=target_text,
        status=entry.status,
        category=entry.category,
        message=f"Expected {matched_source or entry.source} to use {expected}",
        level=level,
        issue_type=issue_type,
        constraint=entry.constraint or normalize_constraint("", status=entry.status),
        matched_source=matched_source,
        matched_kind=matched_kind,
        expected_variants=expected_variants,
    )


def check_consistency(document: MemoryDocument, segments: list[Segment]) -> list[MemoryConsistencyIssue]:
    issues: list[MemoryConsistencyIssue] = []
    checkable_entries = [
        entry
        for entry in document.entries
        if entry.status in INJECTABLE_MEMORY_STATUSES and entry.source.strip() and entry.target.strip()
    ]
    for seg in segments:
        source_text = seg.text_src or ""
        target_text = seg.text_tgt or ""
        for entry in checkable_entries:
            constraint = entry.constraint or normalize_constraint("", status=entry.status)
            expected_targets = _entry_targets(entry)
            variant_sources = _matched_variant_sources(entry, source_text)
            address_alias_sources = _matched_address_alias_sources(entry, source_text)
            matched_specific_address = bool(variant_sources or address_alias_sources)
            if not matched_specific_address and term_matches_text(entry.source, source_text) and entry.target not in target_text:
                policy = _qa_policy(entry)
                if policy == "off":
                    continue
                level = _issue_level(policy)
                issue_type = "hint_miss" if policy == "info" else "hard_miss"
                issues.append(
                    _issue(
                        seg=seg,
                        entry=entry,
                        expected=entry.target,
                        target_text=target_text,
                        level=level,
                        issue_type=issue_type,
                        matched_source=entry.source,
                        matched_kind="canonical",
                        expected_variants=expected_targets,
                    )
                )
            for alias in entry_alias_details(entry):
                if not term_matches_text(alias.source, source_text):
                    continue
                accepted_targets = _accepted_targets_for_alias(entry, alias.source, alias.kind)
                if _contains_any_target(target_text, accepted_targets):
                    continue
                policy = _qa_policy(entry, alias_kind=alias.kind)
                if policy == "off":
                    continue
                if alias.kind in HARD_ALIAS_KINDS and constraint == "must_use":
                    issues.append(
                        _issue(
                            seg=seg,
                            entry=entry,
                            expected=entry.target,
                            target_text=target_text,
                            level="warning",
                            issue_type="hard_miss",
                            matched_source=alias.source,
                            matched_kind=alias.kind,
                            expected_variants=accepted_targets,
                        )
                    )
                elif alias.kind in VARIANT_ALIAS_KINDS:
                    issues.append(
                        _issue(
                            seg=seg,
                            entry=entry,
                            expected=accepted_targets[0] if accepted_targets else entry.target,
                            target_text=target_text,
                            level=_issue_level(policy),
                            issue_type="variant_miss",
                            matched_source=alias.source,
                            matched_kind=alias.kind,
                            expected_variants=accepted_targets,
                        )
                    )
                elif alias.kind in SUGGESTION_ALIAS_KINDS or constraint == "hint" or entry.memory_type == "concept_hint":
                    if policy == "off":
                        continue
                    issues.append(
                        _issue(
                            seg=seg,
                            entry=entry,
                            expected=entry.target,
                            target_text=target_text,
                            level="suggestion",
                            issue_type="hint_miss",
                            matched_source=alias.source,
                            matched_kind=alias.kind,
                            expected_variants=accepted_targets,
                        )
                    )
            for variant in entry.target_variants:
                if not term_matches_text(variant.source, source_text):
                    continue
                accepted = [entry.target, variant.target]
                if _contains_any_target(target_text, accepted):
                    continue
                policy = _qa_policy(entry, variant=True)
                if policy == "off":
                    continue
                issues.append(
                    _issue(
                        seg=seg,
                        entry=entry,
                        expected=variant.target,
                        target_text=target_text,
                        level=_issue_level(policy),
                        issue_type="variant_miss",
                        matched_source=variant.source,
                        matched_kind=variant.kind,
                        expected_variants=accepted,
                    )
                )
    return issues


def write_consistency_issues(store: MemoryStore, issues: list[MemoryConsistencyIssue]) -> None:
    store.issues_file.unlink(missing_ok=True)
    store.issues_file.touch(exist_ok=True)
    for issue in issues:
        store.append_issue(to_plain(issue))
