from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Segment, TaskRecord
from ..artifacts.task_store import TaskStore
from ..formats.exporter import (
    export_ass,
    export_lrc,
    export_srt,
    export_vtt,
    subtitle_delivery_report,
)
from ..formats.srt import parse_srt_file
from ..memory.bootstrapper import bootstrap_memory
from ..memory.checker import check_consistency, write_consistency_issues
from ..memory.collections import build_selected_collections_snapshot, collection_store_for_config
from ..memory.plan import (
    effective_memory_sources,
    memory_enabled,
    runs_bootstrap,
    translates_with_memory,
    uses_collections,
    uses_presets,
)
from ..memory.presets import build_selected_presets_snapshot
from ..memory.store import MemoryStore
from ..utils import append_jsonl, read_json, read_jsonl, write_json
from .aligner import (
    apply_translations,
    merge_asr_window_segments,
    normalize_timeline,
    validate_segments,
)
from .asr_execution import (
    _asr_artifact_paths,
    _parse_asr_rows,
    _sync_checkpoint_openrouter_asr_usage,
)
from .asr_planning import (
    _active_asr_provider,
    _asr_duration_hard_limit,
    _asr_runs_concurrently,
    _asr_uses_word_timeline,
    _ensure_resolved_asr_plan,
    _ingest_artifacts_valid,
)
from .chunking import number_and_chunk_segments, plan_translation_chunks
from .delivery_planning import _output_paths_for_task
from .pipeline_runtime import (
    _check_cancel,
    _is_nonempty_file,
    _is_valid_json_list,
    _require_file,
)
from .source_pipeline import (
    _clean_asr_source_segments,
    _load_segments_from_input,
    _mark_asr_boundary_quality,
    _segments_with_source,
    _source_segments_path,
    load_source_segments,
    persist_raw_source_segments,
    persist_source_segments,
)
from .subtitle_compression import compress_overlong_subtitles
from .subtitle_optimizer import optimize_subtitles
from .subtitle_reflow import reflow_subtitles
from .translation_pipeline import (
    _backfill_translation_validation,
    _effective_initial_chunk_lines,
    _translation_done_count,
    _translation_progress_value,
    _translation_route_providers,
    _translation_row_for_artifact,
    _write_translation_experiment_artifacts,
)
from .word_timeline import merge_word_timeline_windows


@dataclass(frozen=True)
class PipelineExecutionContext:
    config: AppConfig
    store: TaskStore
    task: TaskRecord
    task_id: str
    input_type: str
    paths: dict[str, Path]
    checkpoint: dict[str, Any]
    root_dir: Path
    output_file: Path | None
    providers_file: Path | None


@dataclass(frozen=True)
class PipelineStageDependencies:
    emit_stage: Callable[..., None]
    preflight: Callable[..., None]
    resolve_video_source_mode: Callable[..., tuple[str, dict | None, list[dict]]]
    extract_subtitle_stream: Callable[..., None]
    extract_audio_for_asr: Callable[..., dict[str, Any]]
    split_audio_for_asr: Callable[..., list[dict]]
    build_asr_engine: Callable[..., Any]
    run_asr_segments_concurrent: Callable[..., None]
    run_asr_segments_serial: Callable[..., None]
    translation_progress_callback: Callable[..., Callable]
    iter_translation_results: Callable[..., Any]

def run_precheck_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies) -> None:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    _check_cancel(store, task_id)
    dependencies.emit_stage(store, task_id, "PRECHECK", "Running preflight checks")
    dependencies.preflight(config, store, task, output_file, root_dir=root_dir, providers_file=providers_file)
    checkpoint["status"] = "PRECHECK"
    store.save_checkpoint(task_id, checkpoint)

