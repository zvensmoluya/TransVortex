from __future__ import annotations

import hashlib
import json
import importlib.util
import math
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import fields, is_dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Any, Callable

from .aligner import apply_translations, merge_asr_window_segments, normalize_timeline, validate_segments
from ..artifacts.task_store import TaskStore
from ..artifacts.task_cache import cleanup_task_cache, task_cache_dir
from .asr import AsrEngine, write_segment_asr_output
from .chunking import number_and_chunk_segments, plan_translation_chunks
from ..app.config import apply_route_overrides, load_app_config
from ..app.asr_resolution import (
    build_active_asr_intent_snapshot,
    restore_asr_intent_snapshot,
)
from ..app.asr_runtime import asr_provider_readiness
from ..app.credentials import resolve_provider_credential
from ..openrouter_asr import openrouter_asr_model_profile
from ..formats.exporter import export_ass, export_lrc, export_srt, export_vtt, subtitle_delivery_report
from .media import (
    extract_audio_for_asr,
    extract_subtitle_stream,
    list_subtitle_streams,
    prepare_cloud_asr_audio_upload,
    select_subtitle_stream,
    split_audio_for_asr,
)
from .media_tools import resolve_media_executable
from .openrouter_asr_usage import (
    record_openrouter_asr_usage_receipt as _record_openrouter_asr_usage_receipt,
    write_openrouter_asr_usage_artifact as _write_openrouter_asr_usage_artifact,
)
from ..memory.checker import check_consistency, write_consistency_issues
from ..memory.bootstrapper import bootstrap_memory
from ..memory.collections import build_selected_collections_snapshot, collection_store_for_config
from ..memory.presets import build_selected_presets_snapshot
from ..memory.store import MemoryStore
from ..memory.plan import (
    effective_memory_sources,
    memory_enabled,
    runs_bootstrap,
    translates_with_memory,
    uses_collections,
    uses_presets,
)
from ..app.models import AppConfig, MemoryCollectionRef, MemoryPresetRef, Segment, TaskRecord
from ..asr_domain import (
    ASR_PLAN_SCHEMA_VERSION,
    ASR_RETRY_SCHEMA_VERSION,
    AsrExecutionPlan,
    AsrPlanWindow,
    AsrRetryDecision,
    AsrRetryParent,
    AsrSplitRetryStrategy,
    AsrTimelinePlan,
    AudioFacts,
    AudioStreamFacts,
    CanonicalAudioFacts,
    ResolvedAsrPlan,
    ResolvedAsrRetryPlan,
    SilenceAnalysisFacts,
)
from ..providers.probe import probe_provider
from ..protocol.errors import PipelineTaskError, classify_exception
from ..formats.srt import parse_srt_file
from ..http import is_retryable_http_error
from .subtitle_compression import compress_overlong_subtitles
from .subtitle_optimizer import optimize_subtitles
from .subtitle_reflow import reflow_subtitles
from .source_cleaner import clean_source_segments
from .asr_quality import detect_asr_boundary_risks
from .translate import (
    _adaptive_chunk_by_id,
    _source_chunk_completed_count,
    iter_translate_all_chunks,
    translate_all_chunks,
)
from .translation_validation import validate_translation_response, validation_to_json
from .word_timeline import merge_word_timeline_windows
from .asr_planning import (
    _active_asr_provider,
    _apply_resolved_asr_plan,
    _asr_allows_split_retry,
    _asr_duration_hard_limit,
    _asr_plan_id,
    _asr_plan_window_from_manifest,
    _asr_runs_concurrently,
    _asr_upload_hard_limit,
    _asr_uses_previous_text,
    _asr_uses_word_timeline,
    _ensure_resolved_asr_plan,
    _finite_number,
    _ingest_artifacts_valid,
    _portable_asr_manifest,
    _resolve_task_artifact_ref,
    _resolved_asr_plan,
    _sha256_file,
    _stable_plan_identity,
    _strict_nonnegative_int,
    _task_artifact_ref_from_path,
    _task_dir_from_paths,
    _validate_asr_plan_policy_limits,
    _validate_asr_window_sequence,
    _validated_asr_segment_id,
    _validated_plan_window,
)
from .asr_execution import (
    AsrExecutionDependencies,
    _asr_artifact_paths,
    _asr_item_upload_mb,
    _asr_prompt_text,
    _is_retryable_asr_exception,
    _parse_asr_rows,
    _process_asr_manifest_item as _process_asr_manifest_item_impl,
    _run_asr_segments_concurrent as _run_asr_segments_concurrent_impl,
    _run_asr_segments_serial as _run_asr_segments_serial_impl,
    _sync_checkpoint_openrouter_asr_usage,
    _take_asr_upload_batch,
    filter_asr_rows_for_source,
)
from .pipeline_runtime import (
    TaskCancelled,
    _check_cancel,
    _ensure_artifact_dirs,
    _is_nonempty_file,
    _is_valid_json_list,
    _require_file,
)
from .source_pipeline import (
    _clean_asr_source_segments,
    _legacy_asr_segments_path,
    _load_segments_from_input,
    _mark_asr_boundary_quality,
    _raw_source_segments_path,
    _segments_with_source,
    _source_segments_path,
    load_source_segments,
    persist_raw_source_segments,
    persist_source_segments,
)
from .translation_pipeline import (
    _backfill_translation_validation,
    _effective_initial_chunk_lines,
    _effective_translation_chunk_lines,
    _primary_translation_provider,
    _translation_done_count,
    _translation_progress_value,
    _translation_route_providers,
    _translation_row_for_artifact,
    _write_translation_experiment_artifacts,
)
from .delivery_planning import _normalize_output_format, _output_paths_for_task
from .pipeline_stages import (
    PipelineExecutionContext,
    PipelineStageDependencies,
    run_export_stage,
    run_ingest_stage,
    run_memory_stage,
    run_precheck_stage,
    run_quality_stage,
    run_translation_stage,
)
from ..utils import append_jsonl, gen_task_id, read_json, read_jsonl, to_plain, utc_now_iso, write_json


