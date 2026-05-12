from __future__ import annotations

from ..app.models import Segment
from ..utils import to_plain
from .selector import term_matches_text
from .schema import MemoryConsistencyIssue, MemoryDocument, STRONG_MEMORY_STATUSES
from .store import MemoryStore


def check_consistency(document: MemoryDocument, segments: list[Segment]) -> list[MemoryConsistencyIssue]:
    issues: list[MemoryConsistencyIssue] = []
    strong_entries = [
        entry
        for entry in document.entries
        if entry.status in STRONG_MEMORY_STATUSES and entry.source.strip() and entry.target.strip()
    ]
    for seg in segments:
        source_text = seg.text_src or ""
        target_text = seg.text_tgt or ""
        for entry in strong_entries:
            terms = [entry.source, *entry.aliases]
            if any(term_matches_text(term, source_text) for term in terms) and entry.target not in target_text:
                issues.append(
                    MemoryConsistencyIssue(
                        id=seg.id,
                        source=entry.source,
                        expected_target=entry.target,
                        actual_text=target_text,
                        status=entry.status,
                        category=entry.category,
                        message=f"Expected {entry.source} to use {entry.target}",
                    )
                )
    return issues


def write_consistency_issues(store: MemoryStore, issues: list[MemoryConsistencyIssue]) -> None:
    store.issues_file.unlink(missing_ok=True)
    store.issues_file.touch(exist_ok=True)
    for issue in issues:
        store.append_issue(to_plain(issue))
