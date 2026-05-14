from __future__ import annotations

from pathlib import Path
from typing import Any

from ..app.config import load_app_config
from ..formats.exporter import export_ass, export_srt
from ..app.models import Segment
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
        "reflow": reflow_summary,
        "memory": {
            "enabled": bool(task.settings.get("memory", {}).get("enabled", False)),
            "entries": len(memory_entries) + len(preset_entries),
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
    task.settings["edited"] = True
    store.save_task(task)
    store.append_event(task_id, "edited", stage="EDIT", message="Task result segments edited", details={"segments": len(segments)})
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


def reexport_task(
    *,
    root_dir: Path,
    task_id: str,
    output_format: str | None = None,
    bilingual: bool | str | None = None,
) -> dict[str, Any]:
    config = load_app_config(root_dir=root_dir, cli_overrides={"output_format": output_format} if output_format else None)
    store = TaskStore(config.pipeline.artifacts_dir)
    task = store.load_task(task_id)
    paths = _task_paths(store, task_id)
    final_file = paths["final"] / "segments.final.json"
    segments = [_segment_from_payload(row) for row in read_json(final_file)]
    normalized = str(output_format or task.settings.get("output_format") or config.pipeline.output_format or "srt").lower()
    normalized = normalized if normalized in {"srt", "ass", "both"} else "srt"
    effective_bilingual = _optional_bool(bilingual, task.bilingual)
    stem = Path(task.input_file).stem
    base = paths["output"] / f"{stem}.{task.target_lang}"
    output_paths: dict[str, Path] = {}
    if normalized in {"srt", "both"}:
        output_paths["srt"] = base.parent / f"{base.name}.srt"
        export_srt(segments, output_paths["srt"], effective_bilingual)
    if normalized in {"ass", "both"}:
        output_paths["ass"] = base.parent / f"{base.name}.ass"
        export_ass(segments, output_paths["ass"], bilingual=effective_bilingual, style=config.pipeline.subtitle_ass_style)
    output_payload = {key: str(path) for key, path in output_paths.items()}
    primary = output_payload.get("srt") or output_payload.get("ass")
    store.update_task_status(task_id, task.status, output_path=primary, output_paths=output_payload)
    task = store.load_task(task_id)
    task.settings["edited"] = bool(task.settings.get("edited", False))
    task.settings["output_format"] = normalized
    task.settings["reexport_bilingual"] = effective_bilingual
    store.save_task(task)
    store.append_event(
        task_id,
        "reexported",
        stage="EXPORT",
        message=f"Re-exported {normalized.upper()} subtitles",
        details={"output_path": primary or "", "output_paths": output_payload},
    )
    return {"task_id": task_id, "output_path": primary, "output_paths": output_payload, "bilingual": effective_bilingual}