def _build_asr_engine(config: AppConfig, *, task: TaskRecord, root_dir: Path) -> AsrEngine:
    provider = _active_asr_provider(config)
    return AsrEngine(
        source_lang=task.source_lang,
        prompt=_asr_prompt_text(config),
        asr_provider=provider,
        root_dir=root_dir,
    )


def _asr_execution_dependencies() -> AsrExecutionDependencies:
    return AsrExecutionDependencies(
        build_engine=_build_asr_engine,
        prepare_cloud_asr_audio_upload=prepare_cloud_asr_audio_upload,
        split_audio_for_asr=split_audio_for_asr,
    )


def _process_asr_manifest_item(
    *,
    item: dict,
    asr: Any,
    paths: dict[str, Path],
    config: AppConfig,
    task: TaskRecord | None = None,
    root_dir: Path | None = None,
    allow_split_retry: bool = True,
    previous_text: str = "",
    usage_source_dir: Path | None = None,
) -> dict[str, Any]:
    return _process_asr_manifest_item_impl(
        dependencies=_asr_execution_dependencies(),
        item=item,
        asr=asr,
        paths=paths,
        config=config,
        task=task,
        root_dir=root_dir,
        allow_split_retry=allow_split_retry,
        previous_text=previous_text,
        usage_source_dir=usage_source_dir,
    )


def _run_asr_segments_serial(
    *,
    items: list[dict],
    asr: Any,
    paths: dict[str, Path],
    config: AppConfig,
    store: TaskStore,
    task_id: str,
    checkpoint: dict,
    asr_done: set[int],
    total_segments: int,
    task: TaskRecord | None = None,
    root_dir: Path | None = None,
) -> None:
    _run_asr_segments_serial_impl(
        dependencies=_asr_execution_dependencies(),
        items=items,
        asr=asr,
        paths=paths,
        config=config,
        store=store,
        task_id=task_id,
        checkpoint=checkpoint,
        asr_done=asr_done,
        total_segments=total_segments,
        task=task,
        root_dir=root_dir,
    )


def _run_asr_segments_concurrent(
    *,
    items: list[dict],
    asr: Any,
    paths: dict[str, Path],
    config: AppConfig,
    store: TaskStore,
    task_id: str,
    checkpoint: dict,
    asr_done: set[int],
    total_segments: int,
    task: TaskRecord,
    root_dir: Path,
) -> None:
    _run_asr_segments_concurrent_impl(
        dependencies=_asr_execution_dependencies(),
        items=items,
        asr=asr,
        paths=paths,
        config=config,
        store=store,
        task_id=task_id,
        checkpoint=checkpoint,
        asr_done=asr_done,
        total_segments=total_segments,
        task=task,
        root_dir=root_dir,
    )


def _task_paths(store: TaskStore, task_id: str, cache_root: Path) -> dict[str, Path]:
    base = store.task_dir(task_id)
    cache = task_cache_dir(cache_root, task_id)
    return {
        "base": base,
        "cache": cache,
        "media": cache / "media",
        "asr": base / "asr",
        "source": base / "source",
        "translate": base / "translate",
        "final": base / "final",
        "quality": base / "quality",
        "memory": base / "memory",
        "output": base / "output",
        "chunks": base / "chunks",
    }


def _stage_progress(stage: str) -> float:
    return {
        "INIT": 0.0,
        "QUEUED": 0.0,
        "PRECHECK": 0.02,
        "INGEST": 0.08,
        "ASR": 0.25,
        "MEMORY": 0.54,
        "SEGMENT": 0.55,
        "TRANSLATE": 0.65,
        "ALIGN": 0.85,
        "QUALITY": 0.9,
        "EXPORT": 0.95,
        "DONE": 1.0,
    }.get(stage, 0.0)


def _emit_stage(store: TaskStore, task_id: str, stage: str, message: str) -> None:
    store.update_task_status(task_id, stage, clear_error=True)
    try:
        checkpoint = store.load_checkpoint(task_id)
        _clear_checkpoint_error(checkpoint)
        checkpoint["status"] = stage
        store.save_checkpoint(task_id, checkpoint)
    except Exception:
        pass
    store.append_event(task_id, "stage", stage=stage, message=message, progress=_stage_progress(stage))


