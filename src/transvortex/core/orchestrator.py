from __future__ import annotations

import importlib.util
import shutil
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import fields, is_dataclass
from pathlib import Path
from typing import Any, Callable

from .aligner import apply_translations, merge_asr_window_segments, normalize_timeline, validate_segments
from ..artifacts.task_store import TaskStore
from .asr import AsrEngine, write_segment_asr_output
from .chunking import number_and_chunk_segments, plan_translation_chunks
from ..app.config import apply_route_overrides, load_app_config
from ..app.credentials import resolve_credential
from ..formats.exporter import export_ass, export_srt
from .media import (
    extract_audio_for_asr,
    extract_subtitle_stream,
    list_subtitle_streams,
    prepare_cloud_asr_audio_upload,
    select_subtitle_stream,
    split_audio_for_asr,
)
from ..memory.checker import check_consistency, write_consistency_issues
from ..memory.bootstrapper import bootstrap_memory
from ..memory.presets import build_selected_presets_snapshot
from ..memory.store import MemoryStore
from ..memory.plan import (
    effective_memory_sources,
    memory_enabled,
    runs_bootstrap,
    translates_with_memory,
    uses_presets,
)
from ..app.models import AppConfig, Segment, TaskRecord
from ..providers.probe import probe_provider
from ..protocol.errors import PipelineTaskError, classify_exception
from ..formats.srt import parse_srt_file
from ..http import is_retryable_http_error
from .subtitle_compression import compress_overlong_subtitles
from .subtitle_optimizer import optimize_subtitles
from .subtitle_reflow import reflow_subtitles
from .translate import (
    _adaptive_chunk_by_id,
    _source_chunk_completed_count,
    iter_translate_all_chunks,
    translate_all_chunks,
)
from .translation_validation import validate_translation_response, validation_to_json
from ..utils import append_jsonl, gen_task_id, read_json, read_jsonl, to_plain, utc_now_iso, write_json


class TaskCancelled(RuntimeError):
    pass


def _parse_asr_rows(rows: list[dict], start_id: int) -> list[Segment]:
    out: list[Segment] = []
    next_id = start_id
    for row in rows:
        text = str(row.get("text", "")).strip()
        if not text:
            continue
        out.append(
            Segment(
                id=next_id,
                start=float(row["start"]),
                end=float(row["end"]),
                text_src=text,
                confidence=row.get("confidence"),
                meta=dict(row.get("meta") or {"source": "asr"}),
            )
        )
        next_id += 1
    return out


def _transcribe_asr_segment(
    asr: Any,
    audio_path: Path,
    segment_start_offset: float,
    *,
    prompt: str | None = None,
) -> tuple[list[dict], dict | None, dict[str, Any]]:
    if hasattr(asr, "transcribe_segment_result"):
        try:
            result = asr.transcribe_segment_result(audio_path, segment_start_offset, prompt=prompt)
        except TypeError:
            result = asr.transcribe_segment_result(audio_path, segment_start_offset)
        return list(result.rows), result.raw_response, dict(getattr(result, "transport_meta", {}) or {})
    return list(asr.transcribe_segment(audio_path, segment_start_offset)), None, {}


def _build_asr_engine(config: AppConfig, *, task: TaskRecord, root_dir: Path) -> AsrEngine:
    return AsrEngine(
        model_size=config.pipeline.asr_local.model_size,
        device=config.pipeline.asr_local.device,
        compute_type=config.pipeline.asr_local.compute_type,
        mode=config.pipeline.asr_mode,
        source_lang=task.source_lang,
        local_max_initial_timestamp=config.pipeline.asr_local.max_initial_timestamp,
        local_beam_size=config.pipeline.asr_local.beam_size,
        local_temperature=config.pipeline.asr_local.temperature,
        local_condition_on_previous_text=config.pipeline.asr_local.condition_on_previous_text,
        local_hotwords=config.pipeline.asr_local.hotwords,
        prompt=_asr_prompt_text(config),
        asr_provider=config.asr_providers.get(config.pipeline.asr_provider),
        root_dir=root_dir,
    )


def _is_retryable_asr_exception(exc: Exception) -> bool:
    if is_retryable_http_error(exc):
        return True
    lowered = str(exc).lower()
    return any(
        marker in lowered
        for marker in (
            "timed out",
            "timeout",
            "http error 408",
            "http error 429",
            "http error 500",
            "http error 502",
            "http error 503",
            "http error 504",
            "provider_timeout",
            "unexpected_eof",
            "eof occurred",
            "connection reset",
            "connection aborted",
            "remote end closed connection",
        )
    )


def _apply_audio_preprocess_meta(rows: list[dict], preprocess_meta: dict[str, Any]) -> list[dict]:
    summary = {
        "enabled": preprocess_meta.get("enabled", False),
        "backend": preprocess_meta.get("backend", ""),
        "leading_silence_seconds": preprocess_meta.get("leading_silence_seconds", 0.0),
        "trailing_silence_seconds": preprocess_meta.get("trailing_silence_seconds", 0.0),
        "trim_start_seconds": preprocess_meta.get("trim_start_seconds", 0.0),
        "trim_end_seconds": preprocess_meta.get("trim_end_seconds", 0.0),
        "skipped": preprocess_meta.get("skipped", False),
        "reason": preprocess_meta.get("reason", ""),
        "fallback_used": preprocess_meta.get("fallback_used", False),
        "fallback_reason": preprocess_meta.get("fallback_reason", ""),
    }
    out = []
    for row in rows:
        item = dict(row)
        meta = dict(item.get("meta") or {})
        meta["audio_preprocess"] = summary
        item["meta"] = meta
        out.append(item)
    return out


def _should_retry_cloud_asr_without_preprocess(rows: list[dict]) -> bool:
    texts = [str(row.get("text", "")).strip() for row in rows if str(row.get("text", "")).strip()]
    if not texts:
        return True
    combined = "".join(texts)
    return not any(ch.isalnum() for ch in combined)


def _max_char_run(value: str) -> int:
    longest = 0
    current = 0
    previous = ""
    for ch in value:
        if ch == previous:
            current += 1
        else:
            current = 1
            previous = ch
        longest = max(longest, current)
    return longest


