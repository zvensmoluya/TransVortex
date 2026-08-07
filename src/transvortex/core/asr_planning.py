from __future__ import annotations

import hashlib
import json
import math
import re
from pathlib import Path, PurePosixPath
from typing import Any

from ..app.models import AppConfig, TaskRecord
from ..artifacts.task_store import TaskStore
from ..asr_domain import (
    ASR_PLAN_SCHEMA_VERSION,
    AsrExecutionPlan,
    AsrPlanWindow,
    AsrTimelinePlan,
    AudioFacts,
    AudioStreamFacts,
    CanonicalAudioFacts,
    ResolvedAsrPlan,
    SilenceAnalysisFacts,
)
from ..openrouter_asr import openrouter_asr_model_profile
from ..utils import read_json, to_plain, utc_now_iso, write_json
from .pipeline_runtime import _is_nonempty_file, _is_valid_json_list

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