def _clear_checkpoint_error(checkpoint: dict[str, Any]) -> None:
    checkpoint.pop("error", None)
    checkpoint.pop("error_info", None)


def _progress_detail_from_checkpoint(checkpoint: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "ingest_done",
        "source_segment_count",
        "asr_total_segments",
        "asr_done_count",
        "asr_usage",
        "memory_current_mode",
        "memory_current_attempt",
        "memory_current_max_attempts",
        "memory_current_provider",
        "memory_current_model",
        "memory_current_chunk",
        "memory_current_chunk_ids",
        "memory_attempt_started_at",
        "memory_last_completed_at",
        "memory_bootstrap_status",
        "memory_bootstrap_actions",
        "translate_total_chunks",
        "translate_done_count",
        "translate_current_chunk",
        "translate_current_chunk_ids",
        "translate_current_segment_id",
        "translate_current_attempt",
        "translate_current_max_attempts",
        "translate_current_provider",
        "translate_current_model",
        "translate_current_mode",
        "translate_attempt_started_at",
        "translate_last_completed_at",
        "translate_memory_entries",
        "translate_recovery_chunk",
        "translate_recovery_batch_index",
        "translate_recovery_batch_total",
        "translate_recovery_segment_count",
        "quality_status",
        "quality_current_mode",
        "quality_current_attempt",
        "quality_current_max_attempts",
        "quality_current_provider",
        "quality_current_model",
        "quality_current_chunk",
        "quality_current_chunk_ids",
        "quality_current_segment_id",
        "quality_attempt_started_at",
        "quality_last_completed_at",
        "quality_issue_counts",
        "quality_residual_counts",
        "delivery_status",
        "delivery_issue_counts",
        "transport",
        "http_version",
        "streaming",
        "first_byte_at",
        "last_chunk_at",
        "bytes_received",
        "adaptive_parent_chunk",
        "adaptive_child_chunks",
        "model_request_count",
        "model_request_counts",
        "model_request_stage_counts",
        "model_request_last_mode",
        "model_request_last_stage",
        "model_request_last_started_at",
    ]
    detail = {key: checkpoint[key] for key in keys if key in checkpoint}
    if "translate_done_chunks" in checkpoint:
        detail["translate_done_chunks"] = checkpoint.get("translate_done_chunks") or []
    return detail


def _checkpoint_progress(checkpoint: dict[str, Any]) -> float:
    stage = str(checkpoint.get("status") or "").upper()
    if stage == "ASR":
        done = int(checkpoint.get("asr_done_count") or len(checkpoint.get("asr_done_segments") or []))
        total = int(checkpoint.get("asr_total_segments") or 0)
        if total > 0:
            return 0.25 + 0.25 * min(1.0, done / total)
    if stage == "TRANSLATE":
        done = int(checkpoint.get("translate_done_count") or 0)
        total = int(checkpoint.get("translate_total_chunks") or 0)
        if total > 0:
            return 0.65 + 0.18 * min(1.0, done / total)
    return _stage_progress(stage)


def _checkpoint_status_payload(store: TaskStore, task_id: str) -> dict[str, Any]:
    try:
        checkpoint = store.load_checkpoint(task_id)
    except Exception:
        return {}
    payload: dict[str, Any] = {
        "checkpoint_status": checkpoint.get("status"),
        "checkpoint_updated_at": checkpoint.get("updated_at"),
        "progress": _checkpoint_progress(checkpoint),
    }
    progress_detail = _progress_detail_from_checkpoint(checkpoint)
    receipts_dir = store.task_dir(task_id) / "source" / "asr" / "usage_receipts"
    if receipts_dir.is_dir():
        try:
            _usage_path, live_usage = _write_openrouter_asr_usage_artifact(
                {"source": store.task_dir(task_id) / "source"},
                None,
            )
        except Exception:
            live_usage = None
        if live_usage is not None:
            progress_detail["asr_usage"] = live_usage
    if progress_detail:
        payload["progress_detail"] = progress_detail
    return payload