def _asr_row_quality_decision(row: dict) -> tuple[str, list[str]]:
    text = str(row.get("text", "")).strip()
    duration = max(float(row.get("end", 0.0)) - float(row.get("start", 0.0)), 0.001)
    reasons: list[str] = []
    if not text:
        return "drop", ["empty_text"]
    if text in {"♪", "♪♪"} or not any(ch.isalnum() for ch in text):
        return "drop", ["non_speech_symbols"]
    if "�" in text:
        return "drop", ["replacement_character"]
    run = _max_char_run(text)
    cps = len(text) / duration
    if duration >= 10.0 and run >= 8:
        return "drop", ["long_repeated_hallucination"]
    if run >= 12 and cps >= 10:
        return "drop", ["extreme_repeated_sound"]
    if run >= 6:
        reasons.append("short_repeated_sound")
    if cps >= 18:
        reasons.append("high_source_cps")
    return ("warn" if reasons else "keep"), reasons


def filter_asr_rows_for_source(rows: list[dict]) -> tuple[list[dict], dict[str, Any]]:
    kept: list[dict] = []
    dropped: list[dict] = []
    warnings: list[dict] = []
    for row in rows:
        decision, reasons = _asr_row_quality_decision(row)
        item = dict(row)
        if decision == "drop":
            dropped.append(
                {
                    "start": row.get("start"),
                    "end": row.get("end"),
                    "text": row.get("text"),
                    "reasons": reasons,
                }
            )
            continue
        if decision == "warn":
            meta = dict(item.get("meta") or {})
            existing = list(meta.get("quality_warnings") or [])
            meta["quality_warnings"] = existing + reasons
            item["meta"] = meta
            warnings.append(
                {
                    "start": row.get("start"),
                    "end": row.get("end"),
                    "text": row.get("text"),
                    "reasons": reasons,
                }
            )
        kept.append(item)
    return kept, {
        "input_rows": len(rows),
        "kept_rows": len(kept),
        "dropped_rows": len(dropped),
        "warning_rows": len(warnings),
        "dropped": dropped,
        "warnings": warnings,
    }


def _asr_artifact_paths(paths: dict[str, Path], idx: int) -> dict[str, Path]:
    return {
        "rows": paths["source"] / "asr" / "rows" / f"segment_{idx:05d}.json",
        "raw": paths["source"] / "asr" / "raw" / f"segment_{idx:05d}.json",
        "preprocess": paths["source"] / "asr" / "preprocess" / f"segment_{idx:05d}.json",
        "upload": paths["source"] / "asr" / "upload" / f"segment_{idx:05d}.wav",
        "quality": paths["source"] / "asr" / "quality" / f"segment_{idx:05d}.json",
    }


def _write_asr_segment_artifacts(
    *,
    artifact_paths: dict[str, Path],
    rows: list[dict],
    raw_response: dict | None,
    preprocess_meta: dict[str, Any] | None,
) -> None:
    if preprocess_meta is not None:
        write_json(artifact_paths["preprocess"], preprocess_meta)
    if raw_response is not None:
        write_json(artifact_paths["raw"], raw_response)
    filtered_rows, quality = filter_asr_rows_for_source(rows)
    write_json(artifact_paths["quality"], quality)
    write_segment_asr_output(artifact_paths["rows"], filtered_rows)


def _asr_raw_response_with_transport(raw_response: dict | None, transport_meta: dict[str, Any]) -> dict | None:
    if raw_response is None:
        return None
    if not transport_meta:
        return raw_response
    return {**raw_response, "_transport_meta": transport_meta}


def _asr_previous_text(rows: list[dict]) -> str:
    return " ".join(str(row.get("text") or "").strip() for row in rows if str(row.get("text") or "").strip()).strip()


def _trim_asr_prompt(text: str, max_chars: int) -> str:
    text = str(text or "").strip()
    max_chars = max(int(max_chars), 0)
    if max_chars and len(text) > max_chars:
        return text[-max_chars:]
    return text


def _asr_segment_prompt(config: AppConfig, previous_text: str = "") -> str:
    prompt = config.pipeline.asr_prompt
    if not prompt.enabled:
        return ""
    max_chars = max(int(prompt.max_chars), 0)
    base_text = str(prompt.text or "").strip()
    if prompt.include_previous_text and previous_text.strip():
        previous_section = "Previous transcript:\n" + previous_text.strip()
        if base_text:
            text = base_text + "\n\n" + previous_section
            if max_chars and len(text) > max_chars:
                remaining = max(max_chars - len(base_text) - 2, 0)
                text = base_text
                if remaining:
                    text += "\n\n" + previous_section[-remaining:]
            return _trim_asr_prompt(text, max_chars)
        return _trim_asr_prompt(previous_section, max_chars)
    return _trim_asr_prompt(base_text, max_chars)


def _asr_uses_previous_text(config: AppConfig) -> bool:
    prompt = config.pipeline.asr_prompt
    return bool(prompt.enabled and prompt.include_previous_text)


