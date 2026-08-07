from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Segment, TaskRecord
from ..artifacts.task_store import TaskStore
from ..asr_domain import (
    ASR_RETRY_SCHEMA_VERSION,
    AsrRetryDecision,
    AsrRetryParent,
    AsrSplitRetryStrategy,
    ResolvedAsrRetryPlan,
)
from ..http import is_retryable_http_error
from ..utils import read_json, to_plain, utc_now_iso, write_json
from .asr import write_segment_asr_output
from .asr_planning import (
    _ASR_PLAN_TIME_TOLERANCE,
    _active_asr_provider,
    _asr_allows_split_retry,
    _asr_duration_hard_limit,
    _asr_plan_id,
    _asr_plan_window_from_manifest,
    _asr_uses_previous_text,
    _asr_uses_word_timeline,
    _finite_number,
    _portable_asr_manifest,
    _resolve_task_artifact_ref,
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
from .openrouter_asr_usage import (
    record_openrouter_asr_usage_receipt as _record_openrouter_asr_usage_receipt,
    write_openrouter_asr_usage_artifact as _write_openrouter_asr_usage_artifact,
)
from .pipeline_runtime import _check_cancel, _is_nonempty_file, _is_valid_json_list
from .word_timeline import merge_word_timeline_windows


@dataclass(frozen=True)
class AsrExecutionDependencies:
    build_engine: Callable[..., Any]
    prepare_cloud_asr_audio_upload: Callable[..., dict[str, Any]]
    split_audio_for_asr: Callable[..., list[dict]]

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
    dependencies: AsrExecutionDependencies,
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
    child_manifest = dependencies.split_audio_for_asr(
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
    dependencies: AsrExecutionDependencies,
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
            dependencies=dependencies,
            item=item,
            paths=paths,
            config=config,
            task=task,
            root_dir=root_dir,
            failure=None,
        )
    trim_config = provider.preprocessing.trim_silence
    if trim_config.enabled:
        preprocess_meta = dependencies.prepare_cloud_asr_audio_upload(
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
                dependencies=dependencies,
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
    dependencies: AsrExecutionDependencies,
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
            dependencies=dependencies,
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
            child_asr = dependencies.build_engine(
                config,
                task=task,
                root_dir=root_dir,
            )
            try:
                child_result = _process_asr_manifest_item(
                    dependencies=dependencies,
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
    dependencies: AsrExecutionDependencies,
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
            dependencies=dependencies,
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
    dependencies: AsrExecutionDependencies,
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
                worker_asr = dependencies.build_engine(
                    config,
                    task=task,
                    root_dir=root_dir,
                )
                try:
                    return _process_asr_manifest_item(
                        dependencies=dependencies,
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