def _translation_progress_callback(
    store: TaskStore,
    task_id: str,
    checkpoint: dict[str, Any],
    *,
    stage: str = "TRANSLATE",
):
    lock = threading.Lock()

    def handle(event: dict[str, Any]) -> None:
        with lock:
            mode = str(event.get("mode") or "translate")
            now = utc_now_iso()
            effective_stage = str(stage or "TRANSLATE").upper()
            prefix = {"MEMORY": "memory", "QUALITY": "quality"}.get(effective_stage, "translate")
            provider_meta = event.get("provider_meta") if isinstance(event.get("provider_meta"), dict) else {}
            request_state = str(event.get("request_state") or "").strip().lower()
            if not request_state:
                if provider_meta:
                    request_state = "completed"
                elif event.get("provider") is not None and event.get("model") is not None:
                    request_state = "started"
                else:
                    request_state = "activity"
            checkpoint["status"] = effective_stage
            request_number = int(checkpoint.get("model_request_count") or 0)
            if request_state != "completed":
                checkpoint[f"{prefix}_current_mode"] = mode
                if event.get("attempt") is not None:
                    checkpoint[f"{prefix}_current_attempt"] = int(event.get("attempt") or 1)
                if event.get("max_attempts") is not None:
                    checkpoint[f"{prefix}_current_max_attempts"] = int(event.get("max_attempts") or 1)
                if request_state == "started":
                    checkpoint[f"{prefix}_attempt_started_at"] = now
                if event.get("provider") is not None:
                    checkpoint[f"{prefix}_current_provider"] = str(event.get("provider"))
                if event.get("model") is not None:
                    checkpoint[f"{prefix}_current_model"] = str(event.get("model"))
                if event.get("chunk_id") is not None:
                    checkpoint[f"{prefix}_current_chunk"] = str(event.get("chunk_id"))
                    checkpoint.pop(f"{prefix}_current_chunk_ids", None)
                if event.get("chunk_ids") is not None:
                    checkpoint[f"{prefix}_current_chunk_ids"] = [str(item) for item in event.get("chunk_ids") or []]
                    checkpoint.pop(f"{prefix}_current_chunk", None)
                if event.get("segment_id") is not None:
                    checkpoint[f"{prefix}_current_segment_id"] = int(event.get("segment_id"))
                else:
                    checkpoint.pop(f"{prefix}_current_segment_id", None)
                if event.get("memory_entries") is not None:
                    checkpoint["translate_memory_entries"] = int(event.get("memory_entries") or 0)
                if mode == "batch_recovery":
                    checkpoint["translate_recovery_chunk"] = str(event.get("recovery_chunk_id") or "")
                    checkpoint["translate_recovery_batch_index"] = int(event.get("batch_index") or 1)
                    checkpoint["translate_recovery_batch_total"] = int(event.get("batch_total") or 1)
                    checkpoint["translate_recovery_segment_count"] = len(event.get("segment_ids") or [])
            else:
                checkpoint[f"{prefix}_last_completed_at"] = now
            if request_state == "started":
                request_number += 1
                checkpoint["model_request_count"] = request_number
                mode_counts = dict(checkpoint.get("model_request_counts") or {})
                mode_counts[mode] = int(mode_counts.get(mode) or 0) + 1
                checkpoint["model_request_counts"] = mode_counts
                stage_counts = dict(checkpoint.get("model_request_stage_counts") or {})
                current_stage_counts = dict(stage_counts.get(effective_stage) or {})
                current_stage_counts[mode] = int(current_stage_counts.get(mode) or 0) + 1
                stage_counts[effective_stage] = current_stage_counts
                checkpoint["model_request_stage_counts"] = stage_counts
                checkpoint["model_request_last_mode"] = mode
                checkpoint["model_request_last_stage"] = effective_stage
                checkpoint["model_request_last_started_at"] = now
            for source_key, target_key in [
                ("transport", "transport"),
                ("http_version", "http_version"),
                ("streaming", "streaming"),
                ("first_byte_at", "first_byte_at"),
                ("last_chunk_at", "last_chunk_at"),
                ("bytes_received", "bytes_received"),
                ("adaptive_parent_chunk", "adaptive_parent_chunk"),
                ("adaptive_child_chunks", "adaptive_child_chunks"),
            ]:
                value = event.get(source_key, provider_meta.get(source_key))
                if value is not None:
                    checkpoint[target_key] = value
            store.save_checkpoint(task_id, checkpoint)
            if request_state == "completed":
                event_type = "provider_response"
                label = "Provider response received"
            elif request_state == "activity":
                event_type = "progress"
                label = "Adaptive translation split" if mode == "adaptive_split" else f"Translation {mode} activity"
            elif mode == "memory_patch":
                event_type = "provider_attempt"
                label = "Memory patch request"
            elif mode == "adaptive_split":
                event_type = "progress"
                label = "Adaptive translation split"
            else:
                event_type = "provider_attempt"
                label = f"Translation {mode} request"
            store.append_event(
                task_id,
                event_type,
                stage=effective_stage,
                message=label,
                details={
                    key: value
                    for key, value in {
                        "mode": mode,
                        "request_state": request_state,
                        "request_number": request_number if request_state == "started" else None,
                        "request_part": event.get("request_part"),
                        "chunk_id": event.get("chunk_id"),
                        "chunk_ids": event.get("chunk_ids"),
                        "recovery_chunk_id": event.get("recovery_chunk_id"),
                        "segment_id": event.get("segment_id"),
                        "segment_ids": event.get("segment_ids"),
                        "batch_index": event.get("batch_index"),
                        "batch_total": event.get("batch_total"),
                        "provider": event.get("provider"),
                        "model": event.get("model"),
                        "attempt": event.get("attempt"),
                        "max_attempts": event.get("max_attempts"),
                        "memory_entries": event.get("memory_entries"),
                        "transport": event.get("transport", provider_meta.get("transport")),
                        "http_version": event.get("http_version", provider_meta.get("http_version")),
                        "streaming": event.get("streaming", provider_meta.get("streaming")),
                        "first_byte_at": event.get("first_byte_at", provider_meta.get("first_byte_at")),
                        "last_chunk_at": event.get("last_chunk_at", provider_meta.get("last_chunk_at")),
                        "bytes_received": event.get("bytes_received", provider_meta.get("bytes_received")),
                        "adaptive_parent_chunk": event.get("adaptive_parent_chunk"),
                        "adaptive_child_chunks": event.get("adaptive_child_chunks"),
                    }.items()
                    if value is not None
                },
            )

    return handle


