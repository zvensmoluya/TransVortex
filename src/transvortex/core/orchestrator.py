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
    provider = _active_asr_provider(config)
    return AsrEngine(
        source_lang=task.source_lang,
        prompt=_asr_prompt_text(config),
        asr_provider=provider,
        root_dir=root_dir,
    )


def _active_asr_provider(config: AppConfig):
    provider = config.asr_providers.get(config.pipeline.asr_provider)
    if provider is None:
        raise RuntimeError(f"ASR provider not found: {config.pipeline.asr_provider}")
    return provider


def _asr_uses_word_timeline(config: AppConfig) -> bool:
    provider = _active_asr_provider(config)
    if provider.protocol != "openrouter_stt":
        return False
    profile = openrouter_asr_model_profile(provider.model)
    return profile is not None and profile.timeline_mode == "words_required"


def _is_retryable_asr_exception(exc: Exception) -> bool:
    if getattr(exc, "status_code", None) == 413:
        return True
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


def _should_retry_asr_without_preprocess(rows: list[dict]) -> bool:
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
        "upload": paths["cache"] / "asr" / "upload" / f"segment_{idx:05d}.wav",
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
    else:
        artifact_paths["raw"].unlink(missing_ok=True)
    filtered_rows, quality = filter_asr_rows_for_source(rows)
    write_json(artifact_paths["quality"], quality)
    write_segment_asr_output(artifact_paths["rows"], filtered_rows)


def _asr_raw_response_with_transport(raw_response: dict | None, transport_meta: dict[str, Any]) -> dict | None:
    if raw_response is None:
        return None
    if not transport_meta:
        return raw_response
    return {**raw_response, "_transport_meta": transport_meta}


def _asr_raw_response_with_related(
    raw_response: dict | None,
    related_responses: list[dict],
) -> dict | None:
    related = [item for item in related_responses if isinstance(item, dict)]
    if not related:
        return raw_response
    payload = dict(raw_response or {})
    payload["_related_responses"] = related
    return payload


def _sync_checkpoint_openrouter_asr_usage(
    checkpoint: dict[str, Any],
    *,
    paths: dict[str, Path],
    provider: Any,
) -> tuple[Path | None, dict[str, Any] | None]:
    usage_path, usage = _write_openrouter_asr_usage_artifact(paths, provider)
    if usage is not None:
        checkpoint["asr_usage"] = usage
    else:
        checkpoint.pop("asr_usage", None)
    return usage_path, usage


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
    if not (prompt.enabled and prompt.include_previous_text):
        return False
    capabilities = config.asr_capabilities.get(config.pipeline.asr_provider)
    return capabilities is None or capabilities.hints.prompt


def _asr_allows_split_retry(config: AppConfig) -> bool:
    resolution = config.asr_policy_resolutions.get(config.pipeline.asr_provider)
    return resolution is None or resolution.policy.execution.split_retry


def _asr_duration_hard_limit(config: AppConfig) -> float | None:
    capabilities = config.asr_capabilities.get(config.pipeline.asr_provider)
    if capabilities is None:
        return None
    raw = capabilities.audio_input.max_duration_seconds.hard_max
    if raw is None:
        return None
    parsed = _finite_number(raw, error="asr_duration_capability_invalid")
    if parsed <= 0:
        raise RuntimeError("asr_duration_capability_invalid")
    return parsed


def _asr_upload_hard_limit(config: AppConfig) -> int | None:
    capabilities = config.asr_capabilities.get(config.pipeline.asr_provider)
    if capabilities is None:
        return None
    raw = capabilities.audio_input.max_upload_bytes.hard_max
    if raw is None:
        return None
    parsed = _finite_number(raw, error="asr_upload_capability_invalid")
    if parsed <= 0 or not parsed.is_integer():
        raise RuntimeError("asr_upload_capability_invalid")
    return int(parsed)


def _asr_runs_concurrently(config: AppConfig) -> bool:
    provider = _active_asr_provider(config)
    return (
        provider.kind != "local_worker"
        and provider.execution.concurrency > 1
        and not _asr_uses_previous_text(config)
    )


def _asr_retry_artifact_paths(paths: dict[str, Path], item: dict[str, Any]) -> dict[str, Path]:
    task_dir = _task_dir_from_paths(paths)
    segment_index = _strict_nonnegative_int(
        item.get("segment_index"),
        error="asr_plan_segment_index_invalid",
    )
    segment_id = _validated_asr_segment_id(
        item.get("segment_id") or f"segment-{segment_index:05d}"
    )
    asr_dir = paths.get("asr", task_dir / "asr")
    return {
        "decision": asr_dir / "retry_decisions" / f"{segment_id}.json",
        "plan": asr_dir / "retry_plans" / f"{segment_id}.json",
        "windows": asr_dir / "segments_retry" / segment_id,
        "manifest": asr_dir / "segments_retry" / segment_id / "manifest.json",
        "result_source": task_dir / "source" / "retry" / segment_id,
    }


def _asr_retry_parent(item: dict[str, Any]) -> AsrRetryParent:
    segment_index = _strict_nonnegative_int(
        item.get("segment_index"),
        error="asr_plan_segment_index_invalid",
    )
    segment_id = _validated_asr_segment_id(
        item.get("segment_id") or f"segment-{segment_index:05d}"
    )
    source_start = _finite_number(item.get("start"), error="asr_plan_window_time_invalid")
    duration = _finite_number(item.get("duration"), error="asr_plan_window_time_invalid")
    source_end = source_start + duration
    trusted_start = _finite_number(
        item.get("trusted_start"),
        error="asr_plan_window_time_invalid",
    )
    trusted_end = _finite_number(
        item.get("trusted_end"),
        error="asr_plan_window_time_invalid",
    )
    audio_path = Path(str(item.get("path") or ""))
    if not _is_nonempty_file(audio_path):
        raise RuntimeError("asr_retry_parent_artifact_missing")
    content_sha256 = str(item.get("content_sha256") or "").strip().lower()
    actual_sha256 = _sha256_file(audio_path)
    if content_sha256 and content_sha256 != actual_sha256:
        raise RuntimeError("asr_retry_parent_content_mismatch")
    if (
        duration <= 0
        or trusted_start < source_start - _ASR_PLAN_TIME_TOLERANCE
        or trusted_end > source_end + _ASR_PLAN_TIME_TOLERANCE
        or trusted_end <= trusted_start
    ):
        raise RuntimeError("asr_plan_window_time_invalid")
    return AsrRetryParent(
        segment_id=segment_id,
        segment_index=segment_index,
        content_sha256=actual_sha256,
        source_start=source_start,
        source_end=source_end,
        trusted_start=trusted_start,
        trusted_end=trusted_end,
    )


def _asr_retry_base_plan_id(task: TaskRecord | Any) -> str:
    settings = getattr(task, "settings", None)
    if not isinstance(settings, dict):
        return ""
    plan = settings.get("asr_plan")
    return str(plan.get("plan_id") or "") if isinstance(plan, dict) else ""


def _asr_retry_decision_identity(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "base_plan_id": payload.get("base_plan_id"),
        "parent": payload.get("parent"),
        "strategy": payload.get("strategy"),
    }


def _asr_retry_plan_identity(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "decision_id": payload.get("decision_id"),
        "windows": payload.get("windows"),
    }


def _prefixed_plan_id(prefix: str, identity: dict[str, Any]) -> str:
    return prefix + _asr_plan_id(identity).removeprefix("asr-")


