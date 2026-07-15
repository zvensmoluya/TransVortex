from __future__ import annotations

from pathlib import Path
from typing import Any

from ..app.config import load_app_config
from ..app.models import Segment
from ..core.subtitle_optimizer import evaluate_subtitle_quality
from ..formats.exporter import export_ass, export_lrc, export_srt, export_vtt, subtitle_delivery_report
from ..memory.schema import entry_from_dict, normalize_status
from ..memory.store import MemoryStore
from ..utils import read_json, read_jsonl, to_plain, write_json
from .task_store import TaskStore


def _task_paths(store: TaskStore, task_id: str) -> dict[str, Path]:
    base = store.task_dir(task_id)
    return {
        "base": base,
        "final": base / "final",
        "translate": base / "translate",
        "output": base / "output",
        "quality": base / "quality",
        "memory": base / "memory",
    }


def _segment_from_payload(row: dict[str, Any]) -> Segment:
    return Segment(
        id=int(row["id"]),
        start=float(row["start"]),
        end=float(row["end"]),
        text_src=str(row.get("text_src", "")),
        text_tgt=None if row.get("text_tgt") is None else str(row.get("text_tgt", "")),
        confidence=row.get("confidence"),
        meta=dict(row.get("meta") or {}),
    )


def _translation_meta_by_segment(translated_rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    out: dict[int, dict[str, Any]] = {}
    for chunk in translated_rows:
        provider = chunk.get("provider", "")
        model = chunk.get("model", "")
        compat_mode = chunk.get("compat_mode", "")
        for row in chunk.get("rows", []):
            try:
                seg_id = int(row.get("id"))
            except (TypeError, ValueError):
                continue
            out[seg_id] = {
                "provider": provider,
                "model": model,
                "compat_mode": compat_mode,
                "chunk_id": chunk.get("chunk_id", ""),
            }
    return out


def _quality_by_segment(paths: dict[str, Path]) -> tuple[dict[str, Any], dict[int, list[dict[str, Any]]]]:
    quality_file = paths["quality"] / "subtitle_quality.json"
    if not quality_file.exists():
        return {}, {}
    payload = read_json(quality_file)
    by_id: dict[int, list[dict[str, Any]]] = {}
    for row in payload.get("segments", []):
        try:
            seg_id = int(row.get("id"))
        except (TypeError, ValueError):
            continue
        by_id[seg_id] = list(row.get("issues") or [])
    return dict(payload.get("summary") or {}), by_id


def _reflow_summary(paths: dict[str, Path]) -> dict[str, Any]:
    reflow_file = paths["quality"] / "reflow.jsonl"
    rows = read_jsonl(reflow_file)
    return {
        "enabled": bool(rows),
        "windows": len(rows),
        "reflowed": sum(1 for row in rows if row.get("status") == "reflowed"),
        "failed": sum(1 for row in rows if row.get("status") != "reflowed"),
        "path": str(reflow_file) if reflow_file.exists() else "",
    }


def _delivery_summary(paths: dict[str, Path]) -> dict[str, Any]:
    delivery_file = paths["quality"] / "subtitle_delivery.json"
    if not delivery_file.exists():
        return {}
    payload = read_json(delivery_file)
    if not isinstance(payload, dict):
        return {}
    out: dict[str, Any] = {}
    for fmt, report in payload.items():
        if isinstance(report, dict):
            out[str(fmt)] = dict(report.get("summary") or {})
    return out


def _issues_for_segments(segments: list[Segment], max_cps: int) -> dict[int, list[str]]:
    issues: dict[int, list[str]] = {seg.id: [] for seg in segments}
    sorted_segments = sorted(segments, key=lambda item: (item.start, item.end, item.id))
    prev: Segment | None = None
    for seg in sorted_segments:
        if seg.end <= seg.start:
            issues[seg.id].append("结束时间早于或等于开始时间")
        if prev is not None and seg.start < prev.end:
            issues[seg.id].append("时间轴与上一条重叠")
        if not (seg.text_tgt or "").strip():
            issues[seg.id].append("译文为空")
        duration = max(seg.end - seg.start, 0.1)
        cps = len((seg.text_tgt or seg.text_src or "").strip()) / duration
        if cps > max_cps:
            issues[seg.id].append("字幕阅读速度偏快")
        prev = seg
    return issues


def _manual_edit_issue_summary(segments: list[Segment]) -> tuple[dict[str, int], set[int]]:
    counts = {
        "invalid_timing": 0,
        "timeline_overlap": 0,
        "empty_target": 0,
    }
    segment_ids: set[int] = set()
    previous: Segment | None = None
    for segment in sorted(segments, key=lambda item: (item.start, item.end, item.id)):
        if segment.end <= segment.start:
            counts["invalid_timing"] += 1
            segment_ids.add(segment.id)
        if previous is not None and segment.start < previous.end:
            counts["timeline_overlap"] += 1
            segment_ids.add(segment.id)
        if not (segment.text_tgt or "").strip():
            counts["empty_target"] += 1
            segment_ids.add(segment.id)
        previous = segment
    return counts, segment_ids


def open_task_result(*, root_dir: Path, task_id: str) -> dict[str, Any]:
    config = load_app_config(root_dir=root_dir)
    store = TaskStore(config.pipeline.artifacts_dir)
    task = store.load_task(task_id)
    paths = _task_paths(store, task_id)
    final_file = paths["final"] / "segments.final.json"
    translated_file = paths["translate"] / "segments.translated.jsonl"
    segments = [_segment_from_payload(row) for row in read_json(final_file)] if final_file.exists() else []
    translated_rows = read_jsonl(translated_file)
    meta_by_id = _translation_meta_by_segment(translated_rows)
    quality_summary, quality_by_id = _quality_by_segment(paths)
    reflow_summary = _reflow_summary(paths)
    delivery_summary = _delivery_summary(paths)
    memory_file = paths["memory"] / "translation_memory.json"
    selected_presets_file = paths["memory"] / "selected_presets.json"
    memory_issues_file = paths["memory"] / "consistency_issues.jsonl"
    memory_entries = []
    preset_entries = []
    memory_issues = []
    if memory_file.exists():
        memory_payload = read_json(memory_file)
        memory_entries = list(memory_payload.get("entries") or [])
    if selected_presets_file.exists():
        preset_payload = read_json(selected_presets_file)
        preset_entries = list(preset_payload.get("entries") or [])
    if memory_issues_file.exists():
        memory_issues = read_jsonl(memory_issues_file)
    issues_by_id = _issues_for_segments(segments, config.pipeline.subtitle.quality.hard_max_cps)
    memory_settings = task.settings.get("memory", {}) if isinstance(task.settings.get("memory"), dict) else {}
    memory_enabled = bool(memory_settings.get("enabled", False))
    return {
        "task": {
            **to_plain(task),
            "task_dir": str(paths["base"]),
        },
        "segments": [
            {
                **to_plain(seg),
                "provider": meta_by_id.get(seg.id, {}).get("provider", ""),
                "model": meta_by_id.get(seg.id, {}).get("model", ""),
                "compat_mode": meta_by_id.get(seg.id, {}).get("compat_mode", ""),
                "chunk_id": meta_by_id.get(seg.id, {}).get("chunk_id", ""),
                "issues": issues_by_id.get(seg.id, []),
                "quality_issues": quality_by_id.get(seg.id, []),
            }
            for seg in segments
        ],
        "quality": quality_summary,
        "delivery": delivery_summary,
        "reflow": reflow_summary,
        "memory": {
            "enabled": memory_enabled,
            "bootstrap_enabled": bool((memory_settings.get("bootstrap") or {}).get("enabled", False)) if isinstance(memory_settings.get("bootstrap"), dict) else False,
            "inject_enabled": bool((memory_settings.get("inject") or {}).get("enabled", False)) if isinstance(memory_settings.get("inject"), dict) else False,
            "patch_enabled": bool((memory_settings.get("patch") or {}).get("enabled", False)) if isinstance(memory_settings.get("patch"), dict) else False,
            "entries": len(memory_entries) + len(preset_entries),
            "entry_items": memory_entries,
            "preset_items": preset_entries,
            "issue_items": memory_issues,
            "runtime_entries": len(memory_entries),
            "preset_entries": len(preset_entries),
            "issues": len(memory_issues),
            "paths": {
                "translation_memory": str(memory_file) if memory_file.exists() else "",
                "selected_presets": str(selected_presets_file) if selected_presets_file.exists() else "",
                "consistency_issues": str(memory_issues_file) if memory_issues_file.exists() else "",
            },
        },
        "output_paths": task.output_paths,
    }


def save_task_segments(*, root_dir: Path, task_id: str, segments_payload: list[dict[str, Any]]) -> dict[str, Any]:
    config = load_app_config(root_dir=root_dir)
    store = TaskStore(config.pipeline.artifacts_dir)
    task = store.load_task(task_id)
    segments = sorted([_segment_from_payload(row) for row in segments_payload], key=lambda item: (item.start, item.end, item.id))
    paths = _task_paths(store, task_id)
    write_json(paths["final"] / "segments.final.json", segments)
    quality_report = evaluate_subtitle_quality(segments, config.pipeline.subtitle.quality)
    quality_summary = dict(quality_report.get("summary") or {})
    manual_issue_counts, manual_issue_segment_ids = _manual_edit_issue_summary(segments)
    quality_issue_counts = dict(quality_summary.get("issue_counts") or {})
    quality_residual_counts = dict(quality_summary.get("residual_counts") or {})
    quality_issue_counts.update(manual_issue_counts)
    quality_residual_counts.update(manual_issue_counts)
    if any(manual_issue_counts.values()):
        quality_summary["status"] = "FAIL"
    quality_issue_segment_ids = {
        int(row["id"])
        for row in quality_report.get("segments", [])
        if row.get("issues")
    }
    quality_summary["segments_with_issues"] = len(quality_issue_segment_ids | manual_issue_segment_ids)
    quality_summary["issue_counts"] = quality_issue_counts
    quality_summary["residual_counts"] = quality_residual_counts
    quality_report["summary"] = quality_summary
    write_json(paths["quality"] / "subtitle_quality.json", quality_report)
    checkpoint = store.load_checkpoint(task_id)
    checkpoint["quality_status"] = str(quality_summary.get("status") or "")
    checkpoint["quality_issue_counts"] = quality_issue_counts
    checkpoint["quality_residual_counts"] = quality_residual_counts
    store.save_checkpoint(task_id, checkpoint)
    previous_revision = _settings_revision(task.settings, "result_revision")
    task.settings.setdefault("result_export_revision", previous_revision)
    task.settings["result_revision"] = previous_revision + 1
    task.settings["edited"] = True
    store.save_task(task)
    store.append_event(
        task_id,
        "edited",
        stage="EDIT",
        message="Task result segments edited",
        details={
            "segments": len(segments),
            "quality_status": checkpoint["quality_status"],
            "quality_residual_counts": checkpoint["quality_residual_counts"],
        },
    )
    return open_task_result(root_dir=root_dir, task_id=task_id)


def update_task_memory_entry(
    *,
    root_dir: Path,
    task_id: str,
    entry_id: str,
    status: str,
) -> dict[str, Any]:
    normalized_status = normalize_status(status)
    if normalized_status not in {"proposed", "confirmed", "locked"}:
        raise ValueError("status must be one of: proposed, confirmed, locked")

    config = load_app_config(root_dir=root_dir)
    store = TaskStore(config.pipeline.artifacts_dir)
    memory_store = MemoryStore(store.task_dir(task_id) / "memory")
    document = memory_store.load_runtime()
    updated = False
    next_entries = []
    for entry in document.entries:
        if str(entry.id) == str(entry_id):
            row = to_plain(entry)
            row["status"] = normalized_status
            entry = entry_from_dict(row)
            updated = True
        next_entries.append(entry)

    if not updated:
        raise ValueError(f"runtime memory entry not found: {entry_id}")

    document.entries = next_entries
    memory_store.save(document)
    store.append_event(
        task_id,
        "memory_updated",
        stage="EDIT",
        message="Task memory entry status updated",
        details={"entry_id": entry_id, "status": normalized_status},
    )
    return open_task_result(root_dir=root_dir, task_id=task_id)


def _optional_bool(value: bool | str | None, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return default


def _settings_revision(settings: dict[str, Any], key: str) -> int:
    try:
        return max(0, int(settings.get(key, 0)))
    except (TypeError, ValueError):
        return 0


def _primary_output_base(task: Any, paths: dict[str, Path], output_dir: str | None = None) -> Path:
    if output_dir and output_dir.strip():
        stem = Path(task.input_file).stem
        return Path(output_dir).expanduser().resolve() / f"{stem}.{task.target_lang}"
    for fmt in ("srt", "ass", "vtt", "lrc"):
        value = task.output_paths.get(fmt) if isinstance(task.output_paths, dict) else None
        if isinstance(value, str) and value.strip():
            return Path(value).with_suffix("")
    if task.output_path:
        return Path(task.output_path).with_suffix("")
    stem = Path(task.input_file).stem
    return paths["output"] / f"{stem}.{task.target_lang}"


def reexport_task(
    *,
    root_dir: Path,
    task_id: str,
    output_format: str | None = None,
    output_dir: str | None = None,
    bilingual: bool | str | None = None,
    subtitle_bilingual_order: str | None = None,
    subtitle_prefer_single_line: bool | str | None = None,
) -> dict[str, Any]:
    cli_overrides: dict[str, Any] = {}
    if output_format:
        cli_overrides["output_format"] = output_format
    subtitle_style: dict[str, Any] = {}
    if subtitle_bilingual_order:
        subtitle_style["bilingual_order"] = subtitle_bilingual_order
    if subtitle_prefer_single_line is not None:
        subtitle_style["prefer_single_line"] = _optional_bool(subtitle_prefer_single_line, True)
    if subtitle_style:
        cli_overrides["subtitle_ass_style"] = subtitle_style
    config = load_app_config(root_dir=root_dir, cli_overrides=cli_overrides or None)
    store = TaskStore(config.pipeline.artifacts_dir)
    task = store.load_task(task_id)
    paths = _task_paths(store, task_id)
    final_file = paths["final"] / "segments.final.json"
    segments = [_segment_from_payload(row) for row in read_json(final_file)]
    normalized = str(output_format or task.settings.get("output_format") or config.pipeline.output_format or "srt").lower()
    normalized = "vtt" if normalized == "webvtt" else normalized
    normalized = normalized if normalized in {"srt", "ass", "vtt", "lrc", "both"} else "srt"
    effective_bilingual = _optional_bool(bilingual, task.bilingual)
    base = _primary_output_base(task, paths, output_dir=output_dir)
    base.parent.mkdir(parents=True, exist_ok=True)
    output_paths: dict[str, Path] = {}
    if normalized in {"srt", "both"}:
        output_paths["srt"] = base.parent / f"{base.name}.srt"
        export_srt(
            segments,
            output_paths["srt"],
            effective_bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    if normalized in {"ass", "both"}:
        output_paths["ass"] = base.parent / f"{base.name}.ass"
        export_ass(segments, output_paths["ass"], bilingual=effective_bilingual, style=config.pipeline.subtitle_ass_style)
    if normalized == "vtt":
        output_paths["vtt"] = base.parent / f"{base.name}.vtt"
        export_vtt(
            segments,
            output_paths["vtt"],
            effective_bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    if normalized == "lrc":
        output_paths["lrc"] = base.parent / f"{base.name}.lrc"
        export_lrc(segments, output_paths["lrc"], effective_bilingual, style=config.pipeline.subtitle_ass_style)
    delivery_reports = {
        fmt: subtitle_delivery_report(
            segments,
            output_format=fmt,
            bilingual=effective_bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
        for fmt in output_paths
        if fmt != "lrc"
    }
    delivery_file = paths["quality"] / "subtitle_delivery.json"
    checkpoint = store.load_checkpoint(task_id)
    checkpoint.pop("delivery_status", None)
    checkpoint.pop("delivery_issue_counts", None)
    if delivery_reports:
        write_json(delivery_file, delivery_reports)
        delivery_summary = {
            fmt: dict(report.get("summary") or {})
            for fmt, report in delivery_reports.items()
            if isinstance(report, dict)
        }
        delivery_statuses = [
            str(summary.get("status") or "")
            for summary in delivery_summary.values()
        ]
        checkpoint["delivery_status"] = (
            "FAIL"
            if "FAIL" in delivery_statuses
            else "WARN"
            if "WARN" in delivery_statuses
            else "PASS"
        )
        checkpoint["delivery_issue_counts"] = {
            fmt: dict(summary.get("issue_counts") or {})
            for fmt, summary in delivery_summary.items()
        }
    elif delivery_file.exists():
        delivery_file.unlink()
    checkpoint["status"] = "DONE"
    store.save_checkpoint(task_id, checkpoint)
    output_payload = {key: str(path) for key, path in output_paths.items()}
    primary = output_payload.get("srt") or output_payload.get("ass") or output_payload.get("vtt") or output_payload.get("lrc")
    store.update_task_status(task_id, "DONE", output_path=primary, output_paths=output_payload)
    task = store.load_task(task_id)
    task.settings["edited"] = bool(task.settings.get("edited", False))
    task.settings["output_format"] = normalized
    task.settings["reexport_bilingual"] = effective_bilingual
    task.settings["reexport_subtitle_ass_style"] = {
        "bilingual_order": config.pipeline.subtitle_ass_style.bilingual_order,
        "prefer_single_line": config.pipeline.subtitle_ass_style.prefer_single_line,
    }
    result_revision = _settings_revision(task.settings, "result_revision")
    task.settings["result_revision"] = result_revision
    task.settings["result_export_revision"] = result_revision
    store.save_task(task)
    store.append_event(
        task_id,
        "reexported",
        stage="EXPORT",
        message=f"Re-exported {normalized.upper()} subtitles",
        details={"output_path": primary or "", "output_paths": output_payload},
    )
    return {
        "task_id": task_id,
        "output_path": primary,
        "output_paths": output_payload,
        "bilingual": effective_bilingual,
        "subtitle_bilingual_order": config.pipeline.subtitle_ass_style.bilingual_order,
        "subtitle_prefer_single_line": config.pipeline.subtitle_ass_style.prefer_single_line,
        "result_revision": result_revision,
        "result_export_revision": result_revision,
    }
