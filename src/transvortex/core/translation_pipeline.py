from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from typing import Any

from ..app.models import AppConfig
from ..artifacts.task_store import TaskStore
from ..memory.plan import memory_enabled
from ..utils import append_jsonl
from .translate import _adaptive_chunk_by_id, _source_chunk_completed_count
from .translation_validation import validate_translation_response, validation_to_json

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