def _build_asr_retry_decision(
    *,
    item: dict[str, Any],
    config: AppConfig,
    task: TaskRecord | Any,
) -> dict[str, Any]:
    parent = _asr_retry_parent(item)
    duration = parent.source_end - parent.source_start
    chunking = _active_asr_provider(config).chunking
    max_child_window = max(
        float(chunking.min_window_seconds),
        min(float(chunking.max_window_seconds), duration / 2.0),
    )
    window_seconds = max(0.1, float(max_child_window))
    strategy = AsrSplitRetryStrategy(
        strategy_id="fixed_window_subdivision",
        strategy_version=1,
        mode="fixed",
        window_seconds=window_seconds,
        minimum_window_seconds=max(0.1, float(chunking.min_window_seconds)),
        overlap_seconds=max(
            0.0,
            min(float(chunking.overlap_seconds), window_seconds - 0.001),
        ),
        max_upload_mb=(
            float(chunking.max_upload_mb)
            if chunking.max_upload_mb is not None
            else None
        ),
    )
    identity = {
        "base_plan_id": _asr_retry_base_plan_id(task),
        "parent": to_plain(parent),
        "strategy": to_plain(strategy),
    }
    decision = AsrRetryDecision(
        decision_id=_prefixed_plan_id("asr-retry-decision-", identity),
        created_at=utc_now_iso(),
        base_plan_id=str(identity["base_plan_id"]),
        parent=parent,
        strategy=strategy,
    )
    return to_plain(decision)


def _validate_asr_retry_decision(
    payload: Any,
    *,
    item: dict[str, Any],
    task: TaskRecord | Any,
) -> dict[str, Any]:
    if (
        not isinstance(payload, dict)
        or _strict_nonnegative_int(
            payload.get("retry_schema_version"),
            error="unsupported_asr_retry_schema",
        )
        != ASR_RETRY_SCHEMA_VERSION
    ):
        raise RuntimeError("unsupported_asr_retry_schema")
    identity = _asr_retry_decision_identity(payload)
    expected_id = _prefixed_plan_id("asr-retry-decision-", identity)
    if str(payload.get("decision_id") or "") != expected_id:
        raise RuntimeError("asr_retry_decision_integrity_mismatch")
    if str(payload.get("base_plan_id") or "") != _asr_retry_base_plan_id(task):
        raise RuntimeError("asr_retry_base_plan_mismatch")
    if _stable_plan_identity(payload.get("parent")) != _stable_plan_identity(
        to_plain(_asr_retry_parent(item))
    ):
        raise RuntimeError("asr_retry_parent_mismatch")
    strategy = payload.get("strategy") if isinstance(payload.get("strategy"), dict) else {}
    if (
        str(strategy.get("strategy_id") or "") != "fixed_window_subdivision"
        or _strict_nonnegative_int(
            strategy.get("strategy_version"),
            error="asr_retry_strategy_invalid",
        )
        != 1
        or str(strategy.get("mode") or "") != "fixed"
        or _finite_number(
            strategy.get("window_seconds"),
            error="asr_retry_strategy_invalid",
        )
        <= 0
        or _finite_number(
            strategy.get("minimum_window_seconds"),
            error="asr_retry_strategy_invalid",
        )
        <= 0
        or float(strategy.get("minimum_window_seconds") or 0)
        > float(strategy.get("window_seconds") or 0)
        or _finite_number(
            strategy.get("overlap_seconds"),
            error="asr_retry_strategy_invalid",
        )
        < 0
        or float(strategy.get("overlap_seconds") or 0)
        >= float(strategy.get("window_seconds") or 0)
        or (
            strategy.get("max_upload_mb") is not None
            and _finite_number(
                strategy.get("max_upload_mb"),
                error="asr_retry_strategy_invalid",
            )
            <= 0
        )
    ):
        raise RuntimeError("asr_retry_strategy_invalid")
    return payload


def _load_or_create_asr_retry_decision(
    *,
    item: dict[str, Any],
    paths: dict[str, Path],
    config: AppConfig,
    task: TaskRecord | Any,
    create: bool,
) -> dict[str, Any]:
    retry_paths = _asr_retry_artifact_paths(paths, item)
    if retry_paths["decision"].is_file():
        return _validate_asr_retry_decision(
            read_json(retry_paths["decision"]),
            item=item,
            task=task,
        )
    if not create:
        raise RuntimeError("asr_retry_decision_missing")
    payload = _build_asr_retry_decision(item=item, config=config, task=task)
    write_json(retry_paths["decision"], payload)
    return _validate_asr_retry_decision(payload, item=item, task=task)


def _validate_asr_retry_windows(
    windows: list[dict[str, Any]],
    *,
    parent: dict[str, Any],
) -> None:
    if len(windows) < 2:
        raise RuntimeError("asr_retry_plan_not_subdivided")
    parent_start = float(parent["source_start"])
    parent_end = float(parent["source_end"])
    parent_duration = parent_end - parent_start
    _validate_asr_window_sequence(
        windows,
        audio_start=parent_start,
        audio_end=parent_end,
        error="asr_retry_plan_parent_range_mismatch",
    )
    for window in windows:
        source_start = float(window["start"])
        source_end = source_start + float(window["duration"])
        if (
            source_start < parent_start - _ASR_PLAN_TIME_TOLERANCE
            or source_end > parent_end + _ASR_PLAN_TIME_TOLERANCE
            or source_end - source_start >= parent_duration - _ASR_PLAN_TIME_TOLERANCE
        ):
            raise RuntimeError("asr_retry_plan_parent_range_mismatch")