def run_ingest_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies) -> list[Segment] | None:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    if input_type == "segments_translate":
        _check_cancel(store, task_id)
        dependencies.emit_stage(store, task_id, "INGEST", "Loading source segments")
        source_jsonl = _source_segments_path(paths)
        if not checkpoint.get("ingest_done") or not _is_nonempty_file(source_jsonl):
            all_segments = _load_segments_from_input(Path(task.input_file))
            if not all_segments:
                raise RuntimeError("No subtitle segments parsed from input")
            all_segments = _clean_asr_source_segments(
                paths=paths,
                segments=all_segments,
                store=store,
                task_id=task_id,
                stage="INGEST",
                renumber=False,
            )
            source_jsonl = persist_source_segments(paths, all_segments)
            checkpoint["ingest_done"] = True
            checkpoint["status"] = "INGEST"
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "artifact",
                stage="INGEST",
                message="Source segments ready",
                progress=0.52,
                details={"path": str(source_jsonl), "segments": len(all_segments)},
            )
        else:
            all_segments = load_source_segments(paths)
    elif input_type == "srt_translate":
        _check_cancel(store, task_id)
        dependencies.emit_stage(store, task_id, "INGEST", "Parsing SRT subtitles")
        source_jsonl = _source_segments_path(paths)
        if not checkpoint.get("ingest_done") or not _is_nonempty_file(source_jsonl):
            all_segments = _segments_with_source(parse_srt_file(Path(task.input_file)), "srt")
            if not all_segments:
                raise RuntimeError("No subtitle segments parsed from SRT input")
            source_jsonl = persist_source_segments(paths, all_segments)
            checkpoint["ingest_done"] = True
            checkpoint["status"] = "INGEST"
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "artifact",
                stage="INGEST",
                message="SRT segments ready",
                progress=0.52,
                details={"path": str(source_jsonl), "segments": len(all_segments)},
            )
        else:
            all_segments = load_source_segments(paths)
    else:
        _check_cancel(store, task_id)
        source_mode, subtitle_stream, subtitle_streams = dependencies.resolve_video_source_mode(config, task)
        if source_mode == "embedded_subtitle":
            dependencies.emit_stage(store, task_id, "INGEST", "Extracting embedded subtitles")
            source_jsonl = _source_segments_path(paths)
            embedded_srt = paths["source"] / "embedded_subtitle.srt"
            requested_source_mode = str(task.settings.get("source_mode", config.pipeline.source_mode))
            if requested_source_mode == "auto" and subtitle_stream is not None:
                store.append_event(
                    task_id,
                    "warning",
                    stage="INGEST",
                    level="warning",
                    message="Auto-selected embedded subtitle stream; use --source-mode asr to force ASR if this track is wrong",
                    details={
                        "stream": subtitle_stream,
                        "available_streams": subtitle_streams,
                    },
                )
            if not checkpoint.get("ingest_done") or not _is_nonempty_file(source_jsonl):
                if subtitle_stream is None:
                    raise RuntimeError("No matching text subtitle stream found")
                dependencies.extract_subtitle_stream(
                    Path(task.input_file),
                    embedded_srt,
                    stream_index=int(subtitle_stream["index"]),
                )
                all_segments = _segments_with_source(parse_srt_file(embedded_srt), "embedded_subtitle")
                if not all_segments:
                    raise RuntimeError("No subtitle segments parsed from embedded subtitle stream")
                source_jsonl = persist_source_segments(paths, all_segments)
                write_json(
                    paths["source"] / "subtitle_streams.json",
                    {
                        "selected": subtitle_stream,
                        "streams": subtitle_streams,
                    },
                )
                checkpoint["ingest_done"] = True
                checkpoint["status"] = "INGEST"
                store.save_checkpoint(task_id, checkpoint)
                store.append_event(
                    task_id,
                    "artifact",
                    stage="INGEST",
                    message="Embedded subtitle segments ready",
                    progress=0.52,
                    details={
                        "path": str(source_jsonl),
                        "segments": len(all_segments),
                        "stream": subtitle_stream,
                    },
                )
            else:
                all_segments = load_source_segments(paths)
            if input_type == "video_asr":
                _check_cancel(store, task_id)
                checkpoint["status"] = "DONE"
                checkpoint.pop("error", None)
                checkpoint.pop("error_info", None)
                store.save_checkpoint(task_id, checkpoint)
                store.update_task_status(
                    task_id,
                    "DONE",
                    output_path=str(source_jsonl),
                    output_paths={"segments": str(source_jsonl)},
                    clear_error=True,
                )
                store.append_event(
                    task_id,
                    "done",
                    stage="DONE",
                    message="Subtitle extraction task completed",
                    progress=1.0,
                    details={"output_path": str(source_jsonl), "output_paths": {"segments": str(source_jsonl)}},
                )
                return
        else:
            dependencies.emit_stage(store, task_id, "INGEST", "Extracting and splitting audio")
            audio_full = paths["media"] / "audio_full.m4a"
            manifest_file = paths["asr"] / "segments_manifest.json"
            if not _ingest_artifacts_valid(
                audio_full,
                manifest_file,
                task_dir=paths["base"],
            ):
                media_meta = dependencies.extract_audio_for_asr(
                    Path(task.input_file),
                    audio_full,
                    source_lang=task.source_lang,
                    audio_track=config.pipeline.asr_audio_track,
                )
                asr_provider = _active_asr_provider(config)
                chunking = asr_provider.chunking
                planning_metadata: dict[str, Any] = {}
                segments_manifest = dependencies.split_audio_for_asr(
                    audio_full,
                    paths["asr"] / "windows",
                    mode=chunking.mode,
                    window_seconds=chunking.window_seconds,
                    max_window_seconds=chunking.max_window_seconds,
                    min_window_seconds=chunking.min_window_seconds,
                    overlap_seconds=chunking.overlap_seconds,
                    short_audio_seconds=chunking.short_audio_seconds,
                    max_upload_mb=chunking.max_upload_mb,
                    max_duration_seconds=_asr_duration_hard_limit(config),
                    silence_noise_db=chunking.silence.noise_db,
                    silence_min_seconds=chunking.silence.min_silence_seconds,
                    silence_cut_padding_seconds=chunking.silence.cut_padding_seconds,
                    duration_seconds=float(media_meta["duration_seconds"]),
                    planning_metadata=planning_metadata,
                )
                write_json(paths["media"] / "media_meta.json", media_meta)
                _require_file(audio_full, "media/audio_full.m4a")
                asr_plan = _ensure_resolved_asr_plan(
                    config,
                    store,
                    task,
                    audio_full=audio_full,
                    media_meta=media_meta,
                    manifest=segments_manifest,
                    planning_metadata=planning_metadata,
                    paths=paths,
                )
                if asr_plan is None:
                    write_json(manifest_file, segments_manifest)
                checkpoint["ingest_done"] = True
                checkpoint["status"] = "INGEST"
                if asr_plan is not None:
                    checkpoint["asr_plan_id"] = str(asr_plan.get("plan_id") or "")
                store.save_checkpoint(task_id, checkpoint)
                store.append_event(
                    task_id,
                    "artifact",
                    stage="INGEST",
                    message="Audio segments ready",
                    progress=0.18,
                    details={
                        "path": str(manifest_file),
                        "segments": len(segments_manifest),
                        "asr_plan_id": str(asr_plan.get("plan_id") or "") if asr_plan else "",
                    },
                )
            else:
                segments_manifest = read_json(manifest_file)
                media_meta_file = paths["media"] / "media_meta.json"
                media_meta = read_json(media_meta_file) if media_meta_file.is_file() else {
                    "duration_seconds": max(
                        (
                            float(item.get("start", 0.0))
                            + float(item.get("duration", 0.0))
                            for item in segments_manifest
                            if isinstance(item, dict)
                        ),
                        default=0.0,
                    )
                }
                asr_plan = _ensure_resolved_asr_plan(
                    config,
                    store,
                    task,
                    audio_full=audio_full,
                    media_meta=media_meta,
                    manifest=segments_manifest,
                    planning_metadata={},
                    paths=paths,
                )
                if asr_plan is not None:
                    checkpoint["asr_plan_id"] = str(asr_plan.get("plan_id") or "")

            _check_cancel(store, task_id)
            dependencies.emit_stage(store, task_id, "ASR", "Transcribing audio segments")
            asr = dependencies.build_asr_engine(config, task=task, root_dir=root_dir)
            try:
                asr_done = set(checkpoint.get("asr_done_segments", []))
                checkpoint["asr_total_segments"] = len(segments_manifest)
                checkpoint["asr_done_count"] = len(asr_done)
                checkpoint["status"] = "ASR"
                store.save_checkpoint(task_id, checkpoint)
                segment_files = []
                pending_asr_items = []
                for item in segments_manifest:
                    idx = int(item["segment_index"])
                    artifact_paths = _asr_artifact_paths(paths, idx)
                    segment_files.append((idx, artifact_paths["rows"]))
                    if idx in asr_done and _is_valid_json_list(artifact_paths["rows"]):
                        continue
                    pending_asr_items.append(item)
                if _asr_runs_concurrently(config):
                    dependencies.run_asr_segments_concurrent(
                        items=pending_asr_items,
                        asr=asr,
                        paths=paths,
                        config=config,
                        store=store,
                        task_id=task_id,
                        checkpoint=checkpoint,
                        asr_done=asr_done,
                        total_segments=len(segments_manifest),
                        task=task,
                        root_dir=root_dir,
                    )
                else:
                    dependencies.run_asr_segments_serial(
                        items=pending_asr_items,
                        asr=asr,
                        paths=paths,
                        config=config,
                        store=store,
                        task_id=task_id,
                        checkpoint=checkpoint,
                        asr_done=asr_done,
                        total_segments=len(segments_manifest),
                        task=task,
                        root_dir=root_dir,
                    )
            finally:
                close_asr = getattr(asr, "close", None)
                if callable(close_asr):
                    close_asr()

            all_segments = []
            next_id = 1
            window_segments = []
            word_window_rows: list[tuple[dict[str, Any], list[dict[str, Any]]]] = []
            split_retry_overlap_reports: list[dict[str, Any]] = []
            uses_word_timeline = _asr_uses_word_timeline(config)
            for _idx, seg_file in sorted(segment_files, key=lambda x: x[0]):
                _require_file(seg_file, f"source/asr/rows/{seg_file.name}")
                rows = read_json(seg_file)
                manifest_item = next(
                    (item for item in segments_manifest if int(item["segment_index"]) == _idx),
                    {"segment_index": _idx},
                )
                if uses_word_timeline:
                    word_window_rows.append((manifest_item, rows))
                    preprocess_path = _asr_artifact_paths(paths, _idx)["preprocess"]
                    if preprocess_path.exists():
                        preprocess_payload = read_json(preprocess_path)
                        retry_report = (
                            preprocess_payload.get("word_overlap")
                            if isinstance(preprocess_payload, dict)
                            else None
                        )
                        if isinstance(retry_report, dict):
                            split_retry_overlap_reports.append(
                                {
                                    "parent_window_index": _idx,
                                    "report": retry_report,
                                }
                            )
                    continue
                parsed = _parse_asr_rows(rows, start_id=next_id)
                window_segments.append((manifest_item, parsed))
                all_segments.extend(parsed)
                next_id = all_segments[-1].id + 1 if all_segments else next_id

            if uses_word_timeline:
                merged_rows, word_overlap_report = merge_word_timeline_windows(word_window_rows)
                if split_retry_overlap_reports:
                    word_overlap_report["split_retry_reports"] = split_retry_overlap_reports
                retry_fallback_seams = sum(
                    int(item["report"].get("summary", {}).get("fallback_seams", 0))
                    for item in split_retry_overlap_reports
                )
                fallback_seams = int(
                    word_overlap_report.get("summary", {}).get("fallback_seams", 0)
                )
                total_fallback_seams = fallback_seams + retry_fallback_seams
                word_overlap_report["summary"]["split_retry_count"] = len(
                    split_retry_overlap_reports
                )
                word_overlap_report["summary"]["total_fallback_seams"] = total_fallback_seams
                word_overlap_path = paths["quality"] / "asr_word_overlap.json"
                write_json(word_overlap_path, word_overlap_report)
                all_segments = _parse_asr_rows(merged_rows, start_id=1)
                if total_fallback_seams:
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="ASR word overlap used trusted-boundary fallback",
                        details={
                            "path": str(word_overlap_path),
                            "fallback_seams": total_fallback_seams,
                        },
                    )
            else:
                deduped_segments = merge_asr_window_segments(
                    window_segments,
                    fuzzy_dedupe=_active_asr_provider(config).chunking.fuzzy_dedupe,
                )
                if len(deduped_segments) != len(all_segments):
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="Removed duplicate overlap segments",
                        details={"before": len(all_segments), "after": len(deduped_segments)},
                    )
                all_segments = deduped_segments
            persist_raw_source_segments(paths, all_segments)
            all_segments = _clean_asr_source_segments(
                paths=paths,
                segments=all_segments,
                store=store,
                task_id=task_id,
                stage="ASR",
            )
            all_segments = _mark_asr_boundary_quality(
                paths=paths,
                segments=all_segments,
                provider=_active_asr_provider(config),
                store=store,
                task_id=task_id,
                stage="ASR",
            )
            quality_dir = paths["source"] / "asr" / "quality"
            if quality_dir.exists():
                quality_rows = [read_json(path) for path in sorted(quality_dir.glob("segment_*.json"))]
                quality_summary = {
                    "segments": len(quality_rows),
                    "input_rows": sum(int(row.get("input_rows", 0)) for row in quality_rows),
                    "kept_rows": sum(int(row.get("kept_rows", 0)) for row in quality_rows),
                    "dropped_rows": sum(int(row.get("dropped_rows", 0)) for row in quality_rows),
                    "warning_rows": sum(int(row.get("warning_rows", 0)) for row in quality_rows),
                }
                write_json(quality_dir / "summary.json", quality_summary)
                if quality_summary["dropped_rows"]:
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="Dropped low-quality ASR rows before source normalization",
                        details=quality_summary,
                    )

            source_jsonl = persist_source_segments(paths, all_segments)
            asr_usage_path, asr_usage = _sync_checkpoint_openrouter_asr_usage(
                checkpoint,
                paths=paths,
                provider=_active_asr_provider(config),
            )
            checkpoint["source_segment_count"] = len(all_segments)
            store.save_checkpoint(task_id, checkpoint)
            if asr_usage_path is not None:
                store.append_event(
                    task_id,
                    "artifact",
                    stage="ASR",
                    message="OpenRouter ASR usage ready",
                    progress=0.52,
                    details={"path": str(asr_usage_path), **(asr_usage or {})},
                )
            store.append_event(
                task_id,
                "artifact",
                stage="ASR",
                message="Normalized source segments ready",
                progress=0.52,
                details={"path": str(source_jsonl), "segments": len(all_segments)},
            )

            if input_type == "video_asr":
                _check_cancel(store, task_id)
                checkpoint["status"] = "DONE"
                checkpoint.pop("error", None)
                checkpoint.pop("error_info", None)
                store.save_checkpoint(task_id, checkpoint)
                store.update_task_status(
                    task_id,
                    "DONE",
                    output_path=str(source_jsonl),
                    output_paths={"segments": str(source_jsonl)},
                    clear_error=True,
                )
                store.append_event(
                    task_id,
                    "done",
                    stage="DONE",
                    message="ASR task completed",
                    progress=1.0,
                    details={"output_path": str(source_jsonl), "output_paths": {"segments": str(source_jsonl)}},
                )
                return
    return all_segments