def _previous_asr_text_from_completed(items: list[dict], paths: dict[str, Path]) -> str:
    if not items:
        return ""
    first_idx = min(int(item["segment_index"]) for item in items)
    for idx in range(first_idx - 1, -1, -1):
        rows_path = _asr_artifact_paths(paths, idx)["rows"]
        if not _is_valid_json_list(rows_path):
            continue
        text = _asr_previous_text(read_json(rows_path))
        if text:
            return text
    return ""


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
) -> dict[str, Any]:
    idx = int(item["segment_index"])
    artifact_paths = _asr_artifact_paths(paths, idx)
    audio_path = Path(item["path"])
    transcribe_path = audio_path
    transcribe_offset = float(item["start"])
    preprocess_meta: dict[str, Any] | None = None
    if config.pipeline.asr_mode == "cloud":
        trim_config = config.pipeline.asr_preprocessing.cloud_trim_silence
        preprocess_meta = prepare_cloud_asr_audio_upload(
            audio_path,
            artifact_paths["upload"],
            duration_seconds=float(item.get("duration", 0.0)),
            enabled=trim_config.enabled,
            backend=trim_config.backend,
            noise_db=trim_config.noise_db,
            min_silence_seconds=trim_config.min_silence_seconds,
            keep_preroll_seconds=trim_config.keep_preroll_seconds,
            trim_trailing=trim_config.trim_trailing,
            keep_postroll_seconds=trim_config.keep_postroll_seconds,
            min_upload_seconds=trim_config.min_upload_seconds,
        )
        if preprocess_meta.get("skipped"):
            rows: list[dict] = []
            _write_asr_segment_artifacts(
                artifact_paths=artifact_paths,
                rows=rows,
                raw_response=None,
                preprocess_meta=preprocess_meta,
            )
            return {"idx": idx, "rows": rows, "raw_response": None, "preprocess_meta": preprocess_meta, "skipped": True}
        transcribe_path = Path(preprocess_meta.get("upload_path") or audio_path)
        transcribe_offset += float(preprocess_meta.get("trim_start_seconds") or 0.0)
    try:
        segment_prompt = _asr_segment_prompt(config, previous_text)
        rows, raw_response, transport_meta = _transcribe_asr_segment(
            asr,
            transcribe_path,
            transcribe_offset,
            prompt=segment_prompt,
        )
    except Exception as exc:
        if (
            allow_split_retry
            and config.pipeline.asr_mode == "cloud"
            and _is_retryable_asr_exception(exc)
            and task is not None
            and root_dir is not None
            and float(item.get("duration", 0.0)) > max(float(config.pipeline.asr_chunking.min_window_seconds) * 2.0, 20.0)
        ):
            return _retry_asr_manifest_item_with_subsegments(
                item=item,
                paths=paths,
                config=config,
                task=task,
                root_dir=root_dir,
                failure=exc,
            )
        raise
    if preprocess_meta is not None:
        if preprocess_meta.get("reason") == "trimmed" and _should_retry_cloud_asr_without_preprocess(rows):
            fallback_rows, fallback_raw_response, fallback_transport_meta = _transcribe_asr_segment(
                asr,
                audio_path,
                float(item["start"]),
                prompt=segment_prompt,
            )
            if not _should_retry_cloud_asr_without_preprocess(fallback_rows):
                preprocess_meta["fallback_used"] = True
                preprocess_meta["fallback_reason"] = "preprocessed_asr_looked_empty_or_nonspeech"
                preprocess_meta["upload_path"] = str(audio_path)
                preprocess_meta["trim_start_seconds"] = 0.0
                preprocess_meta["trim_end_seconds"] = float(item.get("duration", 0.0))
                rows = fallback_rows
                raw_response = fallback_raw_response
                transport_meta = fallback_transport_meta
        rows = _apply_audio_preprocess_meta(rows, preprocess_meta)
    _write_asr_segment_artifacts(
        artifact_paths=artifact_paths,
        rows=rows,
        raw_response=_asr_raw_response_with_transport(raw_response, transport_meta),
        preprocess_meta=preprocess_meta,
    )
    return {
        "idx": idx,
        "rows": rows,
        "raw_response": _asr_raw_response_with_transport(raw_response, transport_meta),
        "preprocess_meta": preprocess_meta,
        "skipped": False,
        "transport_meta": transport_meta,
    }


def _retry_asr_manifest_item_with_subsegments(
    *,
    item: dict,
    paths: dict[str, Path],
    config: AppConfig,
    task: TaskRecord,
    root_dir: Path,
    failure: Exception,
) -> dict[str, Any]:
    idx = int(item["segment_index"])
    artifact_paths = _asr_artifact_paths(paths, idx)
    duration = float(item.get("duration", 0.0))
    retry_dir = paths["media"] / "segments_retry" / f"segment_{idx:05d}"
    max_child_window = max(
        float(config.pipeline.asr_chunking.min_window_seconds),
        min(float(config.pipeline.asr_chunking.max_window_seconds), duration / 2.0),
    )
    source_audio_path_raw = item.get("source_audio_path")
    source_audio_path = Path(str(source_audio_path_raw or item.get("path")))
    source_start_seconds = float(item.get("start", 0.0)) if source_audio_path_raw else 0.0
    child_manifest = split_audio_for_asr(
        source_audio_path,
        retry_dir,
        mode=config.pipeline.asr_chunking.mode,
        window_seconds=int(max_child_window),
        max_window_seconds=int(max_child_window),
        min_window_seconds=config.pipeline.asr_chunking.min_window_seconds,
        overlap_seconds=config.pipeline.asr_chunking.overlap_seconds,
        short_audio_seconds=0,
        max_upload_mb=config.pipeline.asr_chunking.max_upload_mb,
        silence_noise_db=config.pipeline.asr_chunking.silence.noise_db,
        silence_min_seconds=config.pipeline.asr_chunking.silence.min_silence_seconds,
        silence_cut_padding_seconds=config.pipeline.asr_chunking.silence.cut_padding_seconds,
        duration_seconds=duration,
        source_start_seconds=source_start_seconds,
    )
    if not source_audio_path_raw:
        parent_start = float(item.get("start", 0.0))
        for child in child_manifest:
            child["start"] = parent_start + float(child.get("start", 0.0))
            child["trusted_start"] = parent_start + float(child.get("trusted_start", 0.0))
            child["trusted_end"] = parent_start + float(child.get("trusted_end", 0.0))
            child["source_audio_path"] = str(source_audio_path)
    retry_artifact_paths = dict(paths)
    retry_artifact_paths["source"] = paths["source"] / "asr" / "retry" / f"segment_{idx:05d}"
    rows: list[dict] = []
    raw_children: list[dict] = []
    preprocess_children: list[dict] = []
    child_previous_text = ""
    for child_idx, child in enumerate(child_manifest):
        child_item = dict(child)
        child_item["segment_index"] = child_idx
        child_asr = _build_asr_engine(config, task=task, root_dir=root_dir)
        child_result = _process_asr_manifest_item(
            item=child_item,
            asr=child_asr,
            paths=retry_artifact_paths,
            config=config,
            task=task,
            root_dir=root_dir,
            allow_split_retry=False,
            previous_text=child_previous_text,
        )
        child_rows_path = _asr_artifact_paths(retry_artifact_paths, int(child_item["segment_index"]))["rows"]
        if child_rows_path.exists():
            child_rows = read_json(child_rows_path)
            rows.extend(child_rows)
            if _asr_uses_previous_text(config):
                text = _asr_previous_text(child_rows)
                if text:
                    child_previous_text = text
        if child_result.get("raw_response") is not None:
            raw_children.append(child_result["raw_response"])
        if child_result.get("preprocess_meta") is not None:
            preprocess_children.append(child_result["preprocess_meta"])
    rows.sort(key=lambda row: (float(row.get("start", 0.0)), float(row.get("end", 0.0)), str(row.get("text", ""))))
    parent_preprocess = {
        "enabled": True,
        "reason": "split_retry",
        "source_path": str(item.get("path", "")),
        "duration_seconds": duration,
        "initial_error": str(failure),
        "children": child_manifest,
        "child_artifact_dir": str(retry_artifact_paths["source"]),
        "child_preprocess": preprocess_children,
    }
    _write_asr_segment_artifacts(
        artifact_paths=artifact_paths,
        rows=rows,
        raw_response={"split_retry": True, "children": raw_children},
        preprocess_meta=parent_preprocess,
    )
    return {
        "idx": idx,
        "rows": rows,
        "raw_response": {"split_retry": True, "children": raw_children},
        "preprocess_meta": parent_preprocess,
        "skipped": False,
        "split_retry": True,
    }