def _video_needs_asr(config: AppConfig, task: TaskRecord) -> bool:
    input_type = str(task.settings.get("input_type", "video_asr_translate"))
    if input_type not in {"video_asr_translate", "video_asr"}:
        return False
    if str(task.settings.get("source_mode", config.pipeline.source_mode)) == "asr":
        return True
    if str(task.settings.get("source_mode", config.pipeline.source_mode)) == "embedded_subtitle":
        return False
    try:
        streams = list_subtitle_streams(Path(task.input_file))
    except Exception:
        return True
    selected = select_subtitle_stream(
        streams,
        source_lang=task.source_lang,
        subtitle_track=str(task.settings.get("subtitle_track", config.pipeline.subtitle_track)),
    )
    return selected is None


def _preflight(
    config: AppConfig,
    store: TaskStore,
    task: TaskRecord,
    output_file: Path | None,
    *,
    root_dir: Path,
    providers_file: Path | None,
) -> None:
    input_type = str(task.settings.get("input_type", "video_asr_translate"))
    input_path = Path(task.input_file)
    if not input_path.exists():
        raise RuntimeError(f"Input file not found: {input_path}")
    if not input_path.is_file():
        raise RuntimeError(f"Input path is not a file: {input_path}")
    if input_type in {"video_asr_translate", "video_asr"}:
        for binary in ("ffmpeg", "ffprobe"):
            if resolve_media_executable(binary) is None:
                raise RuntimeError(f"Required media executable not found: {binary}")
    output_dir = output_file.parent if output_file else store.task_dir(task.task_id) / "output"
    output_dir.mkdir(parents=True, exist_ok=True)
    probe_file = output_dir / ".tvx_write_probe"
    try:
        probe_file.write_text("ok", encoding="utf-8")
    finally:
        probe_file.unlink(missing_ok=True)
    needs_asr = _video_needs_asr(config, task)
    if needs_asr:
        asr_provider = _active_asr_provider(config)
        if asr_provider.kind == "local_inprocess":
            if asr_provider.protocol != "faster_whisper":
                raise RuntimeError(f"unsupported_asr_protocol: {asr_provider.protocol}")
            if importlib.util.find_spec("faster_whisper") is None:
                raise RuntimeError("faster-whisper is required for ASR. Install with: pip install -e .[asr]")
        elif asr_provider.kind == "local_worker":
            readiness = asr_provider_readiness(asr_provider, root_dir=root_dir)
            if readiness.get("can_run") is not True:
                raise RuntimeError(f"ASR provider is not ready: {readiness.get('code', 'unavailable')}")
        elif asr_provider.kind in {"local_server", "remote"}:
            if asr_provider.protocol not in {
                "openai_transcriptions",
                "funasr_openai",
                "openrouter_stt",
            }:
                raise RuntimeError(f"unsupported_asr_protocol: {asr_provider.protocol}")
            if asr_provider.auth.type == "bearer":
                credential = resolve_provider_credential(
                    asr_provider,
                    root_dir=root_dir,
                )
                if not credential.found:
                    raise RuntimeError(f"Missing credential: {credential.credential_id or credential.env_key}")
            elif asr_provider.auth.type != "none":
                raise RuntimeError(f"unsupported_asr_auth_type: {asr_provider.auth.type}")
        else:
            raise RuntimeError(f"unsupported_asr_provider_kind: {asr_provider.kind}")
    if input_type != "video_asr":
        route = config.routing.primary
        provider = config.providers.get(route.provider)
        if not provider:
            raise RuntimeError(f"Translation provider not found: {route.provider}")
        report = probe_provider(
            root_dir=root_dir,
            providers_file=providers_file,
            provider_name=route.provider,
            model=route.model,
            source_lang=task.source_lang,
            target_lang=task.target_lang,
        )
        failures = [
            f"{row.get('name')}: {row.get('message')}"
            for row in report.get("checks", [])
            if row.get("status") == "FAIL"
        ]
        if failures:
            raise RuntimeError(f"Provider preflight failed: {'; '.join(failures)}")


