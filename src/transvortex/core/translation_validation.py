from __future__ import annotations

import re
from dataclasses import dataclass, field

from ..app.models import Chunk


NUMBERED_LINE_RE = re.compile(r"^\[(\d+)\]\s*(.*)$")
ALT_NUMBERED_LINE_RE = re.compile(r"^(?:\(?\s*(\d+)\s*\)?|（\s*(\d+)\s*）)\s*[:：.)、-]\s*(.*)$")
REFUSAL_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\bi\s+can(?:not|'t)\s+(?:help|assist|translate|provide)\b",
        r"\bi\s+cannot\s+translate\b",
        r"\bas\s+an\s+ai\b",
        r"\bunable\s+to\s+(?:assist|comply|translate)\b",
        r"\bviolat(?:e|es|ing)\s+(?:policy|guidelines)\b",
        r"无法(?:协助|帮助|翻译|提供)",
        r"不能(?:协助|帮助|翻译|提供)",
        r"违反(?:政策|规定)",
    ]
]
PROTOCOL_MARKER_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\b(?:assistant|developer|system)\s+(?:analysis|commentary|final)\b",
        r"<\|(?:assistant|developer|system|analysis|commentary|final)\|>",
    ]
]


@dataclass
class ParsedTranslationRow:
    id: int
    text_tgt: str


@dataclass
class TranslationValidationIssue:
    code: str
    level: str
    message: str
    segment_id: int | None = None
    repairable: bool = False


@dataclass
class TranslationValidationResult:
    chunk_id: str
    rows: list[ParsedTranslationRow]
    issues: list[TranslationValidationIssue] = field(default_factory=list)

    @property
    def errors(self) -> list[TranslationValidationIssue]:
        return [issue for issue in self.issues if issue.level == "ERROR"]

    @property
    def repairable_errors(self) -> list[TranslationValidationIssue]:
        return [issue for issue in self.errors if issue.repairable and issue.segment_id is not None]

    @property
    def has_chunk_errors(self) -> bool:
        return any(issue.level == "ERROR" and not issue.repairable for issue in self.issues)


def strip_numbered_text(line: str) -> tuple[int, str]:
    match = NUMBERED_LINE_RE.match(line.strip())
    if match:
        return int(match.group(1)), match.group(2).strip()
    match = ALT_NUMBERED_LINE_RE.match(line.strip())
    if match:
        seg_id = match.group(1) or match.group(2)
        return int(seg_id), match.group(3).strip()
    raise RuntimeError(f"Bad translated line format: {line}")


def contains_refusal(text: str) -> bool:
    return any(pattern.search(text) for pattern in REFUSAL_PATTERNS)


def contains_protocol_marker(text: str) -> bool:
    return any(pattern.search(text) for pattern in PROTOCOL_MARKER_PATTERNS)


def _context_ids(chunk: Chunk) -> set[int]:
    ids: set[int] = set()
    for line in [*chunk.context_before, *chunk.context_after]:
        match = NUMBERED_LINE_RE.match(line.strip())
        if match:
            ids.add(int(match.group(1)))
    return ids


def _raw_has_explanatory_lines(raw_text: str) -> bool:
    for line in raw_text.splitlines():
        stripped = line.strip()
        if stripped and not NUMBERED_LINE_RE.match(stripped) and not ALT_NUMBERED_LINE_RE.match(stripped):
            return True
    return False


def parse_numbered_rows(numbered_lines: list[str]) -> tuple[list[ParsedTranslationRow], list[TranslationValidationIssue]]:
    rows: list[ParsedTranslationRow] = []
    issues: list[TranslationValidationIssue] = []
    for line in numbered_lines:
        try:
            seg_id, text = strip_numbered_text(line)
        except RuntimeError as exc:
            issues.append(
                TranslationValidationIssue(
                    code="bad_line_format",
                    level="ERROR",
                    message=str(exc),
                    repairable=False,
                )
            )
            continue
        rows.append(ParsedTranslationRow(id=seg_id, text_tgt=text))
    return rows, issues


def validate_translation_response(
    *,
    chunk: Chunk,
    numbered_lines: list[str],
    raw_text: str,
    refusal_detection_enabled: bool = True,
) -> TranslationValidationResult:
    rows, issues = parse_numbered_rows(numbered_lines)
    expected_ids = set(chunk.segment_ids)
    context_ids = _context_ids(chunk)
    seen: dict[int, int] = {}
    by_id: dict[int, ParsedTranslationRow] = {}
    for row in rows:
        seen[row.id] = seen.get(row.id, 0) + 1
        by_id.setdefault(row.id, row)

    if raw_text.strip() and refusal_detection_enabled and not rows and contains_refusal(raw_text):
        issues.append(
            TranslationValidationIssue(
                code="refusal_output",
                level="ERROR",
                message="model output appears to be a refusal instead of translations",
                repairable=False,
            )
        )
        return TranslationValidationResult(chunk_id=chunk.chunk_id, rows=rows, issues=issues)
    elif raw_text.strip() and _raw_has_explanatory_lines(raw_text):
        issues.append(
            TranslationValidationIssue(
                code="explanatory_output",
                level="ERROR",
                message="model output contains non-numbered explanatory text",
                repairable=False,
            )
        )

    for seg_id, count in seen.items():
        if count > 1 and seg_id in expected_ids:
            issues.append(
                TranslationValidationIssue(
                    code="duplicate_id",
                    level="ERROR",
                    message=f"duplicate translation id: {seg_id}",
                    segment_id=seg_id,
                    repairable=False,
                )
            )

    for row in rows:
        if row.id in context_ids and row.id not in expected_ids:
            issues.append(
                TranslationValidationIssue(
                    code="context_id_output",
                    level="ERROR",
                    message=f"model translated context id: {row.id}",
                    segment_id=row.id,
                    repairable=False,
                )
            )
        elif row.id not in expected_ids:
            issues.append(
                TranslationValidationIssue(
                    code="extra_id",
                    level="ERROR",
                    message=f"unexpected translation id: {row.id}",
                    segment_id=row.id,
                    repairable=False,
                )
            )

    for seg_id in sorted(expected_ids):
        row = by_id.get(seg_id)
        if row is None:
            issues.append(
                TranslationValidationIssue(
                    code="missing_id",
                    level="ERROR",
                    message=f"missing translation id: {seg_id}",
                    segment_id=seg_id,
                    repairable=True,
                )
            )
            continue
        if not row.text_tgt:
            issues.append(
                TranslationValidationIssue(
                    code="empty_translation",
                    level="ERROR",
                    message=f"empty translation for id: {seg_id}",
                    segment_id=seg_id,
                    repairable=True,
                )
            )
            continue
        if contains_protocol_marker(row.text_tgt):
            issues.append(
                TranslationValidationIssue(
                    code="protocol_marker",
                    level="ERROR",
                    message=f"translation contains an internal protocol marker for id: {seg_id}",
                    segment_id=seg_id,
                    repairable=True,
                )
            )

    return TranslationValidationResult(chunk_id=chunk.chunk_id, rows=rows, issues=issues)


def validation_to_json(result: TranslationValidationResult) -> dict:
    return {
        "chunk_id": result.chunk_id,
        "issues": [
            {
                "code": issue.code,
                "level": issue.level,
                "message": issue.message,
                "segment_id": issue.segment_id,
                "repairable": issue.repairable,
            }
            for issue in result.issues
        ],
    }