def _complete_asr_segment(
    *,
    idx: int,
    asr_done: set[int],
    checkpoint: dict,
    store: TaskStore,
    task_id: str,
    total_segments: int,
    skipped: bool = False,
) -> None:
    asr_done.add(idx)
    checkpoint["asr_done_segments"] = sorted(asr_done)
    checkpoint["status"] = "ASR"
    store.save_checkpoint(task_id, checkpoint)
    verb = "Skipped silent" if skipped else "Transcribed"
    store.append_event(
        task_id,
        "progress",
        stage="ASR",
        message=f"{verb} segment {len(asr_done)}/{total_segments}",
        progress=0.25 + 0.25 * (len(asr_done) / max(total_segments, 1)),
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
    previous_text = _previous_asr_text_from_completed(items, paths) if _asr_uses_previous_text(config) else ""
    for item in items:
        _check_cancel(store, task_id)
        result = _process_asr_manifest_item(
            item=item,
            asr=asr,
            paths=paths,
            config=config,
            task=task,
            root_dir=root_dir,
            previous_text=previous_text,
        )
        preprocess_meta = result.get("preprocess_meta")
        if isinstance(preprocess_meta, dict) and preprocess_meta.get("fallback_used"):
            store.append_event(
                task_id,
                "warning",
                stage="ASR",
                level="warning",
                message="Retried cloud ASR without silence trim",
                details={"segment_index": result["idx"], "reason": preprocess_meta.get("fallback_reason", "")},
            )
        _complete_asr_segment(
            idx=int(result["idx"]),
            asr_done=asr_done,
            checkpoint=checkpoint,
            store=store,
            task_id=task_id,
            total_segments=total_segments,
            skipped=bool(result.get("skipped")),
        )
        if _asr_uses_previous_text(config) and not result.get("skipped"):
            text = _asr_previous_text(list(result.get("rows") or []))
            if text:
                previous_text = text


def _asr_item_upload_mb(item: dict) -> float:
    try:
        raw_path = item.get("path")
        path = Path(str(raw_path)) if raw_path else None
        if path is not None and path.is_file():
            return path.stat().st_size / (1024 * 1024)
    except OSError:
        pass
    duration = max(float(item.get("duration", 0.0)), 0.1)
    return duration * 16000 * 2 / (1024 * 1024)


def _take_asr_upload_batch(items: list[dict], *, max_items: int, max_upload_mb: float) -> tuple[list[dict], list[dict]]:
    if not items:
        return [], []
    max_items = max(1, int(max_items))
    max_upload_mb = max(float(max_upload_mb), 0.1)
    batch: list[dict] = []
    total_mb = 0.0
    remaining = list(items)
    while remaining and len(batch) < max_items:
        candidate = remaining[0]
        candidate_mb = _asr_item_upload_mb(candidate)
        if batch and total_mb + candidate_mb > max_upload_mb:
            break
        batch.append(candidate)
        total_mb += candidate_mb
        remaining.pop(0)
    return batch, remaining


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
    max_workers = max(1, int(config.pipeline.asr_execution.cloud_concurrency))
    max_workers = min(max_workers, max(1, int(config.pipeline.asr_execution.max_cloud_concurrency)))
    current_limit = max_workers
    pending = list(items)
    while pending:
        _check_cancel(store, task_id)
        batch, pending = _take_asr_upload_batch(
            pending,
            max_items=current_limit,
            max_upload_mb=config.pipeline.asr_execution.max_inflight_upload_mb,
        )
        retryable_failure = False
        successes = 0
        with ThreadPoolExecutor(max_workers=current_limit) as executor:
            def submit_item(manifest_item: dict):
                worker_asr = _build_asr_engine(config, task=task, root_dir=root_dir)
                return _process_asr_manifest_item(
                    item=manifest_item,
                    asr=worker_asr,
                    paths=paths,
                    config=config,
                    task=task,
                    root_dir=root_dir,
                )

            futures = {
                executor.submit(submit_item, item): item
                for item in batch
            }
            for future in as_completed(futures):
                _check_cancel(store, task_id)
                item = futures[future]
                try:
                    result = future.result()
                except Exception as exc:
                    if (
                        config.pipeline.asr_execution.adaptive_concurrency
                        and _is_retryable_asr_exception(exc)
                        and current_limit > int(config.pipeline.asr_execution.min_cloud_concurrency)
                    ):
                        retryable_failure = True
                        pending = [item] + pending
                        continue
                    raise
                preprocess_meta = result.get("preprocess_meta")
                if isinstance(preprocess_meta, dict) and preprocess_meta.get("fallback_used"):
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="Retried cloud ASR without silence trim",
                        details={"segment_index": result["idx"], "reason": preprocess_meta.get("fallback_reason", "")},
                    )
                if result.get("split_retry"):
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="Retried cloud ASR segment as smaller subsegments",
                        details={"segment_index": result["idx"]},
                    )
                _complete_asr_segment(
                    idx=int(result["idx"]),
                    asr_done=asr_done,
                    checkpoint=checkpoint,
                    store=store,
                    task_id=task_id,
                    total_segments=total_segments,
                    skipped=bool(result.get("skipped")),
                )
                successes += 1
        if config.pipeline.asr_execution.adaptive_concurrency:
            if retryable_failure:
                current_limit = max(int(config.pipeline.asr_execution.min_cloud_concurrency), max(1, current_limit // 2))
            elif successes >= current_limit:
                current_limit = min(max_workers, current_limit + 1)


def _asr_prompt_text(config: AppConfig) -> str:
    return _asr_segment_prompt(config)


def _task_paths(store: TaskStore, task_id: str) -> dict[str, Path]:
    base = store.task_dir(task_id)
    return {
        "base": base,
        "media": base / "media",
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
        "translate_memory_entries",
        "transport",
        "http_version",
        "streaming",
        "first_byte_at",
        "last_chunk_at",
        "bytes_received",
        "adaptive_parent_chunk",
        "adaptive_child_chunks",
    ]
    detail = {key: checkpoint[key] for key in keys if key in checkpoint}
    if "translate_done_chunks" in checkpoint:
        detail["translate_done_chunks"] = checkpoint.get("translate_done_chunks") or []
    return detail


def _checkpoint_status_payload(store: TaskStore, task_id: str) -> dict[str, Any]:
    try:
        checkpoint = store.load_checkpoint(task_id)
    except Exception:
        return {}
    payload: dict[str, Any] = {
        "checkpoint_status": checkpoint.get("status"),
        "checkpoint_updated_at": checkpoint.get("updated_at"),
    }
    progress_detail = _progress_detail_from_checkpoint(checkpoint)
    if progress_detail:
        payload["progress_detail"] = progress_detail
    return payload


def _translation_progress_callback(store: TaskStore, task_id: str, checkpoint: dict[str, Any]):
    lock = threading.Lock()

    def handle(event: dict[str, Any]) -> None:
        with lock:
            mode = str(event.get("mode") or "translate")
            now = utc_now_iso()
            checkpoint["status"] = "TRANSLATE"
            checkpoint["translate_current_mode"] = mode
            checkpoint["translate_current_attempt"] = int(event.get("attempt") or 1)
            checkpoint["translate_current_max_attempts"] = int(event.get("max_attempts") or 1)
            checkpoint["translate_attempt_started_at"] = now
            if event.get("provider") is not None:
                checkpoint["translate_current_provider"] = str(event.get("provider"))
            if event.get("model") is not None:
                checkpoint["translate_current_model"] = str(event.get("model"))
            if event.get("chunk_id") is not None:
                checkpoint["translate_current_chunk"] = str(event.get("chunk_id"))
                checkpoint.pop("translate_current_chunk_ids", None)
            if event.get("chunk_ids") is not None:
                checkpoint["translate_current_chunk_ids"] = [str(item) for item in event.get("chunk_ids") or []]
                checkpoint.pop("translate_current_chunk", None)
            if event.get("segment_id") is not None:
                checkpoint["translate_current_segment_id"] = int(event.get("segment_id"))
            else:
                checkpoint.pop("translate_current_segment_id", None)
            if event.get("memory_entries") is not None:
                checkpoint["translate_memory_entries"] = int(event.get("memory_entries") or 0)
            provider_meta = event.get("provider_meta") if isinstance(event.get("provider_meta"), dict) else {}
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
            if mode == "memory_patch":
                label = "Memory patch request"
            elif mode == "adaptive_split":
                label = "Adaptive translation split"
            else:
                label = f"Translation {mode} request"
            store.append_event(
                task_id,
                "provider_attempt",
                stage="TRANSLATE",
                message=label,
                details={
                    key: value
                    for key, value in {
                        "mode": mode,
                        "chunk_id": event.get("chunk_id"),
                        "chunk_ids": event.get("chunk_ids"),
                        "segment_id": event.get("segment_id"),
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


def _check_cancel(store: TaskStore, task_id: str) -> None:
    if store.is_cancel_requested(task_id):
        raise TaskCancelled("Task cancelled")


def _ensure_artifact_dirs(paths: dict[str, Path]) -> None:
    for p in paths.values():
        p.mkdir(parents=True, exist_ok=True)


def _require_file(path: Path, label: str) -> None:
    if not path.exists() or path.stat().st_size == 0:
        raise RuntimeError(f"Missing or empty artifact: {label}")


def _is_nonempty_file(path: Path) -> bool:
    return path.exists() and path.is_file() and path.stat().st_size > 0


def _is_valid_json_list(path: Path) -> bool:
    if not _is_nonempty_file(path):
        return False
    try:
        return isinstance(read_json(path), list)
    except Exception:
        return False


def _ingest_artifacts_valid(audio_full: Path, manifest_file: Path) -> bool:
    if not _is_nonempty_file(audio_full) or not _is_valid_json_list(manifest_file):
        return False
    try:
        manifest = read_json(manifest_file)
    except Exception:
        return False
    for item in manifest:
        if not isinstance(item, dict) or not _is_nonempty_file(Path(str(item.get("path", "")))):
            return False
    return True


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
            if shutil.which(binary) is None:
                raise RuntimeError(f"Required executable not found in PATH: {binary}")
    output_dir = output_file.parent if output_file else store.task_dir(task.task_id) / "output"
    output_dir.mkdir(parents=True, exist_ok=True)
    probe_file = output_dir / ".tvx_write_probe"
    try:
        probe_file.write_text("ok", encoding="utf-8")
    finally:
        probe_file.unlink(missing_ok=True)
    needs_asr = _video_needs_asr(config, task)
    if needs_asr and config.pipeline.asr_mode == "local" and importlib.util.find_spec("faster_whisper") is None:
        raise RuntimeError("faster-whisper is required for ASR. Install with: pip install -e .[asr]")
    if needs_asr and config.pipeline.asr_mode == "cloud":
        asr_provider = config.asr_providers.get(config.pipeline.asr_provider)
        if asr_provider is None:
            raise RuntimeError(f"ASR provider not found: {config.pipeline.asr_provider}")
        if asr_provider.protocol != "openai_transcriptions":
            raise RuntimeError(f"unsupported_asr_protocol: {asr_provider.protocol}")
        credential = resolve_credential(
            env_key=asr_provider.env_key,
            credential_id=asr_provider.credential_id,
            root_dir=root_dir,
        )
        if not credential.found:
            raise RuntimeError(f"Missing credential: {credential.credential_id or credential.env_key}")
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
    input_type: str = "video_asr_translate",
    status: str = "QUEUED",
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> tuple[str, Path]:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    normalized_input_type = input_type if input_type in {"video_asr_translate", "srt_translate", "segments_translate", "video_asr"} else "video_asr_translate"
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = _create_task(
        store,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        settings=_task_settings(config, input_type=normalized_input_type),
    )
    if status != "INIT":
        store.update_task_status(task.task_id, status)
    store.clear_cancel(task.task_id)
    store.append_event(task.task_id, "task_created", stage=status, message="Task created", progress=_stage_progress(status))
    return task.task_id, config.pipeline.artifacts_dir


def _task_settings(config: AppConfig, *, input_type: str) -> dict[str, Any]:
    settings = to_plain(config.pipeline)
    settings["input_type"] = input_type
    settings["source_mode"] = config.pipeline.source_mode
    settings["subtitle_track"] = config.pipeline.subtitle_track
    settings["routing"] = to_plain(config.routing)
    settings.setdefault("edited", False)
    return settings


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


def _legacy_asr_segments_path(paths: dict[str, Path]) -> Path:
    return paths["asr"] / "segments.raw.jsonl"


def persist_source_segments(paths: dict[str, Path], segments: list[Segment]) -> Path:
    path = _source_segments_path(paths)
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


def _translation_route_providers(config: AppConfig) -> list:
    out = []
    for route in [config.routing.primary] + list(config.routing.fallback):
        provider = config.providers.get(route.provider)
        if provider is not None:
            out.append(provider)
    return out


def _primary_translation_provider(config: AppConfig):
    return config.providers.get(config.routing.primary.provider)


def _effective_translation_chunk_lines(config: AppConfig) -> int:
    configured = max(1, config.pipeline.translation.chunk_lines)
    provider_limits = [
        max(1, provider.capabilities.max_batch_lines)
        for provider in _translation_route_providers(config)
    ]
    if not provider_limits:
        return configured
    return min(configured, min(provider_limits))


def _effective_initial_chunk_lines(config: AppConfig, segment_count: int) -> tuple[int, list[dict[str, Any]]]:
    configured = max(1, config.pipeline.translation.chunk_lines)
    effective = _effective_translation_chunk_lines(config)
    warnings: list[dict[str, Any]] = []
    if effective < configured:
        warnings.append(
            {
                "message": "Reduced translation chunk size to provider capability limit",
                "details": {
                    "configured_chunk_lines": configured,
                    "effective_chunk_lines": effective,
                },
            }
        )
    if not memory_enabled(config.pipeline.memory):
        return effective, warnings
    memory_min = max(1, int(config.pipeline.memory.chunking.min_initial_chunk_lines))
    memory_max_chunks = max(1, int(config.pipeline.memory.chunking.max_initial_chunks))
    chunk_lines_for_max_chunks = max(1, (max(0, segment_count) + memory_max_chunks - 1) // memory_max_chunks)
    memory_floor = max(memory_min, chunk_lines_for_max_chunks)
    provider_cap = min(
        [max(1, provider.capabilities.max_batch_lines) for provider in _translation_route_providers(config)] or [memory_floor]
    )
    guarded = min(max(effective, memory_floor), provider_cap)
    if guarded > effective:
        warnings.append(
            {
                "message": "Raised initial translation chunk size for memory stability",
                "details": {
                    "configured_chunk_lines": configured,
                    "previous_effective_chunk_lines": effective,
                    "effective_chunk_lines": guarded,
                    "min_initial_chunk_lines": memory_min,
                    "max_initial_chunks": memory_max_chunks,
                    "segment_count": segment_count,
                },
            }
        )
        effective = guarded
    elif memory_floor > effective:
        warnings.append(
            {
                "message": "Memory chunking guard limited by provider capability",
                "details": {
                    "configured_chunk_lines": configured,
                    "effective_chunk_lines": effective,
                    "memory_requested_chunk_lines": memory_floor,
                    "provider_max_batch_lines": provider_cap,
                    "segment_count": segment_count,
                },
            }
        )
    return effective, warnings


def _verified_translated_chunks(translated_rows: list[dict], validation_rows: list[dict]) -> set[str]:
    translated_ids = {str(row.get("chunk_id")) for row in translated_rows if row.get("chunk_id")}
    valid_ids: set[str] = set()
    for row in validation_rows:
        chunk_id = row.get("chunk_id")
        if not chunk_id:
            continue
        issues = row.get("issues", [])
        if not any(issue.get("level") == "ERROR" for issue in issues if isinstance(issue, dict)):
            valid_ids.add(str(chunk_id))
    return translated_ids & valid_ids


def _chunk_output_lines(row: dict) -> list[str]:
    out: list[str] = []
    for item in row.get("rows", []):
        seg_id = item.get("id")
        if seg_id is None:
            continue
        out.append(f"[{seg_id}] {str(item.get('text_tgt', '')).strip()}")
    return out


def _backfill_translation_validation(
    *,
    config: AppConfig,
    chunks,
    translated_rows: list[dict],
    validation_rows: list[dict],
    validation_file: Path,
    store: TaskStore,
    task_id: str,
) -> tuple[list[dict], set[str]]:
    validated_ids = {str(row.get("chunk_id")) for row in validation_rows if row.get("chunk_id")}
    current_validation_rows = list(validation_rows)
    for row in translated_rows:
        chunk_id = str(row.get("chunk_id", ""))
        if not chunk_id or chunk_id in validated_ids:
            continue
        chunk = _adaptive_chunk_by_id(chunks, chunk_id)
        if chunk is None:
            continue
        validation = validate_translation_response(
            chunk=chunk,
            numbered_lines=_chunk_output_lines(row),
            raw_text="\n".join(_chunk_output_lines(row)),
            refusal_detection_enabled=config.pipeline.translation.refusal_detection.enabled,
        )
        validation_json = validation_to_json(validation)
        append_jsonl(validation_file, validation_json)
        current_validation_rows.append(validation_json)
        validated_ids.add(chunk_id)
        store.append_event(
            task_id,
            "progress",
            stage="TRANSLATE",
            message=f"Backfilled validation for translated chunk {chunk_id}",
        )
    return current_validation_rows, _verified_translated_chunks(translated_rows, current_validation_rows)


def _translation_done_count(chunks, translated_done: set[str]) -> int:
    return _source_chunk_completed_count(chunks, translated_done)


def _translation_progress_value(chunks, translated_done: set[str]) -> float:
    return 0.65 + 0.18 * (_translation_done_count(chunks, translated_done) / max(len(chunks), 1))


def _translation_row_for_artifact(row: dict) -> dict:
    return {
        key: value
        for key, value in row.items()
        if key not in {"validation", "repairs", "raw_text", "usage", "raw_text_chars", "request"}
    }


def _write_translation_experiment_artifacts(config: AppConfig, paths: dict[str, Path], row: dict[str, Any]) -> None:
    logging_config = config.pipeline.translation.experiment_logging
    if not logging_config.enabled:
        return
    chunk_id = str(row.get("chunk_id") or "unknown")
    raw_rel = ""
    if logging_config.save_raw_text and isinstance(row.get("raw_text"), str):
        raw_dir = paths["translate"] / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)
        raw_path = raw_dir / f"{chunk_id}.raw.txt"
        raw_path.write_text(row.get("raw_text") or "", encoding="utf-8")
        raw_rel = str(raw_path.relative_to(paths["base"]))
    if not logging_config.save_metrics:
        return
    provider_meta = row.get("provider_meta") if isinstance(row.get("provider_meta"), dict) else {}
    request_meta = row.get("request") if isinstance(row.get("request"), dict) else {}
    chunk_meta = request_meta.get("chunk_meta") if isinstance(request_meta.get("chunk_meta"), dict) else {}
    validation = row.get("validation") if isinstance(row.get("validation"), dict) else {}
    metrics = {
        "chunk_id": chunk_id,
        "experiment_label": logging_config.label,
        "provider": row.get("provider", ""),
        "model": row.get("model", ""),
        "compat_mode": row.get("compat_mode", ""),
        "line_count": request_meta.get("line_count", len(row.get("rows") or [])),
        "context_before_lines": request_meta.get("context_before_lines"),
        "context_after_lines": request_meta.get("context_after_lines"),
        "memory_entries": request_meta.get("memory_entries"),
        "memory_prompt_chars": request_meta.get("memory_prompt_chars"),
        "raw_text_chars": row.get("raw_text_chars", len(str(row.get("raw_text") or ""))),
        "raw_text_path": raw_rel,
        "usage": row.get("usage") if isinstance(row.get("usage"), dict) else {},
        "provider_meta": {
            key: provider_meta.get(key)
            for key in [
                "transport",
                "http_version",
                "streaming",
                "request_started_at",
                "first_byte_at",
                "last_chunk_at",
                "elapsed_ms",
                "bytes_received",
                "compat_mode",
                "base_url",
            ]
            if provider_meta.get(key) is not None
        },
        "chunk_meta": chunk_meta,
        "validation": {
            "issue_count": len(validation.get("issues") or []),
            "issues": validation.get("issues") or [],
        },
        "repairs": len(row.get("repairs") or []),
        "errors": row.get("errors") or [],
        "adaptive_parent_chunk": row.get("adaptive_parent_chunk", ""),
    }
    append_jsonl(paths["translate"] / "metrics.jsonl", metrics)


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


def _normalize_output_format(value: str) -> str:
    normalized = str(value or "srt").strip().lower()
    return normalized if normalized in {"srt", "ass", "both"} else "srt"


def _output_paths_for_task(
    *,
    config: AppConfig,
    task: TaskRecord,
    output_file: Path | None,
    output_dir: Path,
) -> tuple[str, dict[str, Path]]:
    output_format = _normalize_output_format(config.pipeline.output_format)
    stem = Path(task.input_file).stem
    if output_file is not None:
        base = output_file.with_suffix("")
        if output_format == "srt":
            return output_format, {"srt": output_file.with_suffix(".srt")}
        if output_format == "ass":
            return output_format, {"ass": output_file.with_suffix(".ass")}
        return output_format, {"srt": base.with_suffix(".srt"), "ass": base.with_suffix(".ass")}
    base = output_dir / f"{stem}.{task.target_lang}"
    if output_format == "srt":
        return output_format, {"srt": base.parent / f"{base.name}.srt"}
    if output_format == "ass":
        return output_format, {"ass": base.parent / f"{base.name}.ass"}
    return output_format, {"srt": base.parent / f"{base.name}.srt", "ass": base.parent / f"{base.name}.ass"}


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
        input_type=input_type,
        status="INIT",
        event_sink=event_sink,
    )
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
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
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = store.load_task(task_id)
    _apply_saved_pipeline_settings(config, task.settings)
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
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> Path:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    store.load_task(task_id)
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
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    store.load_task(task_id)
    _execute_task(
        config,
        store,
        task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task_id


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
    input_type = str(task.settings.get("input_type", "video_asr_translate"))
    paths = _task_paths(store, task_id)
    _ensure_artifact_dirs(paths)

    checkpoint = store.load_checkpoint(task_id)
    _clear_checkpoint_error(checkpoint)
    try:
        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "PRECHECK", "Running preflight checks")
        _preflight(config, store, task, output_file, root_dir=root_dir, providers_file=providers_file)
        checkpoint["status"] = "PRECHECK"
        store.save_checkpoint(task_id, checkpoint)

        if input_type == "segments_translate":
            _check_cancel(store, task_id)
            _emit_stage(store, task_id, "INGEST", "Loading source segments")
            source_jsonl = _source_segments_path(paths)
            if not checkpoint.get("ingest_done") or not _is_nonempty_file(source_jsonl):
                all_segments = _load_segments_from_input(Path(task.input_file))
                if not all_segments:
                    raise RuntimeError("No subtitle segments parsed from input")
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
            _emit_stage(store, task_id, "INGEST", "Parsing SRT subtitles")
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
            source_mode, subtitle_stream, subtitle_streams = _resolve_video_source_mode(config, task)
            if source_mode == "embedded_subtitle":
                _emit_stage(store, task_id, "INGEST", "Extracting embedded subtitles")
                source_jsonl = _source_segments_path(paths)
                embedded_srt = paths["media"] / "embedded_subtitle.srt"
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
                    extract_subtitle_stream(
                        Path(task.input_file),
                        embedded_srt,
                        stream_index=int(subtitle_stream["index"]),
                    )
                    all_segments = _segments_with_source(parse_srt_file(embedded_srt), "embedded_subtitle")
                    if not all_segments:
                        raise RuntimeError("No subtitle segments parsed from embedded subtitle stream")
                    source_jsonl = persist_source_segments(paths, all_segments)
                    write_json(
                        paths["media"] / "subtitle_streams.json",
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
                _emit_stage(store, task_id, "INGEST", "Extracting and splitting audio")
                audio_full = paths["media"] / "audio_full.m4a"
                manifest_file = paths["media"] / "segments_manifest.json"
                if not checkpoint.get("ingest_done") or not _ingest_artifacts_valid(audio_full, manifest_file):
                    media_meta = extract_audio_for_asr(
                        Path(task.input_file),
                        audio_full,
                        source_lang=task.source_lang,
                        audio_track=config.pipeline.asr_audio_track,
                    )
                    segments_manifest = split_audio_for_asr(
                        audio_full,
                        paths["media"] / "segments",
                        mode=config.pipeline.asr_chunking.mode,
                        window_seconds=config.pipeline.asr_chunking.window_seconds,
                        max_window_seconds=config.pipeline.asr_chunking.max_window_seconds,
                        min_window_seconds=config.pipeline.asr_chunking.min_window_seconds,
                        overlap_seconds=config.pipeline.asr_chunking.overlap_seconds,
                        short_audio_seconds=config.pipeline.asr_chunking.short_audio_seconds,
                        max_upload_mb=config.pipeline.asr_chunking.max_upload_mb,
                        silence_noise_db=config.pipeline.asr_chunking.silence.noise_db,
                        silence_min_seconds=config.pipeline.asr_chunking.silence.min_silence_seconds,
                        silence_cut_padding_seconds=config.pipeline.asr_chunking.silence.cut_padding_seconds,
                        duration_seconds=float(media_meta["duration_seconds"]),
                    )
                    write_json(paths["media"] / "media_meta.json", media_meta)
                    write_json(manifest_file, segments_manifest)
                    _require_file(audio_full, "media/audio_full.m4a")
                    checkpoint["ingest_done"] = True
                    checkpoint["status"] = "INGEST"
                    store.save_checkpoint(task_id, checkpoint)
                    store.append_event(
                        task_id,
                        "artifact",
                        stage="INGEST",
                        message="Audio segments ready",
                        progress=0.18,
                        details={"path": str(manifest_file), "segments": len(segments_manifest)},
                    )
                else:
                    segments_manifest = read_json(manifest_file)

                _check_cancel(store, task_id)
                _emit_stage(store, task_id, "ASR", "Transcribing audio segments")
                asr = _build_asr_engine(config, task=task, root_dir=root_dir)
                asr_done = set(checkpoint.get("asr_done_segments", []))
                segment_files = []
                pending_asr_items = []
                for item in segments_manifest:
                    idx = int(item["segment_index"])
                    artifact_paths = _asr_artifact_paths(paths, idx)
                    segment_files.append((idx, artifact_paths["rows"]))
                    if idx in asr_done and _is_valid_json_list(artifact_paths["rows"]):
                        continue
                    pending_asr_items.append(item)
                if config.pipeline.asr_mode == "cloud" and not _asr_uses_previous_text(config):
                    _run_asr_segments_concurrent(
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
                    _run_asr_segments_serial(
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

                all_segments = []
                next_id = 1
                window_segments = []
                for _idx, seg_file in sorted(segment_files, key=lambda x: x[0]):
                    _require_file(seg_file, f"source/asr/rows/{seg_file.name}")
                    rows = read_json(seg_file)
                    parsed = _parse_asr_rows(rows, start_id=next_id)
                    manifest_item = next(
                        (item for item in segments_manifest if int(item["segment_index"]) == _idx),
                        {"segment_index": _idx},
                    )
                    window_segments.append((manifest_item, parsed))
                    all_segments.extend(parsed)
                    next_id = all_segments[-1].id + 1 if all_segments else next_id
                deduped_segments = merge_asr_window_segments(
                    window_segments,
                    fuzzy_dedupe=config.pipeline.asr_chunking.fuzzy_dedupe,
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
                store.append_event(
                    task_id,
                    "artifact",
                    stage="ASR",
                    message="Normalized source segments ready",
                    progress=0.52,
                    details={"path": str(source_jsonl), "segments": len(all_segments)},
                )

                if input_type == "video_asr":
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

        if memory_enabled(config.pipeline.memory):
            _check_cancel(store, task_id)
            _emit_stage(store, task_id, "MEMORY", "Preparing translation memory")
            memory_store = MemoryStore(paths["memory"])
            memory_store.ensure_runtime_document()
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
                    progress_callback=_translation_progress_callback(store, task_id, checkpoint),
                )
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
        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "SEGMENT", "Preparing translation chunks")
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
        checkpoint["translate_total_chunks"] = len(chunks)
        checkpoint["translate_done_count"] = _translation_done_count(
            chunks,
            {str(item) for item in checkpoint.get("translate_done_chunks", [])},
        )
        store.save_checkpoint(task_id, checkpoint)

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "TRANSLATE", "Translating chunks")
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
        translation_progress = _translation_progress_callback(store, task_id, checkpoint)
        for row in _iter_translation_results(
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

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "ALIGN", "Aligning and validating subtitles")
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
        _emit_stage(store, task_id, "QUALITY", "Optimizing subtitle readability")
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

        _check_cancel(store, task_id)
        output_format, output_paths = _output_paths_for_task(
            config=config,
            task=task,
            output_file=output_file,
            output_dir=paths["output"],
        )
        _emit_stage(store, task_id, "EXPORT", f"Exporting {output_format.upper()} subtitles")
        if "srt" in output_paths:
            export_srt(final_segments, output_paths["srt"], task.bilingual)
        if "ass" in output_paths:
            export_ass(
                final_segments,
                output_paths["ass"],
                bilingual=task.bilingual,
                style=config.pipeline.subtitle_ass_style,
            )
        output_paths_payload = {key: str(path) for key, path in output_paths.items()}
        primary_output = output_paths.get("srt") or output_paths.get("ass")
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
    except TaskCancelled as exc:
        err = classify_exception(exc, stage=str(checkpoint.get("status", task.status)))
        store.update_task_status(task_id, "CANCELLED", error=str(exc), error_info=err)
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


def task_status_json(task: TaskRecord, store: TaskStore | None = None) -> dict[str, Any]:
    return _status_json(task, store=store)
