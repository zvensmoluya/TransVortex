from __future__ import annotations

from pathlib import Path
from typing import Any

from ..app.models import Segment
from ..artifacts.task_store import TaskStore
from ..formats.srt import parse_srt_file
from ..utils import append_jsonl, read_jsonl, write_json
from .asr_quality import detect_asr_boundary_risks
from .pipeline_runtime import _is_nonempty_file
from .source_cleaner import clean_source_segments

def _load_segments_from_raw_jsonl(raw_file: Path) -> list[Segment]:
    rows = read_jsonl(raw_file)
    segments: list[Segment] = []
    for row in rows:
        segments.append(Segment(**row))
    segments.sort(key=lambda x: x.id)
    return segments


def _segments_with_source(segments: list[Segment], source: str) -> list[Segment]:
    out: list[Segment] = []
    for seg in segments:
        meta = dict(seg.meta or {})
        meta.setdefault("source", source)
        out.append(
            Segment(
                id=seg.id,
                start=seg.start,
                end=seg.end,
                text_src=seg.text_src,
                text_tgt=seg.text_tgt,
                confidence=seg.confidence,
                meta=meta,
            )
        )
    return out


def _load_segments_from_input(path: Path, *, source: str = "segments_input") -> list[Segment]:
    if path.suffix.lower() == ".srt":
        return _segments_with_source(parse_srt_file(path), "srt")
    rows = read_jsonl(path)
    segments: list[Segment] = []
    for idx, row in enumerate(rows, start=1):
        if isinstance(row, dict):
            payload = dict(row)
            payload.setdefault("id", idx)
            if "text_src" not in payload and "text" in payload:
                payload["text_src"] = payload.pop("text")
            meta = dict(payload.get("meta") or {})
            meta.setdefault("source", source)
            payload["meta"] = meta
            segments.append(Segment(**payload))
    return sorted(segments, key=lambda seg: seg.id)


def _persist_segments_jsonl(path: Path, segments: list[Segment]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    for seg in segments:
        append_jsonl(path, seg)


def _source_segments_path(paths: dict[str, Path]) -> Path:
    return paths["source"] / "segments.normalized.jsonl"


def _raw_source_segments_path(paths: dict[str, Path]) -> Path:
    return paths["source"] / "segments.raw.jsonl"


def _legacy_asr_segments_path(paths: dict[str, Path]) -> Path:
    return paths["asr"] / "segments.raw.jsonl"


def persist_source_segments(paths: dict[str, Path], segments: list[Segment]) -> Path:
    path = _source_segments_path(paths)
    _persist_segments_jsonl(path, segments)
    return path


def persist_raw_source_segments(paths: dict[str, Path], segments: list[Segment]) -> Path:
    path = _raw_source_segments_path(paths)
    _persist_segments_jsonl(path, segments)
    return path


def load_source_segments(paths: dict[str, Path]) -> list[Segment]:
    source_file = _source_segments_path(paths)
    if _is_nonempty_file(source_file):
        return _load_segments_from_raw_jsonl(source_file)
    legacy_file = _legacy_asr_segments_path(paths)
    if _is_nonempty_file(legacy_file):
        segments = _load_segments_from_raw_jsonl(legacy_file)
        persist_source_segments(paths, segments)
        return segments
    return []


def _clean_asr_source_segments(
    *,
    paths: dict[str, Path],
    segments: list[Segment],
    store: TaskStore | None = None,
    task_id: str = "",
    stage: str = "ASR",
    renumber: bool = True,
) -> list[Segment]:
    result = clean_source_segments(segments, only_asr=True, renumber=renumber)
    paths["quality"].mkdir(parents=True, exist_ok=True)
    report_path = paths["quality"] / "source_cleaning.json"
    write_json(report_path, result.report)
    if result.report.get("dropped_segments") or result.report.get("warning_segments"):
        if store is not None and task_id:
            store.append_event(
                task_id,
                "warning",
                stage=stage,
                level="warning",
                message="Cleaned ASR source segments before normalization",
                details={
                    "path": str(report_path),
                    "input_segments": result.report.get("input_segments", 0),
                    "output_segments": result.report.get("output_segments", 0),
                    "dropped_segments": result.report.get("dropped_segments", 0),
                    "warning_segments": result.report.get("warning_segments", 0),
                    "reason_counts": result.report.get("reason_counts", {}),
                },
            )
    return result.segments


def _mark_asr_boundary_quality(
    *,
    paths: dict[str, Path],
    segments: list[Segment],
    provider: Any,
    store: TaskStore | None = None,
    task_id: str = "",
    stage: str = "ASR",
) -> list[Segment]:
    marked, report = detect_asr_boundary_risks(segments, provider=provider)
    paths["quality"].mkdir(parents=True, exist_ok=True)
    report_path = paths["quality"] / "asr_boundary_quality.json"
    write_json(report_path, report)
    warn_or_error = int(report.get("level_counts", {}).get("warn", 0)) + int(
        report.get("level_counts", {}).get("error", 0)
    )
    if warn_or_error and store is not None and task_id:
        store.append_event(
            task_id,
            "warning",
            stage=stage,
            level="warning",
            message="ASR boundary risk detected",
            details={
                "path": str(report_path),
                "risk_segments": report.get("risk_segments", 0),
                "code_counts": report.get("code_counts", {}),
                "level_counts": report.get("level_counts", {}),
            },
        )
    return marked