def run_memory_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies, all_segments: list[Segment]) -> None:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    if memory_enabled(config.pipeline.memory):
        _check_cancel(store, task_id)
        dependencies.emit_stage(store, task_id, "MEMORY", "Preparing translation memory")
        memory_store = MemoryStore(paths["memory"])
        memory_store.ensure_runtime_document()
        if uses_collections(config.pipeline.memory) and not memory_store.selected_collections_file.exists():
            snapshot = build_selected_collections_snapshot(
                collection_ids=[item.id for item in config.pipeline.memory.collections],
                store=collection_store_for_config(root_dir=root_dir, config=config),
                source_lang=task.source_lang,
                target_lang=task.target_lang,
            )
            memory_store.save_selected_collections(snapshot)
            report = dict(snapshot.get("report") or {})
            store.append_event(
                task_id,
                "artifact",
                stage="MEMORY",
                message="Memory collections snapshot ready",
                details={
                    "path": str(memory_store.selected_collections_file),
                    "applied": report.get("applied") or [],
                    "skipped": report.get("skipped") or [],
                    "conflicts": report.get("conflicts") or [],
                    "entries": int(report.get("entries") or 0),
                },
            )
        if uses_presets(config.pipeline.memory) and not memory_store.selected_presets_file.exists():
            snapshot = build_selected_presets_snapshot(
                presets=config.pipeline.memory.presets,
                root_dir=root_dir,
                source_lang=task.source_lang,
                target_lang=task.target_lang,
            )
            memory_store.save_selected_presets(snapshot)
            report = dict(snapshot.get("report") or {})
            if report.get("applied") or report.get("skipped") or report.get("errors"):
                store.append_event(
                    task_id,
                    "artifact",
                    stage="MEMORY",
                    message="Memory presets snapshot ready",
                    details={
                        "path": str(memory_store.selected_presets_file),
                        "applied": report.get("applied") or [],
                        "skipped": report.get("skipped") or [],
                        "errors": report.get("errors") or [],
                        "entries": int(report.get("entries") or 0),
                    },
                )
        if runs_bootstrap(config.pipeline.memory):
            bootstrap_payload = bootstrap_memory(
                config,
                all_segments,
                source_lang=task.source_lang,
                target_lang=task.target_lang,
                memory_dir=paths["memory"],
                progress_callback=dependencies.translation_progress_callback(
                    store,
                    task_id,
                    checkpoint,
                    stage="MEMORY",
                ),
            )
            checkpoint["status"] = "MEMORY"
            checkpoint["memory_bootstrap_status"] = str(bootstrap_payload.get("status") or "")
            checkpoint["memory_bootstrap_actions"] = len(bootstrap_payload.get("actions") or [])
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "artifact",
                stage="MEMORY",
                message="Memory bootstrap ready",
                level="warning" if bootstrap_payload.get("status") == "failed" else "info",
                details={
                    "path": str(paths["memory"] / "bootstrap.json"),
                    "status": bootstrap_payload.get("status"),
                    "actions": len(bootstrap_payload.get("actions") or []),
                    "errors": bootstrap_payload.get("errors") or [],
                },
            )