def _status_json(task: TaskRecord, store: TaskStore | None = None) -> dict[str, Any]:
    payload = {
        "task_id": task.task_id,
        "status": task.status,
        "input_file": task.input_file,
        "source_lang": task.source_lang,
        "target_lang": task.target_lang,
        "bilingual": task.bilingual,
        "created_at": task.created_at,
        "updated_at": task.updated_at,
        "output_path": task.output_path,
        "output_paths": task.output_paths,
        "error": None if task.status == "DONE" else task.error,
        "error_info": None if task.status == "DONE" else task.error_info,
    }
    if store is not None:
        payload.update(_checkpoint_status_payload(store, task.task_id))
        try:
            from ..artifacts.runtime import TaskRuntime

            payload["runtime"] = TaskRuntime(store.artifacts_dir).status_payload(task)
        except Exception:
            payload["runtime"] = {
                "state": "unknown",
                "can_cancel": task.status not in {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"},
                "can_resume": task.status in {"FAILED", "CANCELLED", "INTERRUPTED"},
                "worker_pid": None,
                "last_seen": "",
                "stale_reason": "",
            }
    return payload


def _create_task(
    store: TaskStore,
    input_file: Path,
    source_lang: str,
    target_lang: str,
    bilingual: bool,
    settings: dict,
) -> TaskRecord:
    task = TaskRecord(
        task_id=gen_task_id(),
        input_file=str(input_file),
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        status="INIT",
        created_at=utc_now_iso(),
        updated_at=utc_now_iso(),
        settings=settings,
    )
    store.save_task(task)
    return task


def create_pipeline_task(
    *,
    root_dir: Path,
    input_file: Path,
    source_lang: str,
    target_lang: str,
    bilingual: bool = False,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | None = None,
    input_type: str = "video_asr_translate",
    status: str = "QUEUED",
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> tuple[str, Path]:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model, routing=routing)
    normalized_input_type = input_type if input_type in {"video_asr_translate", "srt_translate", "segments_translate", "video_asr"} else "video_asr_translate"
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    collection_snapshot = None
    if uses_collections(config.pipeline.memory):
        collection_snapshot = build_selected_collections_snapshot(
            collection_ids=[item.id for item in config.pipeline.memory.collections],
            store=collection_store_for_config(root_dir=root_dir, config=config),
            source_lang=source_lang,
            target_lang=target_lang,
        )
    task = _create_task(
        store,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        settings=_task_settings(config, input_type=normalized_input_type, root_dir=root_dir),
    )
    if collection_snapshot is not None:
        MemoryStore(store.task_dir(task.task_id) / "memory").save_selected_collections(collection_snapshot)
    if status != "INIT":
        store.update_task_status(task.task_id, status)
    store.clear_cancel(task.task_id)
    store.append_event(task.task_id, "task_created", stage=status, message="Task created", progress=_stage_progress(status))
    if collection_snapshot is not None:
        report = dict(collection_snapshot.get("report") or {})
        store.append_event(
            task.task_id,
            "artifact",
            stage="MEMORY",
            message="Memory collections snapshot frozen",
            details={
                "path": str(store.task_dir(task.task_id) / "memory" / "selected_collections.json"),
                "applied": report.get("applied") or [],
                "skipped": report.get("skipped") or [],
                "conflicts": report.get("conflicts") or [],
                "entries": int(report.get("entries") or 0),
            },
        )
    return task.task_id, config.pipeline.artifacts_dir


def _task_settings(config: AppConfig, *, input_type: str, root_dir: Path) -> dict[str, Any]:
    settings = to_plain(config.pipeline)
    settings["input_type"] = input_type
    settings["source_mode"] = config.pipeline.source_mode
    settings["subtitle_track"] = config.pipeline.subtitle_track
    settings["routing"] = to_plain(config.routing)
    if input_type in {"video_asr_translate", "video_asr"}:
        asr_intent = build_active_asr_intent_snapshot(config, root_dir=root_dir)
        if asr_intent:
            settings["asr_intent"] = asr_intent
    settings.setdefault("edited", False)
    return settings


def _apply_saved_asr_settings(
    config: AppConfig,
    settings: dict[str, Any],
    *,
    root_dir: Path,
) -> None:
    raw = settings.get("asr_intent")
    if isinstance(raw, dict):
        restore_asr_intent_snapshot(config, raw, root_dir=root_dir)


def _apply_saved_pipeline_settings(config: AppConfig, settings: dict[str, Any]) -> None:
    def apply_dataclass(target: Any, values: dict[str, Any]) -> None:
        if not is_dataclass(target):
            return
        field_names = {item.name for item in fields(target)}
        for name, value in values.items():
            if name not in field_names or name in {"artifacts_dir"}:
                continue
            current = getattr(target, name)
            if is_dataclass(current) and isinstance(value, dict):
                apply_dataclass(current, value)
                continue
            if isinstance(current, Path):
                setattr(target, name, Path(str(value)))
                continue
            if isinstance(current, list):
                continue
            if isinstance(value, dict):
                continue
            setattr(target, name, value)

    apply_dataclass(config.pipeline, settings)
    memory_settings = settings.get("memory")
    if isinstance(memory_settings, dict):
        raw_collections = memory_settings.get("collections")
        if isinstance(raw_collections, list):
            config.pipeline.memory.collections = [
                MemoryCollectionRef(id=str(item.get("id") or "").strip())
                for item in raw_collections
                if isinstance(item, dict) and str(item.get("id") or "").strip()
            ]
        else:
            # Tasks created before collection support must resume without
            # inheriting a newly configured global collection.
            config.pipeline.memory.collections = []
        raw_presets = memory_settings.get("presets")
        if isinstance(raw_presets, list):
            config.pipeline.memory.presets = [
                MemoryPresetRef(
                    id=str(item.get("id") or "").strip(),
                    override_status=str(item.get("override_status") or "").strip(),
                )
                for item in raw_presets
                if isinstance(item, dict) and str(item.get("id") or "").strip()
            ]


def _task_routing_override(
    task: TaskRecord,
    *,
    routing: dict[str, Any] | None,
    provider_name: str | None,
    model: str | None,
) -> dict[str, Any] | None:
    if routing is not None:
        return routing
    if provider_name or model:
        return None
    saved = task.settings.get("routing")
    return saved if isinstance(saved, dict) else None


def _save_task_routing_settings(
    store: TaskStore,
    task: TaskRecord,
    config: AppConfig,
) -> None:
    task.settings["routing"] = to_plain(config.routing)
    store.save_task(task)


def _resolve_video_source_mode(config: AppConfig, task: TaskRecord) -> tuple[str, dict | None, list[dict]]:
    requested = str(task.settings.get("source_mode", config.pipeline.source_mode))
    subtitle_track = str(task.settings.get("subtitle_track", config.pipeline.subtitle_track))
    if requested == "asr":
        return "asr", None, []
    try:
        streams = list_subtitle_streams(Path(task.input_file))
    except Exception:
        if requested == "embedded_subtitle":
            raise
        return "asr", None, []
    selected = select_subtitle_stream(streams, source_lang=task.source_lang, subtitle_track=subtitle_track)
    if requested == "embedded_subtitle":
        if selected is None:
            raise RuntimeError("No matching text subtitle stream found")
        return "embedded_subtitle", selected, streams
    if selected is not None:
        return "embedded_subtitle", selected, streams
    return "asr", None, streams


def _translate_all_chunks_accepts_progress_callback() -> bool:
    try:
        import inspect

        return "progress_callback" in inspect.signature(translate_all_chunks).parameters
    except Exception:
        return False


def _translate_all_chunks_accepts_memory_dir() -> bool:
    try:
        import inspect

        return "memory_dir" in inspect.signature(translate_all_chunks).parameters
    except Exception:
        return False


def _iter_translation_results(
    config: AppConfig,
    chunks,
    *,
    source_lang: str,
    target_lang: str,
    already_done: set[str],
    memory_dir: Path | None = None,
    progress_callback=None,
):
    if translate_all_chunks.__module__ != "transvortex.core.translate":
        extra = {"progress_callback": progress_callback} if _translate_all_chunks_accepts_progress_callback() else {}
        if memory_dir is not None and _translate_all_chunks_accepts_memory_dir():
            yield from translate_all_chunks(
                config,
                chunks,
                source_lang=source_lang,
                target_lang=target_lang,
                already_done=already_done,
                memory_dir=memory_dir,
                **extra,
            )
        else:
            yield from translate_all_chunks(
                config,
                chunks,
                source_lang=source_lang,
                target_lang=target_lang,
                already_done=already_done,
                **extra,
            )
        return
    yield from iter_translate_all_chunks(
        config,
        chunks,
        source_lang=source_lang,
        target_lang=target_lang,
        already_done=already_done,
        memory_dir=memory_dir,
        progress_callback=progress_callback,
    )


def run_pipeline(
    *,
    root_dir: Path,
    input_file: Path,
    source_lang: str,
    target_lang: str,
    bilingual: bool = False,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | None = None,
    input_type: str = "video_asr_translate",
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    task_id, artifacts_dir = create_pipeline_task(
        root_dir=root_dir,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        providers_file=providers_file,
        cli_overrides=cli_overrides,
        provider_name=provider_name,
        model=model,
        routing=routing,
        input_type=input_type,
        status="INIT",
        event_sink=event_sink,
    )
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model, routing=routing)
    store = TaskStore(artifacts_dir, event_sink=event_sink)
    _execute_task(
        config,
        store,
        task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task_id


def resume_pipeline(
    *,
    root_dir: Path,
    task_id: str,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | None = None,
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = store.load_task(task_id)
    effective_routing = _task_routing_override(
        task,
        routing=routing,
        provider_name=provider_name,
        model=model,
    )
    config = apply_route_overrides(config, provider_name=provider_name, model=model, routing=effective_routing)
    _apply_saved_pipeline_settings(config, task.settings)
    _apply_saved_asr_settings(config, task.settings, root_dir=root_dir)
    _save_task_routing_settings(store, task, config)
    store.clear_cancel(task_id)
    store.update_task_status(task_id, "QUEUED", clear_error=True)
    store.append_event(task_id, "resume_requested", stage="QUEUED", message="Resume requested")
    _execute_task(
        config,
        store,
        task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task_id


def queue_resume_task(
    *,
    root_dir: Path,
    task_id: str,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | None = None,
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> Path:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = store.load_task(task_id)
    effective_routing = _task_routing_override(
        task,
        routing=routing,
        provider_name=provider_name,
        model=model,
    )
    config = apply_route_overrides(config, provider_name=provider_name, model=model, routing=effective_routing)
    _apply_saved_pipeline_settings(config, task.settings)
    _apply_saved_asr_settings(config, task.settings, root_dir=root_dir)
    _save_task_routing_settings(store, task, config)
    store.clear_cancel(task_id)
    store.update_task_status(task_id, "QUEUED", clear_error=True)
    store.append_event(task_id, "resume_requested", stage="QUEUED", message="Resume requested")
    return config.pipeline.artifacts_dir


def execute_pipeline_task(
    *,
    root_dir: Path,
    task_id: str,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    routing: dict[str, Any] | None = None,
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = store.load_task(task_id)
    effective_routing = _task_routing_override(
        task,
        routing=routing,
        provider_name=provider_name,
        model=model,
    )
    config = apply_route_overrides(config, provider_name=provider_name, model=model, routing=effective_routing)
    _apply_saved_pipeline_settings(config, task.settings)
    _apply_saved_asr_settings(config, task.settings, root_dir=root_dir)
    _save_task_routing_settings(store, task, config)
    _execute_task(
        config,
        store,
        task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task_id


def _pipeline_stage_dependencies() -> PipelineStageDependencies:
    return PipelineStageDependencies(
        emit_stage=_emit_stage,
        preflight=_preflight,
        resolve_video_source_mode=_resolve_video_source_mode,
        extract_subtitle_stream=extract_subtitle_stream,
        extract_audio_for_asr=extract_audio_for_asr,
        split_audio_for_asr=split_audio_for_asr,
        build_asr_engine=_build_asr_engine,
        run_asr_segments_concurrent=_run_asr_segments_concurrent,
        run_asr_segments_serial=_run_asr_segments_serial,
        translation_progress_callback=_translation_progress_callback,
        iter_translation_results=_iter_translation_results,
    )


def _execute_task(
    config: AppConfig,
    store: TaskStore,
    task_id: str,
    output_file: Path | None = None,
    *,
    root_dir: Path,
    providers_file: Path | None = None,
) -> None:
    task = store.load_task(task_id)
    _apply_saved_asr_settings(config, task.settings, root_dir=root_dir)
    input_type = str(task.settings.get("input_type", "video_asr_translate"))
    cache_root = config.pipeline.cache_dir or config.pipeline.artifacts_dir / ".cache"
    paths = _task_paths(store, task_id, cache_root)
    _ensure_artifact_dirs(paths)

    checkpoint = store.load_checkpoint(task_id)
    _clear_checkpoint_error(checkpoint)
    try:
        context = PipelineExecutionContext(
            config=config,
            store=store,
            task=task,
            task_id=task_id,
            input_type=input_type,
            paths=paths,
            checkpoint=checkpoint,
            root_dir=root_dir,
            output_file=output_file,
            providers_file=providers_file,
        )
        dependencies = _pipeline_stage_dependencies()
        run_precheck_stage(context, dependencies)
        all_segments = run_ingest_stage(context, dependencies)
        if all_segments is None:
            return
        run_memory_stage(context, dependencies, all_segments)
        translated_file = run_translation_stage(context, dependencies, all_segments)
        final_segments = run_quality_stage(
            context,
            dependencies,
            all_segments,
            translated_file,
        )
        run_export_stage(context, dependencies, final_segments)
    except TaskCancelled as exc:
        err = classify_exception(exc, stage=str(checkpoint.get("status", task.status)))
        store.update_task_status(task_id, "CANCELLED", error=str(exc), error_info=err)
        try:
            _sync_checkpoint_openrouter_asr_usage(
                checkpoint,
                paths=paths,
                provider=_active_asr_provider(config),
            )
        except Exception:
            pass
        checkpoint["status"] = "CANCELLED"
        checkpoint["error"] = str(exc)
        checkpoint["error_info"] = err
        store.save_checkpoint(task_id, checkpoint)
        store.append_event(
            task_id,
            "cancelled",
            stage=checkpoint.get("status"),
            message=str(exc),
            level="warning",
            details={"error_info": err},
        )
        raise PipelineTaskError(task_id, err) from exc
    except Exception as exc:
        try:
            if store.load_task(task_id).status == "DONE":
                return
        except Exception:
            pass
        err = classify_exception(exc, stage=str(checkpoint.get("status", task.status)))
        store.update_task_status(task_id, "FAILED", error=str(exc), error_info=err)
        try:
            _sync_checkpoint_openrouter_asr_usage(
                checkpoint,
                paths=paths,
                provider=_active_asr_provider(config),
            )
        except Exception:
            pass
        checkpoint["status"] = "FAILED"
        checkpoint["error"] = str(exc)
        checkpoint["error_info"] = err
        store.save_checkpoint(task_id, checkpoint)
        store.append_event(
            task_id,
            "error",
            stage=str(checkpoint.get("status", task.status)),
            message=str(exc),
            level="error",
            details={"error_info": err},
        )
        raise PipelineTaskError(task_id, err) from exc
    finally:
        try:
            completed = store.load_task(task_id).status == "DONE"
        except Exception:
            completed = False
        if completed:
            try:
                cleanup_task_cache(cache_root, task_id)
            except OSError:
                # A later Local Service startup retries completed task caches.
                pass


def task_status_json(task: TaskRecord, store: TaskStore | None = None) -> dict[str, Any]:
    return _status_json(task, store=store)