def _load_asr_retry_plan(
    *,
    item: dict[str, Any],
    paths: dict[str, Path],
    config: AppConfig,
    decision: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    retry_paths = _asr_retry_artifact_paths(paths, item)
    payload = read_json(retry_paths["plan"])
    if (
        not isinstance(payload, dict)
        or _strict_nonnegative_int(
            payload.get("retry_schema_version"),
            error="unsupported_asr_retry_schema",
        )
        != ASR_RETRY_SCHEMA_VERSION
    ):
        raise RuntimeError("unsupported_asr_retry_schema")
    identity = _asr_retry_plan_identity(payload)
    expected_id = _prefixed_plan_id("asr-retry-plan-", identity)
    if str(payload.get("retry_plan_id") or "") != expected_id:
        raise RuntimeError("asr_retry_plan_integrity_mismatch")
    if str(payload.get("decision_id") or "") != str(decision["decision_id"]):
        raise RuntimeError("asr_retry_decision_mismatch")
    planned_windows = payload.get("windows") if isinstance(payload.get("windows"), list) else []
    task_dir = _task_dir_from_paths(paths)
    runtime_windows = [
        _validated_plan_window(planned, ordinal=ordinal, task_dir=task_dir)
        for ordinal, planned in enumerate(planned_windows)
    ]
    portable_manifest = _portable_asr_manifest(planned_windows)
    try:
        persisted_manifest = read_json(retry_paths["manifest"])
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError("asr_retry_manifest_missing") from exc
    if persisted_manifest != portable_manifest:
        raise RuntimeError("asr_retry_manifest_mismatch")
    _validate_asr_retry_windows(runtime_windows, parent=dict(decision["parent"]))
    _validate_asr_plan_policy_limits(config, runtime_windows)
    return payload, runtime_windows


def _create_asr_retry_plan(
    *,
    item: dict[str, Any],
    paths: dict[str, Path],
    config: AppConfig,
    decision: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    retry_paths = _asr_retry_artifact_paths(paths, item)
    strategy = dict(decision["strategy"])
    parent = dict(decision["parent"])
    parent_start = float(parent["source_start"])
    parent_end = float(parent["source_end"])
    parent_duration = parent_end - parent_start
    child_manifest = split_audio_for_asr(
        Path(str(item["path"])),
        retry_paths["windows"],
        mode="fixed",
        window_seconds=float(strategy["window_seconds"]),
        max_window_seconds=float(strategy["window_seconds"]),
        min_window_seconds=float(strategy["minimum_window_seconds"]),
        overlap_seconds=float(strategy["overlap_seconds"]),
        short_audio_seconds=0.0,
        max_upload_mb=(
            float(strategy["max_upload_mb"])
            if strategy.get("max_upload_mb") is not None
            else None
        ),
        max_duration_seconds=_asr_duration_hard_limit(config),
        silence_noise_db=_active_asr_provider(config).chunking.silence.noise_db,
        silence_min_seconds=_active_asr_provider(config).chunking.silence.min_silence_seconds,
        silence_cut_padding_seconds=_active_asr_provider(config).chunking.silence.cut_padding_seconds,
        duration_seconds=parent_duration,
        source_start_seconds=0.0,
    )
    for child in child_manifest:
        child["start"] = parent_start + float(child.get("start", 0.0))
        child["trusted_start"] = parent_start + float(child.get("trusted_start", 0.0))
        child["trusted_end"] = parent_start + float(child.get("trusted_end", 0.0))
        child.pop("source_audio_path", None)
    task_dir = _task_dir_from_paths(paths)
    windows = tuple(
        _asr_plan_window_from_manifest(
            child,
            ordinal=ordinal,
            task_dir=task_dir,
            audio_end=parent_end,
            segment_id_prefix=f"{parent['segment_id']}.retry",
        )
        for ordinal, child in enumerate(child_manifest)
    )
    windows_payload = list(to_plain(windows))
    portable_manifest = _portable_asr_manifest(windows_payload)
    _validate_asr_retry_windows(
        [
            {
                **row,
                "artifact_path": row["path"],
                "path": str(_resolve_task_artifact_ref(row["path"], task_dir=task_dir)),
            }
            for row in portable_manifest
        ],
        parent=parent,
    )
    identity = {
        "decision_id": str(decision["decision_id"]),
        "windows": windows_payload,
    }
    resolved = ResolvedAsrRetryPlan(
        retry_plan_id=_prefixed_plan_id("asr-retry-plan-", identity),
        resolved_at=utc_now_iso(),
        decision_id=str(decision["decision_id"]),
        windows=windows,
    )
    payload = to_plain(resolved)
    write_json(retry_paths["manifest"], portable_manifest)
    write_json(retry_paths["plan"], payload)
    return _load_asr_retry_plan(
        item=item,
        paths=paths,
        config=config,
        decision=decision,
    )


def _persisted_asr_retry_exists(paths: dict[str, Path], item: dict[str, Any]) -> bool:
    retry_paths = _asr_retry_artifact_paths(paths, item)
    return retry_paths["decision"].is_file() or retry_paths["plan"].is_file()


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
    usage_source_dir: Path | None = None,
) -> dict[str, Any]:
    idx = int(item["segment_index"])
    artifact_paths = _asr_artifact_paths(paths, idx)
    audio_path = Path(item["path"])
    transcribe_path = audio_path
    transcribe_offset = float(item["start"])
    preprocess_meta: dict[str, Any] | None = None
    provider = _active_asr_provider(config)
    if (
        allow_split_retry
        and _asr_allows_split_retry(config)
        and provider.protocol in {
            "openai_transcriptions",
            "funasr_openai",
            "openrouter_stt",
        }
        and task is not None
        and root_dir is not None
        and _persisted_asr_retry_exists(paths, item)
    ):
        return _retry_asr_manifest_item_with_subsegments(
            item=item,
            paths=paths,
            config=config,
            task=task,
            root_dir=root_dir,
            failure=None,
        )
    trim_config = provider.preprocessing.trim_silence
    if trim_config.enabled:
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
        _record_openrouter_asr_usage_receipt(
            source_dir=usage_source_dir or paths["source"],
            provider=provider,
            raw_response=getattr(exc, "raw_response", None),
            transport_meta=dict(getattr(exc, "transport_meta", {}) or {}),
        )
        if (
            allow_split_retry
            and _asr_allows_split_retry(config)
            and provider.protocol in {
                "openai_transcriptions",
                "funasr_openai",
                "openrouter_stt",
            }
            and _is_retryable_asr_exception(exc)
            and task is not None
            and root_dir is not None
            and float(item.get("duration", 0.0)) > max(float(provider.chunking.min_window_seconds) * 2.0, 20.0)
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
    raw_response = _record_openrouter_asr_usage_receipt(
        source_dir=usage_source_dir or paths["source"],
        provider=provider,
        raw_response=raw_response,
        transport_meta=transport_meta,
    )
    if preprocess_meta is not None:
        if preprocess_meta.get("reason") == "trimmed" and _should_retry_asr_without_preprocess(rows):
            initial_raw_response = _asr_raw_response_with_transport(raw_response, transport_meta)
            try:
                fallback_rows, fallback_raw_response, fallback_transport_meta = _transcribe_asr_segment(
                    asr,
                    audio_path,
                    float(item["start"]),
                    prompt=segment_prompt,
                )
            except Exception as exc:
                _record_openrouter_asr_usage_receipt(
                    source_dir=usage_source_dir or paths["source"],
                    provider=provider,
                    raw_response=getattr(exc, "raw_response", None),
                    transport_meta=dict(getattr(exc, "transport_meta", {}) or {}),
                )
                raise
            fallback_raw_response = _record_openrouter_asr_usage_receipt(
                source_dir=usage_source_dir or paths["source"],
                provider=provider,
                raw_response=fallback_raw_response,
                transport_meta=fallback_transport_meta,
            )
            fallback_response = _asr_raw_response_with_transport(
                fallback_raw_response,
                fallback_transport_meta,
            )
            if not _should_retry_asr_without_preprocess(fallback_rows):
                preprocess_meta["fallback_used"] = True
                preprocess_meta["fallback_reason"] = "preprocessed_asr_looked_empty_or_nonspeech"
                preprocess_meta["upload_path"] = str(audio_path)
                preprocess_meta["trim_start_seconds"] = 0.0
                preprocess_meta["trim_end_seconds"] = float(item.get("duration", 0.0))
                rows = fallback_rows
                raw_response = _asr_raw_response_with_related(
                    fallback_raw_response,
                    [initial_raw_response] if initial_raw_response is not None else [],
                )
                transport_meta = fallback_transport_meta
            else:
                raw_response = _asr_raw_response_with_related(
                    raw_response,
                    [fallback_response] if fallback_response is not None else [],
                )
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
    failure: Exception | None,
) -> dict[str, Any]:
    idx = int(item["segment_index"])
    artifact_paths = _asr_artifact_paths(paths, idx)
    duration = float(item.get("duration", 0.0))
    retry_paths = _asr_retry_artifact_paths(paths, item)
    decision = _load_or_create_asr_retry_decision(
        item=item,
        paths=paths,
        config=config,
        task=task,
        create=failure is not None,
    )
    if retry_paths["plan"].is_file():
        retry_plan, child_manifest = _load_asr_retry_plan(
            item=item,
            paths=paths,
            config=config,
            decision=decision,
        )
    else:
        retry_plan, child_manifest = _create_asr_retry_plan(
            item=item,
            paths=paths,
            config=config,
            decision=decision,
        )
    retry_artifact_paths = dict(paths)
    retry_artifact_paths["source"] = retry_paths["result_source"]
    rows: list[dict] = []
    child_window_rows: list[tuple[dict[str, Any], list[dict[str, Any]]]] = []
    raw_children: list[dict] = []
    preprocess_children: list[dict] = []
    child_previous_text = ""
    for child_idx, child in enumerate(child_manifest):
        child_item = dict(child)
        child_item["segment_index"] = child_idx
        child_artifacts = _asr_artifact_paths(
            retry_artifact_paths,
            int(child_item["segment_index"]),
        )
        if _is_valid_json_list(child_artifacts["rows"]):
            child_rows = read_json(child_artifacts["rows"])
            raw_response = read_json(child_artifacts["raw"]) if child_artifacts["raw"].is_file() else None
            preprocess_meta = (
                read_json(child_artifacts["preprocess"])
                if child_artifacts["preprocess"].is_file()
                else None
            )
            child_result = {
                "idx": child_idx,
                "rows": child_rows,
                "raw_response": raw_response if isinstance(raw_response, dict) else None,
                "preprocess_meta": preprocess_meta if isinstance(preprocess_meta, dict) else None,
                "skipped": False,
            }
        else:
            child_asr = _build_asr_engine(config, task=task, root_dir=root_dir)
            try:
                child_result = _process_asr_manifest_item(
                    item=child_item,
                    asr=child_asr,
                    paths=retry_artifact_paths,
                    config=config,
                    task=task,
                    root_dir=root_dir,
                    allow_split_retry=False,
                    previous_text=child_previous_text,
                    usage_source_dir=paths["source"],
                )
            finally:
                close_child_asr = getattr(child_asr, "close", None)
                if callable(close_child_asr):
                    close_child_asr()
            child_rows = list(child_result.get("rows") or [])
        rows.extend(child_rows)
        child_window_rows.append((dict(child_item), child_rows))
        if _asr_uses_previous_text(config):
            text = _asr_previous_text(child_rows)
            if text:
                child_previous_text = text
        if child_result.get("raw_response") is not None:
            raw_children.append(child_result["raw_response"])
        if child_result.get("preprocess_meta") is not None:
            preprocess_children.append(child_result["preprocess_meta"])
    word_overlap_report: dict[str, Any] | None = None
    if _asr_uses_word_timeline(config):
        rows, word_overlap_report = merge_word_timeline_windows(child_window_rows)
    else:
        rows.sort(key=lambda row: (float(row.get("start", 0.0)), float(row.get("end", 0.0)), str(row.get("text", ""))))
    portable_children = _portable_asr_manifest(list(retry_plan["windows"]))
    task_dir = _task_dir_from_paths(paths)
    child_artifact_ref, _child_artifact_path = _task_artifact_ref_from_path(
        retry_paths["result_source"],
        task_dir=task_dir,
    )
    parent_preprocess = {
        "enabled": True,
        "reason": "split_retry",
        "source_segment_id": str(decision["parent"]["segment_id"]),
        "duration_seconds": duration,
        "initial_error": failure.__class__.__name__ if failure is not None else "persisted_retry",
        "retry_decision_id": str(decision["decision_id"]),
        "retry_plan_id": str(retry_plan["retry_plan_id"]),
        "children": portable_children,
        "child_artifact_dir": child_artifact_ref,
        "child_preprocess": preprocess_children,
    }
    if word_overlap_report is not None:
        parent_preprocess["word_overlap"] = word_overlap_report
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
    paths: dict[str, Path],
    provider: Any,
    skipped: bool = False,
) -> None:
    asr_done.add(idx)
    checkpoint["asr_done_segments"] = sorted(asr_done)
    checkpoint["asr_done_count"] = len(asr_done)
    checkpoint["asr_total_segments"] = max(0, int(total_segments))
    checkpoint["status"] = "ASR"
    _sync_checkpoint_openrouter_asr_usage(
        checkpoint,
        paths=paths,
        provider=provider,
    )
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
                message="Retried ASR without silence trim",
                details={"segment_index": result["idx"], "reason": preprocess_meta.get("fallback_reason", "")},
            )
        _complete_asr_segment(
            idx=int(result["idx"]),
            asr_done=asr_done,
            checkpoint=checkpoint,
            store=store,
            task_id=task_id,
            total_segments=total_segments,
            paths=paths,
            provider=_active_asr_provider(config),
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
    execution = _active_asr_provider(config).execution
    max_workers = max(1, int(execution.concurrency))
    max_workers = min(max_workers, max(1, int(execution.max_concurrency)))
    current_limit = max_workers
    pending = list(items)
    while pending:
        _check_cancel(store, task_id)
        batch, pending = _take_asr_upload_batch(
            pending,
            max_items=current_limit,
            max_upload_mb=execution.max_inflight_upload_mb,
        )
        retryable_failure = False
        successes = 0
        with ThreadPoolExecutor(max_workers=current_limit) as executor:
            def submit_item(manifest_item: dict):
                worker_asr = _build_asr_engine(config, task=task, root_dir=root_dir)
                try:
                    return _process_asr_manifest_item(
                        item=manifest_item,
                        asr=worker_asr,
                        paths=paths,
                        config=config,
                        task=task,
                        root_dir=root_dir,
                    )
                finally:
                    close_worker_asr = getattr(worker_asr, "close", None)
                    if callable(close_worker_asr):
                        close_worker_asr()

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
                        execution.adaptive_concurrency
                        and _is_retryable_asr_exception(exc)
                        and current_limit > int(execution.min_concurrency)
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
                        message="Retried ASR without silence trim",
                        details={"segment_index": result["idx"], "reason": preprocess_meta.get("fallback_reason", "")},
                    )
                if result.get("split_retry"):
                    store.append_event(
                        task_id,
                        "warning",
                        stage="ASR",
                        level="warning",
                        message="Retried ASR segment as smaller subsegments",
                        details={"segment_index": result["idx"]},
                    )
                _complete_asr_segment(
                    idx=int(result["idx"]),
                    asr_done=asr_done,
                    checkpoint=checkpoint,
                    store=store,
                    task_id=task_id,
                    total_segments=total_segments,
                    paths=paths,
                    provider=_active_asr_provider(config),
                    skipped=bool(result.get("skipped")),
                )
                successes += 1
        if execution.adaptive_concurrency:
            if retryable_failure:
                current_limit = max(int(execution.min_concurrency), max(1, current_limit // 2))
            elif successes >= current_limit:
                current_limit = min(max_workers, current_limit + 1)


def _asr_prompt_text(config: AppConfig) -> str:
    return _asr_segment_prompt(config)


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


_ASR_PLAN_TIME_TOLERANCE = 0.001
_ASR_CUT_REASONS = {
    "end_of_audio",
    "fixed_window",
    "hard_limit",
    "silence_boundary",
    "whole_audio",
}
_ASR_SEGMENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def _task_dir_from_paths(paths: dict[str, Path]) -> Path:
    if "base" in paths:
        return paths["base"]
    if "asr" in paths:
        return paths["asr"].parent
    if "source" in paths:
        return paths["source"].parent
    raise RuntimeError("asr_task_directory_missing")


def _validated_asr_segment_id(value: Any) -> str:
    segment_id = str(value or "").strip()
    if not _ASR_SEGMENT_ID_PATTERN.fullmatch(segment_id):
        raise RuntimeError("asr_plan_segment_id_invalid")
    return segment_id


def _strict_nonnegative_int(value: Any, *, error: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RuntimeError(error)
    return value


def _finite_number(value: Any, *, error: str) -> float:
    if isinstance(value, bool):
        raise RuntimeError(error)
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise RuntimeError(error) from exc
    if not math.isfinite(parsed):
        raise RuntimeError(error)
    return parsed


def _task_artifact_ref_from_path(path_value: Any, *, task_dir: Path) -> tuple[str, Path]:
    raw = str(path_value or "").strip()
    if not raw or raw.startswith("~"):
        raise RuntimeError("asr_plan_artifact_path_invalid")
    root = task_dir.resolve()
    candidate = Path(raw)
    resolved = candidate.resolve() if candidate.is_absolute() else (root / candidate).resolve()
    try:
        relative = resolved.relative_to(root)
    except ValueError as exc:
        raise RuntimeError("asr_plan_artifact_path_escape") from exc
    artifact_ref = PurePosixPath(*relative.parts).as_posix()
    if not artifact_ref or artifact_ref == ".":
        raise RuntimeError("asr_plan_artifact_path_invalid")
    return artifact_ref, resolved


def _resolve_task_artifact_ref(reference: Any, *, task_dir: Path) -> Path:
    raw = str(reference or "").strip()
    pure = PurePosixPath(raw)
    if (
        not raw
        or raw != pure.as_posix()
        or pure.is_absolute()
        or any(part in {"", ".", ".."} or ":" in part for part in pure.parts)
    ):
        raise RuntimeError("asr_plan_artifact_path_invalid")
    root = task_dir.resolve()
    resolved = root.joinpath(*pure.parts).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise RuntimeError("asr_plan_artifact_path_escape") from exc
    return resolved


def _derived_asr_cut_reason(*, source_end: float, audio_end: float) -> str:
    return "end_of_audio" if source_end >= audio_end - 0.05 else "fixed_window"


def _asr_plan_window_from_manifest(
    item: dict[str, Any],
    *,
    ordinal: int,
    task_dir: Path,
    audio_end: float,
    segment_id_prefix: str = "segment",
) -> AsrPlanWindow:
    segment_index = _strict_nonnegative_int(
        item.get("segment_index"),
        error="asr_plan_segment_index_invalid",
    )
    if segment_index != ordinal:
        raise RuntimeError("asr_plan_segment_index_invalid")
    segment_id = _validated_asr_segment_id(
        item.get("segment_id") or f"{segment_id_prefix}-{segment_index:05d}"
    )
    source_start = _finite_number(item.get("start"), error="asr_plan_window_time_invalid")
    duration = _finite_number(item.get("duration"), error="asr_plan_window_time_invalid")
    source_end = source_start + duration
    trusted_start = _finite_number(
        item.get("trusted_start"),
        error="asr_plan_window_time_invalid",
    )
    trusted_end = _finite_number(
        item.get("trusted_end"),
        error="asr_plan_window_time_invalid",
    )
    if (
        audio_end <= 0
        or source_start < 0
        or duration <= 0
        or source_end > audio_end + 0.1
        or trusted_start < source_start - _ASR_PLAN_TIME_TOLERANCE
        or trusted_end > source_end + _ASR_PLAN_TIME_TOLERANCE
        or trusted_end <= trusted_start
    ):
        raise RuntimeError("asr_plan_window_time_invalid")
    artifact_path, resolved_path = _task_artifact_ref_from_path(
        item.get("path"),
        task_dir=task_dir,
    )
    if not _is_nonempty_file(resolved_path):
        raise RuntimeError("asr_plan_artifact_missing")
    encoded_size_bytes = resolved_path.stat().st_size
    estimated_upload_raw = item.get("estimated_upload_bytes")
    estimated_upload_bytes = (
        _strict_nonnegative_int(
            estimated_upload_raw,
            error="asr_plan_upload_size_invalid",
        )
        if estimated_upload_raw is not None
        else math.ceil(duration * CanonicalAudioFacts().bytes_per_second + 44)
    )
    if estimated_upload_bytes <= 0:
        raise RuntimeError("asr_plan_upload_size_invalid")
    cut_reason = str(item.get("cut_reason") or "").strip() or _derived_asr_cut_reason(
        source_end=source_end,
        audio_end=audio_end,
    )
    if cut_reason not in _ASR_CUT_REASONS:
        raise RuntimeError("asr_plan_cut_reason_invalid")
    return AsrPlanWindow(
        segment_id=segment_id,
        segment_index=segment_index,
        artifact_path=artifact_path,
        content_sha256=_sha256_file(resolved_path),
        encoded_size_bytes=encoded_size_bytes,
        source_start=source_start,
        source_end=source_end,
        trusted_start=trusted_start,
        trusted_end=trusted_end,
        estimated_upload_bytes=estimated_upload_bytes,
        cut_reason=cut_reason,
    )


def _portable_asr_manifest(windows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "segment_id": str(item["segment_id"]),
            "segment_index": int(item["segment_index"]),
            "start": float(item["source_start"]),
            "duration": float(item["source_end"]) - float(item["source_start"]),
            "trusted_start": float(item["trusted_start"]),
            "trusted_end": float(item["trusted_end"]),
            "estimated_upload_bytes": int(item["estimated_upload_bytes"]),
            "encoded_size_bytes": int(item["encoded_size_bytes"]),
            "content_sha256": str(item["content_sha256"]),
            "cut_reason": str(item["cut_reason"]),
            "path": str(item["artifact_path"]),
        }
        for item in windows
    ]


def _validated_plan_window(
    planned: dict[str, Any],
    *,
    ordinal: int,
    task_dir: Path,
) -> dict[str, Any]:
    if not isinstance(planned, dict):
        raise RuntimeError("asr_plan_manifest_mismatch")
    segment_index = _strict_nonnegative_int(
        planned.get("segment_index"),
        error="asr_plan_segment_index_invalid",
    )
    if segment_index != ordinal:
        raise RuntimeError("asr_plan_segment_index_invalid")
    segment_id = _validated_asr_segment_id(planned.get("segment_id"))
    source_start = _finite_number(
        planned.get("source_start"),
        error="asr_plan_window_time_invalid",
    )
    source_end = _finite_number(
        planned.get("source_end"),
        error="asr_plan_window_time_invalid",
    )
    trusted_start = _finite_number(
        planned.get("trusted_start"),
        error="asr_plan_window_time_invalid",
    )
    trusted_end = _finite_number(
        planned.get("trusted_end"),
        error="asr_plan_window_time_invalid",
    )
    if (
        source_start < 0
        or source_end <= source_start
        or trusted_start < source_start - _ASR_PLAN_TIME_TOLERANCE
        or trusted_end > source_end + _ASR_PLAN_TIME_TOLERANCE
        or trusted_end <= trusted_start
    ):
        raise RuntimeError("asr_plan_window_time_invalid")
    estimated_upload_bytes = _strict_nonnegative_int(
        planned.get("estimated_upload_bytes"),
        error="asr_plan_upload_size_invalid",
    )
    encoded_size_bytes = _strict_nonnegative_int(
        planned.get("encoded_size_bytes"),
        error="asr_plan_artifact_size_invalid",
    )
    if estimated_upload_bytes <= 0 or encoded_size_bytes <= 0:
        raise RuntimeError("asr_plan_artifact_size_invalid")
    cut_reason = str(planned.get("cut_reason") or "").strip()
    if cut_reason not in _ASR_CUT_REASONS:
        raise RuntimeError("asr_plan_cut_reason_invalid")
    content_sha256 = str(planned.get("content_sha256") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", content_sha256):
        raise RuntimeError("asr_plan_content_hash_invalid")
    artifact_path = str(planned.get("artifact_path") or "")
    resolved_path = _resolve_task_artifact_ref(artifact_path, task_dir=task_dir)
    if not _is_nonempty_file(resolved_path):
        raise RuntimeError("asr_plan_artifact_missing")
    if resolved_path.stat().st_size != encoded_size_bytes:
        raise RuntimeError("asr_plan_artifact_size_mismatch")
    if _sha256_file(resolved_path) != content_sha256:
        raise RuntimeError("asr_plan_content_hash_mismatch")
    return {
        "segment_id": segment_id,
        "segment_index": segment_index,
        "start": source_start,
        "duration": source_end - source_start,
        "trusted_start": trusted_start,
        "trusted_end": trusted_end,
        "estimated_upload_bytes": estimated_upload_bytes,
        "encoded_size_bytes": encoded_size_bytes,
        "content_sha256": content_sha256,
        "cut_reason": cut_reason,
        "artifact_path": artifact_path,
        "path": str(resolved_path),
    }


def _validate_asr_window_sequence(
    windows: list[dict[str, Any]],
    *,
    audio_start: float,
    audio_end: float,
    error: str,
) -> None:
    if not windows or audio_end <= audio_start:
        raise RuntimeError(error)
    first = windows[0]
    last = windows[-1]
    if (
        abs(float(first["start"]) - audio_start) > 0.1
        or abs(float(first["trusted_start"]) - audio_start) > 0.1
        or abs(float(last["start"]) + float(last["duration"]) - audio_end) > 0.1
        or abs(float(last["trusted_end"]) - audio_end) > 0.1
    ):
        raise RuntimeError(error)
    for ordinal, window in enumerate(windows):
        is_last = ordinal == len(windows) - 1
        cut_reason = str(window["cut_reason"])
        valid_terminal_cut = cut_reason == "end_of_audio" or (
            len(windows) == 1 and cut_reason == "whole_audio"
        )
        if valid_terminal_cut != is_last:
            raise RuntimeError(error)
        if ordinal == 0:
            continue
        previous = windows[ordinal - 1]
        previous_start = float(previous["start"])
        previous_end = previous_start + float(previous["duration"])
        current_start = float(window["start"])
        if (
            current_start <= previous_start
            or current_start > previous_end + 0.1
            or abs(float(window["trusted_start"]) - float(previous["trusted_end"])) > 0.1
        ):
            raise RuntimeError(error)


def _manifest_matches_planned_window(actual: Any, planned: dict[str, Any]) -> bool:
    if not isinstance(actual, dict):
        return False
    exact_fields = (
        "segment_id",
        "segment_index",
        "estimated_upload_bytes",
        "encoded_size_bytes",
        "content_sha256",
        "cut_reason",
    )
    if any(actual.get(field) != planned.get(field) for field in exact_fields):
        return False
    if str(actual.get("path") or "") != str(planned.get("artifact_path") or ""):
        return False
    return not any(
        abs(
            _finite_number(actual.get(actual_field), error="asr_plan_manifest_mismatch")
            - float(planned[planned_field])
        )
        > _ASR_PLAN_TIME_TOLERANCE
        for actual_field, planned_field in (
            ("start", "start"),
            ("duration", "duration"),
            ("trusted_start", "trusted_start"),
            ("trusted_end", "trusted_end"),
        )
    )


def _ingest_artifacts_valid(audio_full: Path, manifest_file: Path, *, task_dir: Path) -> bool:
    if not _is_nonempty_file(audio_full) or not _is_valid_json_list(manifest_file):
        return False
    try:
        manifest = read_json(manifest_file)
    except Exception:
        return False
    for item in manifest:
        if not isinstance(item, dict):
            return False
        try:
            _artifact_ref, artifact_path = _task_artifact_ref_from_path(
                item.get("path"),
                task_dir=task_dir,
            )
        except RuntimeError:
            return False
        if not _is_nonempty_file(artifact_path):
            return False
    return True


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _stable_plan_identity(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _stable_plan_identity(item)
            for key, item in value.items()
            if key not in {"observed_at", "checked_at", "captured_at"}
        }
    if isinstance(value, list):
        return [_stable_plan_identity(item) for item in value]
    return value


def _asr_plan_id(identity: dict[str, Any]) -> str:
    return "asr-" + hashlib.sha256(
        json.dumps(
            _stable_plan_identity(identity),
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()[:20]


def _resolved_asr_concurrency(
    config: AppConfig,
    estimated_upload_bytes: list[int],
) -> int:
    policy_resolution = config.asr_policy_resolutions.get(config.pipeline.asr_provider)
    if policy_resolution is None:
        return max(1, _active_asr_provider(config).execution.concurrency)
    execution = policy_resolution.policy.execution
    largest_upload = max(estimated_upload_bytes, default=1)
    inflight_parallelism = max(
        1,
        execution.max_inflight_audio_bytes // max(largest_upload, 1),
    )
    if _asr_uses_previous_text(config):
        return 1
    return max(
        1,
        min(
            execution.target_concurrency,
            execution.maximum_concurrency,
            max(len(estimated_upload_bytes), 1),
            inflight_parallelism,
        ),
    )


def _resolved_asr_plan(
    config: AppConfig,
    *,
    audio_full: Path,
    media_meta: dict[str, Any],
    manifest: list[dict],
    planning_metadata: dict[str, Any],
    paths: dict[str, Path],
) -> ResolvedAsrPlan | None:
    engine_id = config.pipeline.asr_provider
    engine = config.asr_engine_specs.get(engine_id)
    capabilities = config.asr_capabilities.get(engine_id)
    policy_resolution = config.asr_policy_resolutions.get(engine_id)
    if engine is None or capabilities is None or policy_resolution is None:
        return None

    silence_ranges = [
        item
        for item in planning_metadata.get("silence_ranges") or []
        if isinstance(item, dict)
    ]
    silence_payload = {
        "schema_version": 1,
        "mode": str(planning_metadata.get("mode") or policy_resolution.policy.chunking.mode),
        "noise_db": policy_resolution.policy.chunking.silence.noise_db,
        "minimum_seconds": policy_resolution.policy.chunking.silence.minimum_seconds,
        "ranges": silence_ranges,
    }
    silence_text = json.dumps(
        silence_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    silence_fingerprint = hashlib.sha256(silence_text.encode("utf-8")).hexdigest()
    silence_path = paths["asr"] / "silence_analysis.json"
    write_json(silence_path, silence_payload)

    audio_facts = AudioFacts(
        content_fingerprint=_sha256_file(audio_full),
        duration_seconds=float(media_meta.get("duration_seconds") or 0.0),
        encoded_size_bytes=audio_full.stat().st_size,
        selected_stream=AudioStreamFacts(
            index=_strict_nonnegative_int(
                media_meta.get("audio_stream_index", 0),
                error="asr_plan_audio_stream_invalid",
            ),
            codec=str(media_meta.get("audio_codec") or ""),
            sample_rate_hz=(
                _strict_nonnegative_int(
                    media_meta["audio_stream_sample_rate_hz"],
                    error="asr_plan_audio_stream_invalid",
                )
                if media_meta.get("audio_stream_sample_rate_hz") is not None
                else None
            ),
            channels=(
                _strict_nonnegative_int(
                    media_meta["audio_stream_channels"],
                    error="asr_plan_audio_stream_invalid",
                )
                if media_meta.get("audio_stream_channels") is not None
                else None
            ),
            bitrate=(
                _strict_nonnegative_int(
                    media_meta["audio_stream_bitrate"],
                    error="asr_plan_audio_stream_invalid",
                )
                if media_meta.get("audio_stream_bitrate") is not None
                else None
            ),
            language_tag=str(media_meta.get("audio_stream_language") or ""),
        ),
        canonical_audio=CanonicalAudioFacts(),
        silence_analysis=SilenceAnalysisFacts(
            artifact_ref="asr/silence_analysis.json",
            fingerprint=silence_fingerprint,
            range_count=len(silence_ranges),
        ),
    )
    task_dir = _task_dir_from_paths(paths)
    audio_end = float(media_meta.get("duration_seconds") or 0.0)
    windows = tuple(
        _asr_plan_window_from_manifest(
            item,
            ordinal=ordinal,
            task_dir=task_dir,
            audio_end=audio_end,
        )
        for ordinal, item in enumerate(manifest)
    )
    if len({item.segment_id for item in windows}) != len(windows):
        raise RuntimeError("asr_plan_segment_id_duplicate")
    _validate_asr_plan_policy_limits(config, windows)
    execution_policy = policy_resolution.policy.execution
    actual_concurrency = _resolved_asr_concurrency(
        config,
        [item.estimated_upload_bytes for item in windows],
    )
    execution = AsrExecutionPlan(
        actual_concurrency=actual_concurrency,
        request_deadline_seconds=execution_policy.request_deadline_seconds,
        max_attempts=execution_policy.max_attempts,
        split_retry=execution_policy.split_retry,
    )
    if _asr_uses_word_timeline(config):
        timeline = AsrTimelinePlan(
            input_granularity="word",
            strategy_id="word_timeline_boundary_alignment",
            strategy_version=1,
        )
    elif any(item.trusted_start > item.source_start or item.trusted_end < item.source_end for item in windows):
        timeline = AsrTimelinePlan(
            input_granularity="segment",
            strategy_id="trusted_midpoint_segment_merge",
            strategy_version=1,
        )
    else:
        timeline = AsrTimelinePlan(
            input_granularity="segment",
            strategy_id="ordered_segment_timeline",
            strategy_version=1,
        )
    identity = {
        "engine": to_plain(engine),
        "capabilities": to_plain(capabilities),
        "effective_policy": to_plain(policy_resolution.policy),
        "audio_facts": to_plain(audio_facts),
        "windows": to_plain(windows),
        "execution": to_plain(execution),
        "timeline": to_plain(timeline),
    }
    plan_id = _asr_plan_id(identity)
    return ResolvedAsrPlan(
        plan_id=plan_id,
        resolved_at=utc_now_iso(),
        engine=engine,
        capabilities=capabilities,
        effective_policy=policy_resolution.policy,
        policy_sources=dict(policy_resolution.sources),
        audio_facts=audio_facts,
        windows=windows,
        execution=execution,
        timeline=timeline,
        adjustments=policy_resolution.adjustments,
    )


def _validate_asr_plan_policy_limits(
    config: AppConfig,
    windows: tuple[AsrPlanWindow, ...] | list[dict[str, Any]],
) -> None:
    resolution = config.asr_policy_resolutions.get(config.pipeline.asr_provider)
    if resolution is None:
        return
    policy = resolution.policy
    duration_limit = _asr_duration_hard_limit(config)
    upload_hard_limit = _asr_upload_hard_limit(config)
    upload_soft_limit = policy.chunking.upload_soft_limit_bytes

    def value(window: AsrPlanWindow | dict[str, Any], name: str) -> Any:
        if isinstance(window, dict):
            return window.get(name)
        return getattr(window, name)

    if policy.chunking.mode == "none":
        if (
            len(windows) != 1
            or str(value(windows[0], "cut_reason")) != "whole_audio"
        ):
            raise RuntimeError("asr_plan_none_mode_not_whole_audio")

    for window in windows:
        source_start = _finite_number(
            value(window, "source_start")
            if not isinstance(window, dict)
            else window.get("start"),
            error="asr_plan_window_time_invalid",
        )
        source_end = _finite_number(
            value(window, "source_end")
            if not isinstance(window, dict)
            else source_start + _finite_number(
                window.get("duration"),
                error="asr_plan_window_time_invalid",
            ),
            error="asr_plan_window_time_invalid",
        )
        window_duration = source_end - source_start
        if (
            duration_limit is not None
            and window_duration > duration_limit + _ASR_PLAN_TIME_TOLERANCE
        ):
            raise RuntimeError("asr_plan_window_duration_capability_exceeded")

        estimated_upload_bytes = _strict_nonnegative_int(
            value(window, "estimated_upload_bytes"),
            error="asr_plan_upload_size_invalid",
        )
        encoded_size_bytes = _strict_nonnegative_int(
            value(window, "encoded_size_bytes"),
            error="asr_plan_artifact_size_invalid",
        )
        if upload_hard_limit is not None and (
            estimated_upload_bytes > upload_hard_limit
            or encoded_size_bytes > upload_hard_limit
        ):
            raise RuntimeError("asr_plan_window_upload_capability_exceeded")
        if upload_soft_limit is not None and (
            estimated_upload_bytes > upload_soft_limit
            or encoded_size_bytes > upload_soft_limit
        ):
            raise RuntimeError("asr_plan_window_upload_policy_exceeded")


def _apply_resolved_asr_plan(
    config: AppConfig,
    plan: dict[str, Any],
    manifest: list[dict],
    *,
    task_dir: Path,
    audio_full: Path | None = None,
) -> None:
    if _strict_nonnegative_int(
        plan.get("plan_schema_version"),
        error="unsupported_asr_plan_schema",
    ) != ASR_PLAN_SCHEMA_VERSION:
        raise RuntimeError("unsupported_asr_plan_schema")
    identity_fields = (
        "engine",
        "capabilities",
        "effective_policy",
        "audio_facts",
        "windows",
        "execution",
        "timeline",
    )
    identity = {field: plan.get(field) for field in identity_fields}
    if str(plan.get("plan_id") or "") != _asr_plan_id(identity):
        raise RuntimeError("asr_plan_integrity_mismatch")
    engine = plan.get("engine") if isinstance(plan.get("engine"), dict) else {}
    if str(engine.get("id") or "") != config.pipeline.asr_provider:
        raise RuntimeError("asr_plan_engine_mismatch")
    active_engine = config.asr_engine_specs.get(config.pipeline.asr_provider)
    if active_engine is not None and _stable_plan_identity(engine) != _stable_plan_identity(
        to_plain(active_engine)
    ):
        raise RuntimeError("asr_plan_engine_mismatch")
    active_policy = config.asr_policy_resolutions.get(config.pipeline.asr_provider)
    planned_policy = plan.get("effective_policy")
    if active_policy is not None and _stable_plan_identity(planned_policy) != _stable_plan_identity(
        to_plain(active_policy.policy)
    ):
        raise RuntimeError("asr_plan_policy_mismatch")
    active_capabilities = config.asr_capabilities.get(config.pipeline.asr_provider)
    planned_capabilities = plan.get("capabilities")
    if active_capabilities is not None and _stable_plan_identity(
        planned_capabilities
    ) != _stable_plan_identity(to_plain(active_capabilities)):
        raise RuntimeError("asr_plan_capabilities_mismatch")
    audio_facts = plan.get("audio_facts") if isinstance(plan.get("audio_facts"), dict) else {}
    planned_duration = _finite_number(
        audio_facts.get("duration_seconds"),
        error="asr_plan_audio_duration_invalid",
    )
    if planned_duration <= 0:
        raise RuntimeError("asr_plan_audio_duration_mismatch")
    if audio_full is not None:
        if str(audio_facts.get("content_fingerprint") or "") != _sha256_file(audio_full):
            raise RuntimeError("asr_plan_audio_mismatch")
        if _strict_nonnegative_int(
            audio_facts.get("encoded_size_bytes"),
            error="asr_plan_audio_mismatch",
        ) != audio_full.stat().st_size:
            raise RuntimeError("asr_plan_audio_mismatch")
        canonical_audio = (
            audio_facts.get("canonical_audio")
            if isinstance(audio_facts.get("canonical_audio"), dict)
            else {}
        )
        if canonical_audio != to_plain(CanonicalAudioFacts()):
            raise RuntimeError("asr_plan_audio_format_mismatch")
    windows = plan.get("windows") if isinstance(plan.get("windows"), list) else []
    if len(windows) != len(manifest):
        raise RuntimeError("asr_plan_manifest_mismatch")
    segment_ids: set[str] = set()
    runtime_windows: list[dict[str, Any]] = []
    for ordinal, (planned, actual) in enumerate(zip(windows, manifest, strict=True)):
        validated = _validated_plan_window(
            planned,
            ordinal=ordinal,
            task_dir=task_dir,
        )
        if validated["segment_id"] in segment_ids:
            raise RuntimeError("asr_plan_segment_id_duplicate")
        segment_ids.add(validated["segment_id"])
        try:
            actual_window = _asr_plan_window_from_manifest(
                actual,
                ordinal=ordinal,
                task_dir=task_dir,
                audio_end=planned_duration,
            )
        except RuntimeError as exc:
            raise RuntimeError("asr_plan_manifest_mismatch") from exc
        normalized_actual = _portable_asr_manifest([to_plain(actual_window)])[0]
        for field in (
            "segment_id",
            "estimated_upload_bytes",
            "encoded_size_bytes",
            "content_sha256",
            "cut_reason",
        ):
            if field in actual:
                normalized_actual[field] = actual[field]
        if not _manifest_matches_planned_window(normalized_actual, validated):
            raise RuntimeError("asr_plan_manifest_mismatch")
        runtime_windows.append(validated)
    _validate_asr_window_sequence(
        runtime_windows,
        audio_start=0.0,
        audio_end=planned_duration,
        error="asr_plan_audio_duration_mismatch",
    )
    _validate_asr_plan_policy_limits(config, runtime_windows)
    timeline = plan.get("timeline") if isinstance(plan.get("timeline"), dict) else {}
    supported_timelines = {
        ("word_timeline_boundary_alignment", 1),
        ("trusted_midpoint_segment_merge", 1),
        ("ordered_segment_timeline", 1),
    }
    timeline_key = (
        str(timeline.get("strategy_id") or ""),
        _strict_nonnegative_int(
            timeline.get("strategy_version"),
            error="unsupported_asr_timeline_strategy",
        ),
    )
    if timeline_key not in supported_timelines:
        raise RuntimeError("unsupported_asr_timeline_strategy")
    if (str(timeline.get("input_granularity")) == "word") != _asr_uses_word_timeline(config):
        raise RuntimeError("asr_plan_timeline_mismatch")
    execution = plan.get("execution") if isinstance(plan.get("execution"), dict) else {}
    if bool(execution.get("split_retry")) != _asr_allows_split_retry(config):
        raise RuntimeError("asr_plan_execution_mismatch")
    planned_uploads = [
        _strict_nonnegative_int(
            item.get("estimated_upload_bytes"),
            error="asr_plan_execution_mismatch",
        )
        for item in windows
        if isinstance(item, dict)
    ]
    actual_concurrency = _strict_nonnegative_int(
        execution.get("actual_concurrency"),
        error="asr_plan_execution_mismatch",
    )
    if actual_concurrency != _resolved_asr_concurrency(
        config,
        planned_uploads,
    ):
        raise RuntimeError("asr_plan_execution_mismatch")
    if active_policy is not None and (
        _finite_number(
            execution.get("request_deadline_seconds"),
            error="asr_plan_execution_mismatch",
        )
        != float(active_policy.policy.execution.request_deadline_seconds)
        or _strict_nonnegative_int(
            execution.get("max_attempts"),
            error="asr_plan_execution_mismatch",
        )
        != active_policy.policy.execution.max_attempts
    ):
        raise RuntimeError("asr_plan_execution_mismatch")
    provider = _active_asr_provider(config)
    provider.execution.concurrency = max(1, actual_concurrency)
    provider.execution.timeout_seconds = max(
        0.001,
        _finite_number(
            execution.get("request_deadline_seconds"),
            error="asr_plan_execution_mismatch",
        ),
    )
    provider.execution.retry = max(
        1,
        _strict_nonnegative_int(
            execution.get("max_attempts"),
            error="asr_plan_execution_mismatch",
        ),
    )
    for actual, runtime_window in zip(manifest, runtime_windows, strict=True):
        actual.clear()
        actual.update(runtime_window)


def _ensure_resolved_asr_plan(
    config: AppConfig,
    store: TaskStore,
    task: TaskRecord,
    *,
    audio_full: Path,
    media_meta: dict[str, Any],
    manifest: list[dict],
    planning_metadata: dict[str, Any],
    paths: dict[str, Path],
) -> dict[str, Any] | None:
    task_dir = _task_dir_from_paths(paths)
    plan_file = paths["asr"] / "asr_plan.json"
    manifest_file = paths["asr"] / "segments_manifest.json"
    saved = task.settings.get("asr_plan")
    if isinstance(saved, dict):
        _apply_resolved_asr_plan(
            config,
            saved,
            manifest,
            task_dir=task_dir,
            audio_full=audio_full,
        )
        try:
            plan_file_matches = plan_file.is_file() and read_json(plan_file) == saved
        except (OSError, ValueError, json.JSONDecodeError):
            plan_file_matches = False
        if plan_file.exists() and not plan_file_matches:
            raise RuntimeError("asr_plan_artifact_mismatch")
        if not plan_file.exists():
            write_json(plan_file, saved)
        return saved
    resolved = _resolved_asr_plan(
        config,
        audio_full=audio_full,
        media_meta=media_meta,
        manifest=manifest,
        planning_metadata=planning_metadata,
        paths=paths,
    )
    if resolved is None:
        return None
    payload = to_plain(resolved)
    portable_manifest = _portable_asr_manifest(list(payload["windows"]))
    manifest[:] = [dict(item) for item in portable_manifest]
    _apply_resolved_asr_plan(
        config,
        payload,
        manifest,
        task_dir=task_dir,
        audio_full=audio_full,
    )
    write_json(plan_file, payload)
    write_json(manifest_file, portable_manifest)
    task.settings["asr_plan"] = payload
    store.save_task(task)
    return payload


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
    task = _create_task(
        store,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        settings=_task_settings(config, input_type=normalized_input_type, root_dir=root_dir),
    )
    if status != "INIT":
        store.update_task_status(task.task_id, status)
    store.clear_cancel(task.task_id)
    store.append_event(task.task_id, "task_created", stage=status, message="Task created", progress=_stage_progress(status))
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


def _translation_route_providers(config: AppConfig) -> list:
    out = []
    for route in [config.routing.primary] + list(config.routing.fallback):
        provider = config.providers.get(route.provider)
        if provider is not None:
            out.append(
                replace(
                    provider,
                    capabilities=provider.capabilities_for_model(route.model),
                )
            )
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
                "batch_recovery_requests",
                "batch_recovered_rows",
            ]
            if provider_meta.get(key) is not None
        },
        "chunk_meta": chunk_meta,
        "validation": {
            "issue_count": len(validation.get("issues") or []),
            "issues": validation.get("issues") or [],
        },
        "protocol_recovered": bool(request_meta.get("protocol_recovered", False)),
        "batch_recovery_requests": int(request_meta.get("batch_recovery_requests") or 0),
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
    if normalized == "webvtt":
        normalized = "vtt"
    return normalized if normalized in {"srt", "ass", "vtt", "lrc", "both"} else "srt"


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
        if output_format == "vtt":
            return output_format, {"vtt": output_file.with_suffix(".vtt")}
        if output_format == "lrc":
            return output_format, {"lrc": output_file.with_suffix(".lrc")}
        return output_format, {
            "srt": base.parent / f"{base.name}.srt",
            "ass": base.parent / f"{base.name}.ass",
        }
    base = output_dir / f"{stem}.{task.target_lang}"
    if output_format == "srt":
        return output_format, {"srt": base.parent / f"{base.name}.srt"}
    if output_format == "ass":
        return output_format, {"ass": base.parent / f"{base.name}.ass"}
    if output_format == "vtt":
        return output_format, {"vtt": base.parent / f"{base.name}.vtt"}
    if output_format == "lrc":
        return output_format, {"lrc": base.parent / f"{base.name}.lrc"}
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
                _emit_stage(store, task_id, "INGEST", "Extracting and splitting audio")
                audio_full = paths["media"] / "audio_full.m4a"
                manifest_file = paths["asr"] / "segments_manifest.json"
                if not _ingest_artifacts_valid(
                    audio_full,
                    manifest_file,
                    task_dir=paths["base"],
                ):
                    media_meta = extract_audio_for_asr(
                        Path(task.input_file),
                        audio_full,
                        source_lang=task.source_lang,
                        audio_track=config.pipeline.asr_audio_track,
                    )
                    asr_provider = _active_asr_provider(config)
                    chunking = asr_provider.chunking
                    planning_metadata: dict[str, Any] = {}
                    segments_manifest = split_audio_for_asr(
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
                _emit_stage(store, task_id, "ASR", "Transcribing audio segments")
                asr = _build_asr_engine(config, task=task, root_dir=root_dir)
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
                    progress_callback=_translation_progress_callback(
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
        checkpoint["source_segment_count"] = len(all_segments)
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
        quality_progress = _translation_progress_callback(store, task_id, checkpoint, stage="QUALITY")
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

        _check_cancel(store, task_id)
        output_format, output_paths = _output_paths_for_task(
            config=config,
            task=task,
            output_file=output_file,
            output_dir=paths["output"],
        )
        _emit_stage(store, task_id, "EXPORT", f"Exporting {output_format.upper()} subtitles")
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