def run_translation_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies, all_segments: list[Segment]) -> Path:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    _check_cancel(store, task_id)
    dependencies.emit_stage(store, task_id, "SEGMENT", "Preparing translation chunks")
    if config.pipeline.translation.chunking.mode == "capacity_aware":
        chunks, chunking_warnings = plan_translation_chunks(
            config,
            all_segments,
            _translation_route_providers(config),
        )
    else:
        effective_chunk_lines, chunking_warnings = _effective_initial_chunk_lines(config, len(all_segments))
        chunks = number_and_chunk_segments(
            all_segments,
            effective_chunk_lines,
            context_before_lines=config.pipeline.translation.context_before_lines,
            context_after_lines=config.pipeline.translation.context_after_lines,
        )
    for warning in chunking_warnings:
        store.append_event(
            task_id,
            "warning",
            stage="SEGMENT",
            level="warning",
            message=str(warning.get("message", "")),
            details=dict(warning.get("details") or {}),
        )
    write_json(paths["chunks"] / "chunks.json", chunks)
    checkpoint["status"] = "SEGMENT"
    checkpoint["source_segment_count"] = len(all_segments)
    checkpoint["translate_total_chunks"] = len(chunks)
    checkpoint["translate_done_count"] = _translation_done_count(
        chunks,
        {str(item) for item in checkpoint.get("translate_done_chunks", [])},
    )
    store.save_checkpoint(task_id, checkpoint)

    _check_cancel(store, task_id)
    dependencies.emit_stage(store, task_id, "TRANSLATE", "Translating chunks")
    translated_file = paths["translate"] / "segments.translated.jsonl"
    validation_file = paths["translate"] / "validation.jsonl"
    repairs_file = paths["translate"] / "repairs.jsonl"
    repairs_file.parent.mkdir(parents=True, exist_ok=True)
    repairs_file.touch(exist_ok=True)
    translated_rows = read_jsonl(translated_file)
    validation_rows = read_jsonl(validation_file)
    validation_rows, translated_done = _backfill_translation_validation(
        config=config,
        chunks=chunks,
        translated_rows=translated_rows,
        validation_rows=validation_rows,
        validation_file=validation_file,
        store=store,
        task_id=task_id,
    )
    checkpoint["translate_total_chunks"] = len(chunks)
    checkpoint["translate_done_chunks"] = sorted(translated_done)
    checkpoint["translate_done_count"] = _translation_done_count(chunks, translated_done)
    store.save_checkpoint(task_id, checkpoint)
    translation_progress = dependencies.translation_progress_callback(store, task_id, checkpoint)
    for row in dependencies.iter_translation_results(
        config,
        chunks,
        source_lang=task.source_lang,
        target_lang=task.target_lang,
        already_done=translated_done,
        memory_dir=paths["memory"] if translates_with_memory(config.pipeline.memory) else None,
        progress_callback=translation_progress,
    ):
        _check_cancel(store, task_id)
        _write_translation_experiment_artifacts(config, paths, row)
        append_jsonl(translated_file, _translation_row_for_artifact(row))
        append_jsonl(validation_file, row.get("validation", {"chunk_id": row.get("chunk_id"), "issues": []}))
        for repair in row.get("repairs", []):
            append_jsonl(repairs_file, repair)
        translated_done.add(row["chunk_id"])
        checkpoint["translate_done_chunks"] = sorted(translated_done)
        checkpoint["translate_done_count"] = _translation_done_count(chunks, translated_done)
        checkpoint["status"] = "TRANSLATE"
        checkpoint.pop("translate_current_chunk", None)
        checkpoint.pop("translate_current_chunk_ids", None)
        checkpoint.pop("translate_current_segment_id", None)
        checkpoint.pop("translate_current_attempt", None)
        checkpoint.pop("translate_current_max_attempts", None)
        checkpoint.pop("translate_current_provider", None)
        checkpoint.pop("translate_current_model", None)
        checkpoint.pop("translate_current_mode", None)
        checkpoint.pop("translate_attempt_started_at", None)
        store.save_checkpoint(task_id, checkpoint)
        store.append_event(
            task_id,
            "progress",
            stage="TRANSLATE",
            message=f"Translated chunk {checkpoint['translate_done_count']}/{len(chunks)}",
            progress=_translation_progress_value(chunks, translated_done),
        )
    return translated_file

def run_quality_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies, all_segments: list[Segment], translated_file: Path) -> list[Segment]:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    _check_cancel(store, task_id)
    dependencies.emit_stage(store, task_id, "ALIGN", "Aligning and validating subtitles")
    translated_rows = read_jsonl(translated_file)
    aligned_segments = normalize_timeline(apply_translations(all_segments, translated_rows))
    errors, warnings = validate_segments(aligned_segments, max_cps=config.pipeline.subtitle.quality.hard_max_cps)
    for warning in warnings:
        store.append_event(task_id, "warning", stage="ALIGN", level="warning", message=warning)
    if errors:
        raise RuntimeError("; ".join(errors[:10]))
    write_json(paths["final"] / "segments.aligned.json", aligned_segments)
    store.append_event(
        task_id,
        "artifact",
        stage="ALIGN",
        message="Aligned subtitle segments ready",
        progress=0.88,
        details={"path": str(paths["final"] / "segments.aligned.json"), "segments": len(aligned_segments)},
    )
    _check_cancel(store, task_id)
    dependencies.emit_stage(store, task_id, "QUALITY", "Optimizing subtitle readability")
    quality_progress = dependencies.translation_progress_callback(store, task_id, checkpoint, stage="QUALITY")
    quality_result = optimize_subtitles(aligned_segments, config.pipeline.subtitle.quality)
    final_segments = quality_result.segments
    paths["quality"].mkdir(parents=True, exist_ok=True)
    compression_rows: list[dict[str, Any]] = []
    if config.pipeline.subtitle.compression.enabled:
        final_segments, compression_rows = compress_overlong_subtitles(
            config=config,
            segments=final_segments,
            source_lang=task.source_lang,
            target_lang=task.target_lang,
            memory_dir=paths["memory"] if translates_with_memory(config.pipeline.memory) else None,
            progress_callback=quality_progress,
        )
        for row in compression_rows:
            append_jsonl(paths["quality"] / "compression.jsonl", row)
        quality_result = optimize_subtitles(final_segments, config.pipeline.subtitle.quality)
        final_segments = quality_result.segments
    reflow_rows: list[dict[str, Any]] = []
    if config.pipeline.subtitle.reflow.enabled:
        final_segments, reflow_rows = reflow_subtitles(
            config=config,
            segments=final_segments,
            quality_report=quality_result.report,
            source_lang=task.source_lang,
            target_lang=task.target_lang,
            memory_dir=paths["memory"] if translates_with_memory(config.pipeline.memory) else None,
            progress_callback=quality_progress,
        )
        for row in reflow_rows:
            append_jsonl(paths["quality"] / "reflow.jsonl", row)
        if reflow_rows:
            store.append_event(
                task_id,
                "artifact",
                stage="QUALITY",
                message="Subtitle reflow report ready",
                progress=0.91,
                details={
                    "path": str(paths["quality"] / "reflow.jsonl"),
                    "windows": len(reflow_rows),
                    "reflowed": sum(1 for row in reflow_rows if row.get("status") == "reflowed"),
                },
            )
        quality_result = optimize_subtitles(final_segments, config.pipeline.subtitle.quality)
        final_segments = quality_result.segments
        write_json(paths["final"] / "segments.reflowed.json", final_segments)
    write_json(paths["quality"] / "subtitle_quality.json", quality_result.report)
    quality_summary = quality_result.report.get("summary", {})
    quality_status = str(quality_summary.get("status") or "")
    checkpoint["quality_status"] = quality_status
    checkpoint["quality_issue_counts"] = dict(quality_summary.get("issue_counts") or {})
    checkpoint["quality_residual_counts"] = dict(quality_summary.get("residual_counts") or {})
    for code, count in quality_result.report.get("summary", {}).get("issue_counts", {}).items():
        store.append_event(
            task_id,
            "warning",
            stage="QUALITY",
            level="warning",
            message=f"Subtitle quality issue {code}: {count}",
            details={"code": code, "count": count},
        )
    if quality_status in {"WARN", "FAIL"}:
        store.append_event(
            task_id,
            "warning",
            stage="QUALITY",
            level="warning",
            message=f"Subtitle quality status {quality_status}",
            details={
                "status": quality_status,
                "residual_counts": quality_summary.get("residual_counts", {}),
            },
        )
    store.append_event(
        task_id,
        "artifact",
        stage="QUALITY",
        message="Subtitle quality report ready",
        progress=0.92,
        details={
            "path": str(paths["quality"] / "subtitle_quality.json"),
            "summary": quality_summary,
        },
    )
    write_json(paths["final"] / "segments.final.json", final_segments)
    if translates_with_memory(config.pipeline.memory) and config.pipeline.memory.consistency_check.enabled:
        memory_store = MemoryStore(paths["memory"])
        memory_document = memory_store.load_effective(effective_memory_sources(config.pipeline.memory))
        memory_issues = check_consistency(memory_document, final_segments)
        write_consistency_issues(memory_store, memory_issues)
        store.append_event(
            task_id,
            "artifact",
            stage="QUALITY",
            message="Translation memory consistency report ready",
            progress=0.93,
            details={
                "path": str(memory_store.issues_file),
                "issues": len(memory_issues),
            },
        )
    checkpoint["status"] = "QUALITY"
    store.save_checkpoint(task_id, checkpoint)
    return final_segments

def run_export_stage(context: PipelineExecutionContext, dependencies: PipelineStageDependencies, final_segments: list[Segment]) -> None:
    config = context.config
    store = context.store
    task = context.task
    task_id = context.task_id
    input_type = context.input_type
    paths = context.paths
    checkpoint = context.checkpoint
    root_dir = context.root_dir
    output_file = context.output_file
    providers_file = context.providers_file
    _check_cancel(store, task_id)
    output_format, output_paths = _output_paths_for_task(
        config=config,
        task=task,
        output_file=output_file,
        output_dir=paths["output"],
    )
    dependencies.emit_stage(store, task_id, "EXPORT", f"Exporting {output_format.upper()} subtitles")
    if "srt" in output_paths:
        export_srt(
            final_segments,
            output_paths["srt"],
            task.bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    if "ass" in output_paths:
        export_ass(
            final_segments,
            output_paths["ass"],
            bilingual=task.bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    if "vtt" in output_paths:
        export_vtt(
            final_segments,
            output_paths["vtt"],
            task.bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    if "lrc" in output_paths:
        export_lrc(
            final_segments,
            output_paths["lrc"],
            task.bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    delivery_reports: dict[str, dict] = {}
    for fmt in output_paths:
        if fmt == "lrc":
            continue
        delivery_reports[fmt] = subtitle_delivery_report(
            final_segments,
            output_format=fmt,
            bilingual=task.bilingual,
            style=config.pipeline.subtitle_ass_style,
        )
    delivery_file = paths["quality"] / "subtitle_delivery.json"
    checkpoint.pop("delivery_status", None)
    checkpoint.pop("delivery_issue_counts", None)
    if delivery_reports:
        write_json(delivery_file, delivery_reports)
        delivery_summary = {
            fmt: report.get("summary", {})
            for fmt, report in delivery_reports.items()
            if isinstance(report, dict)
        }
        delivery_statuses = [
            str(summary.get("status") or "")
            for summary in delivery_summary.values()
            if isinstance(summary, dict)
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
            if isinstance(summary, dict)
        }
        store.append_event(
            task_id,
            "artifact",
            stage="EXPORT",
            message="Subtitle delivery report ready",
            progress=0.97,
            details={"path": str(paths["quality"] / "subtitle_delivery.json"), "summary": delivery_summary},
        )
        for fmt, report in delivery_reports.items():
            summary = dict(report.get("summary") or {})
            if summary.get("status") in {"WARN", "FAIL"}:
                store.append_event(
                    task_id,
                    "warning",
                    stage="EXPORT",
                    level="warning",
                    message=f"{fmt.upper()} delivery status {summary.get('status')}",
                    details={"issue_counts": summary.get("issue_counts", {})},
                )
    elif delivery_file.exists():
        delivery_file.unlink()
    output_paths_payload = {key: str(path) for key, path in output_paths.items()}
    primary_output = output_paths.get("srt") or output_paths.get("ass") or output_paths.get("vtt") or output_paths.get("lrc")
    checkpoint["status"] = "DONE"
    checkpoint.pop("error", None)
    store.save_checkpoint(task_id, checkpoint)
    store.update_task_status(
        task_id,
        "DONE",
        output_path=str(primary_output) if primary_output else None,
        output_paths=output_paths_payload,
    )
    store.append_event(
        task_id,
        "done",
        stage="DONE",
        message="Task completed",
        progress=1.0,
        details={"output_path": str(primary_output) if primary_output else "", "output_paths": output_paths_payload},
    )
