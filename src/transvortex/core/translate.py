from __future__ import annotations

import concurrent.futures
import inspect
import time
from dataclasses import replace
from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment
from ..memory.injector import build_memory_prompt
from ..memory.merger import merge_patch
from ..memory.patcher import generate_memory_patch
from ..memory.selector import select_memory_entries
from ..memory.store import MemoryStore
from ..memory.plan import dynamic_updates_enabled, effective_memory_sources, translates_with_memory
from ..providers import build_provider_client, classify_error
from .chunking import translation_prompt_overhead_tokens, trim_context_for_budget
from .translation_validation import (
    ParsedTranslationRow,
    TranslationValidationIssue,
    TranslationValidationResult,
    validate_translation_response,
    validation_to_json,
)


ProgressCallback = Callable[[dict[str, Any]], None]


class AdaptiveTranslationError(RuntimeError):
    def __init__(self, message: str, partial_results: list[dict] | None = None) -> None:
        super().__init__(message)
        self.partial_results = partial_results or []


class TranslationProtocolIncompleteError(RuntimeError):
    pass


def _notify_progress(progress_callback: ProgressCallback | None, **payload: Any) -> None:
    if progress_callback is None:
        return
    try:
        progress_callback(payload)
    except Exception:
        pass


def _memory_prompt_entry_count(memory_prompt: str) -> int:
    return sum(1 for line in str(memory_prompt or "").splitlines() if line.strip().startswith("- "))


_HARD_CAPACITY_SPLIT_MARKERS = {
    "batch too large",
    "context length",
    "maximum context",
    "max context",
    "too many tokens",
    "token limit",
    "maximum tokens",
    "request too large",
    "payload too large",
    "413",
}

_PROTOCOL_RECOVERY_CODES = {
    "bad_line_format",
    "explanatory_output",
    "duplicate_id",
    "context_id_output",
    "extra_id",
}

_COMPLETION_ERROR_CODES = {"missing_id", "empty_translation"}
_MAX_INDIVIDUAL_ROW_REPAIRS = 8
_MIN_TRAILING_BATCH_RECOVERY = 3
_MAX_BATCH_RECOVERY_LINES = 120
_RECOVERY_CONTEXT_BEFORE_LINES = 12
_RECOVERY_CONTEXT_AFTER_LINES = 8


def _translate_chunk_accepts_progress_callback() -> bool:
    try:
        return "progress_callback" in inspect.signature(translate_chunk).parameters
    except Exception:
        return False


def _translate_chunk_adaptive_accepts_progress_callback() -> bool:
    try:
        return "progress_callback" in inspect.signature(translate_chunk_adaptive).parameters
    except Exception:
        return False


def _submit_translate_chunk(
    pool: concurrent.futures.ThreadPoolExecutor,
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    memory_prompt: str,
    progress_callback: ProgressCallback | None,
    already_done: set[str] | None = None,
    memory_prompt_builder: Callable[[Chunk], str] | None = None,
):
    if config.pipeline.translation.batching.mode == "adaptive":
        if _translate_chunk_adaptive_accepts_progress_callback():
            return pool.submit(
                translate_chunk_adaptive,
                config,
                chunk,
                source_lang,
                target_lang,
                memory_prompt=memory_prompt,
                progress_callback=progress_callback,
                already_done=already_done,
                memory_prompt_builder=memory_prompt_builder,
            )
        return pool.submit(translate_chunk_adaptive, config, chunk, source_lang, target_lang, memory_prompt)
    if _translate_chunk_accepts_progress_callback():
        return pool.submit(
            translate_chunk,
            config,
            chunk,
            source_lang,
            target_lang,
            memory_prompt=memory_prompt,
            progress_callback=progress_callback,
        )
    return pool.submit(translate_chunk, config, chunk, source_lang, target_lang, memory_prompt)


def _call_translate_chunk(
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    memory_prompt: str,
    progress_callback: ProgressCallback | None,
) -> dict:
    if _translate_chunk_accepts_progress_callback():
        return translate_chunk(
            config,
            chunk,
            source_lang,
            target_lang,
            memory_prompt=memory_prompt,
            progress_callback=progress_callback,
        )
    return translate_chunk(config, chunk, source_lang, target_lang, memory_prompt)


def _call_translate_chunk_or_adaptive(
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    memory_prompt: str,
    progress_callback: ProgressCallback | None,
    already_done: set[str] | None = None,
    memory_prompt_builder: Callable[[Chunk], str] | None = None,
) -> dict | list[dict]:
    if config.pipeline.translation.batching.mode == "adaptive":
        kwargs: dict[str, Any] = {
            "memory_prompt": memory_prompt,
            "already_done": already_done,
            "memory_prompt_builder": memory_prompt_builder,
        }
        if _translate_chunk_adaptive_accepts_progress_callback():
            kwargs["progress_callback"] = progress_callback
        return translate_chunk_adaptive(config, chunk, source_lang, target_lang, **kwargs)
    return _call_translate_chunk(config, chunk, source_lang, target_lang, memory_prompt, progress_callback)


def _generate_memory_patch_accepts_progress_callback() -> bool:
    try:
        return "progress_callback" in inspect.signature(generate_memory_patch).parameters
    except Exception:
        return False


def _chunk_source_by_id(chunk: Chunk) -> dict[int, str]:
    out: dict[int, str] = {}
    for line in chunk.lines:
        stripped = line.strip()
        if not stripped.startswith("[") or "]" not in stripped:
            continue
        raw_id, text = stripped[1:].split("]", 1)
        try:
            out[int(raw_id)] = text.strip()
        except ValueError:
            continue
    return out


def _contextual_subchunk(chunk: Chunk, segment_ids: list[int], *, chunk_id: str) -> Chunk:
    selected = set(segment_ids)
    indexed_lines = list(zip(chunk.segment_ids, chunk.lines))
    positions = [idx for idx, (seg_id, _line) in enumerate(indexed_lines) if seg_id in selected]
    if not positions:
        return replace(chunk, chunk_id=chunk_id, segment_ids=[], lines=[], context_before=[], context_after=[])
    first = min(positions)
    last = max(positions)
    before_pool = [*chunk.context_before, *(line for _seg_id, line in indexed_lines[:first])]
    after_pool = [*(line for _seg_id, line in indexed_lines[last + 1 :]), *chunk.context_after]
    return replace(
        chunk,
        chunk_id=chunk_id,
        segment_ids=[seg_id for seg_id, _line in indexed_lines if seg_id in selected],
        lines=[line for seg_id, line in indexed_lines if seg_id in selected],
        context_before=before_pool[-_RECOVERY_CONTEXT_BEFORE_LINES:],
        context_after=after_pool[:_RECOVERY_CONTEXT_AFTER_LINES],
        asr_uncertain_ids=[seg_id for seg_id in chunk.asr_uncertain_ids if seg_id in selected],
        meta={**dict(chunk.meta or {}), "recovery_parent_chunk": chunk.chunk_id},
    )


def _split_chunk(chunk: Chunk) -> tuple[Chunk, Chunk]:
    midpoint = max(1, len(chunk.segment_ids) // 2)
    left_ids = chunk.segment_ids[:midpoint]
    right_ids = chunk.segment_ids[midpoint:]
    left_lines = chunk.lines[:midpoint]
    right_lines = chunk.lines[midpoint:]
    left = replace(
        chunk,
        chunk_id=f"{chunk.chunk_id}s0",
        segment_ids=left_ids,
        lines=left_lines,
        context_after=[*right_lines, *chunk.context_after],
        asr_uncertain_ids=[item for item in chunk.asr_uncertain_ids if item in left_ids],
        meta={
            **dict(chunk.meta or {}),
            "adaptive_split": "left",
            "adaptive_sibling_lines": len(right_lines),
            "adaptive_context_hint": "capacity_split",
        },
    )
    right = replace(
        chunk,
        chunk_id=f"{chunk.chunk_id}s1",
        segment_ids=right_ids,
        lines=right_lines,
        context_before=[*chunk.context_before, *left_lines],
        asr_uncertain_ids=[item for item in chunk.asr_uncertain_ids if item in right_ids],
        meta={
            **dict(chunk.meta or {}),
            "adaptive_split": "right",
            "adaptive_sibling_lines": len(left_lines),
            "adaptive_context_hint": "capacity_split",
        },
    )
    return left, right


def _route_providers(config: AppConfig) -> list:
    providers = []
    for route in [config.routing.primary] + list(config.routing.fallback):
        provider = config.providers.get(route.provider)
        if provider is not None:
            providers.append(
                replace(
                    provider,
                    capabilities=provider.capabilities_for_model(route.model),
                )
            )
    return providers


def _max_input_tokens_for_routes(config: AppConfig) -> int:
    providers = _route_providers(config)
    if providers and any(int(provider.capabilities.max_context_tokens or 0) <= 0 for provider in providers):
        return 0
    limits = [
        int(provider.capabilities.max_context_tokens)
        for provider in providers
        if int(provider.capabilities.max_context_tokens or 0) > 0
    ]
    if not limits:
        return 0
    safety = float(config.pipeline.translation.chunking.input_safety_ratio)
    safety = max(0.1, min(1.0, safety))
    return max(1, int(min(limits) * safety))


def _runtime_chunk_for_request(config: AppConfig, chunk: Chunk, memory_prompt: str) -> Chunk:
    max_input_tokens = _max_input_tokens_for_routes(config)
    prompt_overhead = translation_prompt_overhead_tokens(config)
    before, after, budget_meta = trim_context_for_budget(
        lines=chunk.lines,
        context_before=chunk.context_before,
        context_after=chunk.context_after,
        max_input_tokens=max_input_tokens,
        prompt_overhead_tokens=prompt_overhead,
        memory_prompt=memory_prompt,
    )
    if before == chunk.context_before and after == chunk.context_after and not chunk.meta:
        return chunk
    meta = dict(chunk.meta or {})
    meta.update(
        {
            "runtime_estimated_input_tokens": budget_meta["estimated_input_tokens"],
            "runtime_max_input_tokens": max_input_tokens,
            "runtime_context_before_lines": len(before),
            "runtime_context_after_lines": len(after),
            "runtime_dropped_context_before_lines": len(chunk.context_before) - len(before),
            "runtime_dropped_context_after_lines": len(chunk.context_after) - len(after),
        }
    )
    return replace(chunk, context_before=before, context_after=after, meta=meta)


def _retryable_split_failure(exc: Exception) -> bool:
    if isinstance(exc, TranslationProtocolIncompleteError):
        return True
    text = str(exc)
    lowered = text.lower()
    return any(marker in lowered for marker in _HARD_CAPACITY_SPLIT_MARKERS)


def _chunk_completed(chunk: Chunk, done: set[str]) -> bool:
    if chunk.chunk_id in done:
        return True
    if len(chunk.segment_ids) <= 1:
        return False
    left, right = _split_chunk(chunk)
    return _chunk_completed(left, done) and _chunk_completed(right, done)


def _source_chunk_completed_count(chunks: list[Chunk], done: set[str]) -> int:
    return sum(1 for chunk in chunks if _chunk_completed(chunk, done))


def _adaptive_chunk_by_id(chunks: list[Chunk], chunk_id: str) -> Chunk | None:
    for chunk in sorted(chunks, key=lambda item: len(item.chunk_id), reverse=True):
        if chunk.chunk_id == chunk_id:
            return chunk
        if not chunk_id.startswith(f"{chunk.chunk_id}s"):
            continue
        suffix = chunk_id[len(chunk.chunk_id) :]
        current = chunk
        while suffix:
            if len(suffix) < 2 or suffix[0] != "s" or suffix[1] not in {"0", "1"}:
                current = None
                break
            if len(current.segment_ids) <= 1:
                current = None
                break
            left, right = _split_chunk(current)
            current = left if suffix[1] == "0" else right
            suffix = suffix[2:]
        if current is not None and current.chunk_id == chunk_id:
            return current
    return None


def _has_completed_child(chunk: Chunk, done: set[str]) -> bool:
    prefix = f"{chunk.chunk_id}s"
    return any(item.startswith(prefix) for item in done)


def _rows_to_dicts(rows: list[ParsedTranslationRow]) -> list[dict]:
    return [{"id": row.id, "text_tgt": row.text_tgt} for row in sorted(rows, key=lambda item: item.id)]


def _replace_row(rows: list[ParsedTranslationRow], repaired: ParsedTranslationRow) -> list[ParsedTranslationRow]:
    out: list[ParsedTranslationRow] = []
    replaced = False
    for row in rows:
        if row.id == repaired.id:
            if not replaced:
                out.append(repaired)
                replaced = True
            continue
        out.append(row)
    if not replaced:
        out.append(repaired)
    return sorted(out, key=lambda item: item.id)


def _base_request(
    *,
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    model: str,
    memory_prompt: str = "",
    protocol_recovery_hint: str = "",
    adaptive_context_hint: str = "",
) -> NormalizedRequest:
    return NormalizedRequest(
        model=model,
        lines=chunk.lines,
        source_lang=source_lang,
        target_lang=target_lang,
        context_before=chunk.context_before,
        context_after=chunk.context_after,
        asr_uncertain_ids=chunk.asr_uncertain_ids,
        include_asr_uncertainty_hints=config.pipeline.translation.asr_uncertainty_hints.enabled,
        style_prompt=config.pipeline.translation.style_prompt,
        memory_prompt=memory_prompt,
        system_prompt=config.pipeline.translation.system_prompt,
        protocol_recovery_hint=protocol_recovery_hint,
        adaptive_context_hint=adaptive_context_hint,
    )


def _adaptive_context_hint(chunk: Chunk) -> str:
    if dict(chunk.meta or {}).get("adaptive_context_hint") != "capacity_split":
        return ""
    sibling_lines = int(dict(chunk.meta or {}).get("adaptive_sibling_lines") or 0)
    return (
        "This is a capacity retry for one part of a larger subtitle chunk. "
        f"The adjacent {sibling_lines} sibling line(s) in CONTEXT_BEFORE or CONTEXT_AFTER are context only; "
        "translate only TRANSLATE_ONLY ids and do not output context ids."
    )


def _validate(
    config: AppConfig,
    chunk: Chunk,
    *,
    numbered_lines: list[str],
    raw_text: str,
) -> TranslationValidationResult:
    return validate_translation_response(
        chunk=chunk,
        numbered_lines=numbered_lines,
        raw_text=raw_text,
        refusal_detection_enabled=config.pipeline.translation.refusal_detection.enabled,
    )


def _provider_response_incomplete_reason(provider_meta: dict[str, Any] | None) -> str:
    meta = dict(provider_meta or {})
    status = str(meta.get("response_status") or "").strip().lower()
    details = meta.get("incomplete_details") if isinstance(meta.get("incomplete_details"), dict) else {}
    detail_reason = str(details.get("reason") or "").strip()
    finish_reason = str(meta.get("finish_reason") or "").strip()
    normalized_finish = finish_reason.lower().replace("-", "_")
    if status == "incomplete":
        return detail_reason or finish_reason or "provider reported an incomplete response"
    if normalized_finish in {"length", "max_tokens", "max_output_tokens", "max_tokens_reached"}:
        return finish_reason
    return ""


def _raise_for_failed_provider_response(provider_meta: dict[str, Any] | None) -> None:
    status = str(dict(provider_meta or {}).get("response_status") or "").strip().lower()
    if status == "failed":
        raise RuntimeError("provider reported a failed response")


def _completion_issue_ids(validation: TranslationValidationResult) -> list[int]:
    return sorted(
        {
            int(issue.segment_id)
            for issue in validation.errors
            if issue.code in _COMPLETION_ERROR_CODES and issue.segment_id is not None
        }
    )


def _trailing_completion_ids(chunk: Chunk, validation: TranslationValidationResult) -> list[int]:
    completion_ids = set(_completion_issue_ids(validation))
    trailing: list[int] = []
    for seg_id in reversed(chunk.segment_ids):
        if seg_id not in completion_ids:
            break
        trailing.append(seg_id)
    trailing.reverse()
    return trailing


def _completion_requires_capacity_split(chunk: Chunk, validation: TranslationValidationResult) -> bool:
    completion_ids = _completion_issue_ids(validation)
    if len(completion_ids) > _MAX_INDIVIDUAL_ROW_REPAIRS:
        return True
    if len(completion_ids) < 5:
        return False
    return len(completion_ids) / max(len(chunk.segment_ids), 1) >= 0.2


def _batched_recovery_ids(
    chunk: Chunk,
    validation: TranslationValidationResult,
    *,
    response_incomplete: bool,
) -> list[int]:
    trailing = _trailing_completion_ids(chunk, validation)
    if len(trailing) < _MIN_TRAILING_BATCH_RECOVERY:
        return []
    start_index = chunk.segment_ids.index(trailing[0])
    recovery_ids = set(trailing)
    repairable_ids = {
        int(issue.segment_id)
        for issue in validation.repairable_errors
        if issue.segment_id is not None
    }
    boundary_index = max(0, start_index - 1)
    for seg_id in chunk.segment_ids[boundary_index:]:
        if seg_id in repairable_ids:
            recovery_ids.add(seg_id)
    if response_incomplete and start_index > 0:
        recovery_ids.add(chunk.segment_ids[start_index - 1])
    return [seg_id for seg_id in chunk.segment_ids if seg_id in recovery_ids]


def _batch_recovery_hint(validation: TranslationValidationResult, segment_ids: list[int]) -> str:
    return "\n".join(
        [
            _protocol_recovery_hint(validation),
            "- This request contains only the unfinished tail of the previous response and its boundary row.",
            "- Translate every TRANSLATE_ONLY id in this smaller recovery batch; do not continue from any other id.",
            "- Recovery ids: " + ", ".join(str(seg_id) for seg_id in segment_ids) + ".",
        ]
    )


def _recover_rows_in_batches(
    *,
    config: AppConfig,
    client: Any,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    provider_name: str,
    model: str,
    validation: TranslationValidationResult,
    recovery_ids: list[int],
    memory_prompt: str,
    progress_callback: ProgressCallback | None,
) -> tuple[TranslationValidationResult, list[dict], list[dict[str, Any]]]:
    provider = config.providers[provider_name]
    model_capabilities = provider.capabilities_for_model(model)
    max_batch_lines = max(
        1,
        min(
            _MAX_BATCH_RECOVERY_LINES,
            int(model_capabilities.max_batch_lines),
        ),
    )
    rows = list(validation.rows)
    artifacts: list[dict] = []
    usages: list[dict[str, Any]] = []
    for batch_index, offset in enumerate(range(0, len(recovery_ids), max_batch_lines)):
        batch_ids = recovery_ids[offset : offset + max_batch_lines]
        recovery_chunk = _contextual_subchunk(
            chunk,
            batch_ids,
            chunk_id=f"{chunk.chunk_id}r{batch_index:03d}",
        )
        _notify_progress(
            progress_callback,
            mode="batch_recovery",
            request_state="started",
            chunk_id=chunk.chunk_id,
            recovery_chunk_id=recovery_chunk.chunk_id,
            segment_ids=batch_ids,
            provider=provider_name,
            model=model,
            batch_index=batch_index + 1,
            batch_total=(len(recovery_ids) + max_batch_lines - 1) // max_batch_lines,
        )
        req = _base_request(
            config=config,
            chunk=_runtime_chunk_for_request(config, recovery_chunk, memory_prompt),
            source_lang=source_lang,
            target_lang=target_lang,
            model=model,
            memory_prompt=memory_prompt,
            protocol_recovery_hint=_batch_recovery_hint(validation, batch_ids),
        )
        response = client.translate_request(req)
        _raise_for_failed_provider_response(response.provider_meta)
        incomplete_reason = _provider_response_incomplete_reason(response.provider_meta)
        recovery_validation = _validate(
            config,
            recovery_chunk,
            numbered_lines=response.numbered_lines,
            raw_text=response.raw_text,
        )
        if incomplete_reason or recovery_validation.has_chunk_errors or _completion_requires_capacity_split(
            recovery_chunk, recovery_validation
        ):
            issue_text = "; ".join(issue.message for issue in recovery_validation.errors)
            reason = incomplete_reason or issue_text or "batch recovery remained incomplete"
            raise TranslationProtocolIncompleteError(
                f"translation protocol incomplete during batch recovery for {recovery_chunk.chunk_id}: {reason}"
            )
        for recovered in recovery_validation.rows:
            rows = _replace_row(rows, recovered)
        if response.usage:
            usages.append(dict(response.usage))
        artifacts.append(
            {
                "chunk_id": chunk.chunk_id,
                "recovery_chunk_id": recovery_chunk.chunk_id,
                "mode": "batch_recovery",
                "ids": list(batch_ids),
                "line_count": len(batch_ids),
                "provider": provider_name,
                "model": model,
                "provider_meta": dict(response.provider_meta or {}),
                "usage": dict(response.usage or {}),
                "validation": validation_to_json(recovery_validation),
            }
        )
    repaired_lines = [f"[{row.id}] {row.text_tgt}" for row in rows]
    merged_validation = _validate(
        config,
        chunk,
        numbered_lines=repaired_lines,
        raw_text="\n".join(repaired_lines),
    )
    return merged_validation, artifacts, usages


def _repair_row(
    *,
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    provider_name: str,
    model: str,
    issue: TranslationValidationIssue,
    current_rows: list[ParsedTranslationRow],
    memory_prompt: str = "",
    progress_callback: ProgressCallback | None = None,
) -> tuple[ParsedTranslationRow, list[dict]]:
    provider = config.providers[provider_name]
    client = build_provider_client(provider)
    source_by_id = _chunk_source_by_id(chunk)
    seg_id = int(issue.segment_id or 0)
    bad_translation = next((row.text_tgt for row in current_rows if row.id == seg_id), "")
    repair_chunk = _contextual_subchunk(chunk, [seg_id], chunk_id=f"{chunk.chunk_id}p{seg_id}")
    if not repair_chunk.lines:
        repair_chunk = replace(
            chunk,
            segment_ids=[seg_id],
            lines=[f"[{seg_id}] {source_by_id.get(seg_id, '')}".rstrip()],
        )
    errors: list[dict] = []
    max_attempts = max(1, config.pipeline.translation.repair.max_attempts)
    for attempt in range(max_attempts):
        try:
            _notify_progress(
                progress_callback,
                mode="repair",
                request_state="started",
                chunk_id=chunk.chunk_id,
                segment_id=seg_id,
                provider=provider_name,
                model=model,
                attempt=attempt + 1,
                max_attempts=max_attempts,
            )
            req = NormalizedRequest(
                model=model,
                lines=repair_chunk.lines,
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=repair_chunk.context_before,
                context_after=repair_chunk.context_after,
                asr_uncertain_ids=[seg_id] if seg_id in chunk.asr_uncertain_ids else [],
                include_asr_uncertainty_hints=config.pipeline.translation.asr_uncertainty_hints.enabled,
                style_prompt=config.pipeline.translation.style_prompt,
                memory_prompt=memory_prompt,
                prompt_mode="repair",
                repair_reason=issue.message,
                bad_translation=bad_translation,
                system_prompt=config.pipeline.translation.system_prompt,
            )
            response = client.translate_request(req)
            validation = _validate(
                config,
                repair_chunk,
                numbered_lines=response.numbered_lines,
                raw_text=response.raw_text,
            )
            if not validation.errors and len(validation.rows) == 1:
                return validation.rows[0], errors
            errors.append(
                {
                    "provider": provider_name,
                    "model": model,
                    "attempt": attempt + 1,
                    "error_type": "mismatch_lines",
                    "message": "; ".join(item.message for item in validation.errors) or "repair validation failed",
                }
            )
        except Exception as exc:  # pragma: no cover - runtime network branches
            errors.append(
                {
                    "provider": provider_name,
                    "model": model,
                    "attempt": attempt + 1,
                    "error_type": classify_error(exc),
                    "message": str(exc),
                }
            )
        if attempt + 1 < max_attempts:
            time.sleep(min(2**attempt, 5))
    raise RuntimeError(f"row repair failed for id {seg_id}: {errors}")


def _repair_rows(
    *,
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    provider_name: str,
    model: str,
    validation: TranslationValidationResult,
    memory_prompt: str = "",
    progress_callback: ProgressCallback | None = None,
) -> tuple[TranslationValidationResult, list[dict], list[dict]]:
    if not config.pipeline.translation.repair.enabled or not validation.repairable_errors:
        return validation, [], []
    unique_issues: list[TranslationValidationIssue] = []
    seen_ids: set[int] = set()
    for issue in validation.repairable_errors:
        seg_id = int(issue.segment_id or 0)
        if seg_id in seen_ids:
            continue
        seen_ids.add(seg_id)
        unique_issues.append(issue)
    if len(unique_issues) > _MAX_INDIVIDUAL_ROW_REPAIRS:
        raise TranslationProtocolIncompleteError(
            "translation protocol incomplete: refusing to amplify "
            f"{len(unique_issues)} row issues into individual repair requests"
        )
    rows = list(validation.rows)
    repair_artifacts: list[dict] = []
    repair_errors: list[dict] = []
    for issue in unique_issues:
        repaired, errors = _repair_row(
            config=config,
            chunk=chunk,
            source_lang=source_lang,
            target_lang=target_lang,
            provider_name=provider_name,
            model=model,
            issue=issue,
            current_rows=rows,
            memory_prompt=memory_prompt,
            progress_callback=progress_callback,
        )
        repair_errors.extend(errors)
        rows = _replace_row(rows, repaired)
        repair_artifacts.append(
            {
                "chunk_id": chunk.chunk_id,
                "id": repaired.id,
                "text_tgt": repaired.text_tgt,
                "reason": issue.message,
                "provider": provider_name,
                "model": model,
                "errors": errors,
            }
        )
    repaired_lines = [f"[{row.id}] {row.text_tgt}" for row in rows]
    repaired_validation = _validate(
        config,
        chunk,
        numbered_lines=repaired_lines,
        raw_text="\n".join(repaired_lines),
    )
    return repaired_validation, repair_artifacts, repair_errors


def _should_protocol_recover(validation: TranslationValidationResult) -> bool:
    if any(issue.code == "refusal_output" for issue in validation.errors):
        return False
    return any(issue.code in _PROTOCOL_RECOVERY_CODES for issue in validation.errors)


def _protocol_recovery_hint(validation: TranslationValidationResult) -> str:
    issue_codes = ", ".join(sorted({issue.code for issue in validation.errors})) or "validation_failed"
    missing_ids = [str(issue.segment_id) for issue in validation.errors if issue.code == "missing_id" and issue.segment_id]
    empty_ids = [str(issue.segment_id) for issue in validation.errors if issue.code == "empty_translation" and issue.segment_id]
    details: list[str] = [
        "Previous output failed subtitle protocol validation.",
        f"Issue codes: {issue_codes}.",
        "Retry the same translation task using the same source, context, memory, and style.",
        "Return every TRANSLATE_ONLY id exactly once, in numeric order.",
        "Do not output CONTEXT_BEFORE or CONTEXT_AFTER ids.",
        "Do not output Markdown, explanations, summaries, headings, blank translations, or extra text.",
    ]
    if missing_ids:
        details.append("Missing ids from previous output: " + ", ".join(missing_ids[:40]) + ".")
    if empty_ids:
        details.append("Empty ids from previous output: " + ", ".join(empty_ids[:40]) + ".")
    return "\n".join(f"- {item}" for item in details)


def translate_chunk(
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    memory_prompt: str = "",
    progress_callback: ProgressCallback | None = None,
) -> dict:
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    error_messages: list[dict] = []
    for route in route_candidates:
        provider = config.providers.get(route.provider)
        if not provider:
            error_messages.append(
                {
                    "provider": route.provider,
                    "model": route.model,
                    "error_type": "bad_schema",
                    "message": "provider not found",
                }
            )
            continue
        client = build_provider_client(provider)
        retries = max(1, provider.limits.retry)
        protocol_recovery_used = False
        for attempt in range(retries):
            try:
                request_chunk = _runtime_chunk_for_request(config, chunk, memory_prompt)
                response = None
                validation = None
                protocol_recovered = False
                protocol_hint = ""
                batch_recovery_artifacts: list[dict] = []
                batch_recovery_usages: list[dict[str, Any]] = []
                for protocol_attempt in range(2):
                    _notify_progress(
                        progress_callback,
                        mode="protocol_recovery" if protocol_attempt else "translate",
                        request_state="started",
                        chunk_id=request_chunk.chunk_id,
                        segment_ids=request_chunk.segment_ids,
                        provider=route.provider,
                        model=route.model,
                        attempt=attempt + 1,
                        max_attempts=retries,
                        memory_entries=_memory_prompt_entry_count(memory_prompt),
                    )
                    req = _base_request(
                        config=config,
                        chunk=request_chunk,
                        source_lang=source_lang,
                        target_lang=target_lang,
                        model=route.model,
                        memory_prompt=memory_prompt,
                        protocol_recovery_hint=protocol_hint,
                        adaptive_context_hint=_adaptive_context_hint(request_chunk),
                    )
                    response = client.translate_request(req)
                    _raise_for_failed_provider_response(response.provider_meta)
                    validation = _validate(
                        config,
                        request_chunk,
                        numbered_lines=response.numbered_lines,
                        raw_text=response.raw_text,
                    )
                    incomplete_reason = _provider_response_incomplete_reason(response.provider_meta)
                    recovery_ids = (
                        []
                        if validation.has_chunk_errors
                        else _batched_recovery_ids(
                            request_chunk,
                            validation,
                            response_incomplete=bool(incomplete_reason),
                        )
                    )
                    if recovery_ids:
                        validation, recovered_artifacts, recovered_usages = _recover_rows_in_batches(
                            config=config,
                            client=client,
                            chunk=request_chunk,
                            source_lang=source_lang,
                            target_lang=target_lang,
                            provider_name=route.provider,
                            model=route.model,
                            validation=validation,
                            recovery_ids=recovery_ids,
                            memory_prompt=memory_prompt,
                            progress_callback=progress_callback,
                        )
                        batch_recovery_artifacts.extend(recovered_artifacts)
                        batch_recovery_usages.extend(recovered_usages)
                        protocol_recovered = True
                        break
                    if incomplete_reason:
                        raise TranslationProtocolIncompleteError(
                            "translation protocol incomplete: provider ended the response early "
                            f"({incomplete_reason})"
                        )
                    if _completion_requires_capacity_split(request_chunk, validation):
                        raise TranslationProtocolIncompleteError(
                            "translation protocol incomplete: too many missing or empty translation rows "
                            f"({len(_completion_issue_ids(validation))}/{len(request_chunk.segment_ids)})"
                        )
                    if protocol_attempt == 0 and not protocol_recovery_used and _should_protocol_recover(validation):
                        protocol_hint = _protocol_recovery_hint(validation)
                        protocol_recovery_used = True
                        protocol_recovered = True
                        continue
                    break
                if validation is None or response is None:
                    raise RuntimeError("translation did not return a response")
                if validation.has_chunk_errors:
                    raise RuntimeError("; ".join(issue.message for issue in validation.errors))
                validation, repairs, repair_errors = _repair_rows(
                    config=config,
                    chunk=request_chunk,
                    source_lang=source_lang,
                    target_lang=target_lang,
                    provider_name=route.provider,
                    model=route.model,
                    validation=validation,
                    memory_prompt=memory_prompt,
                    progress_callback=progress_callback,
                )
                repairs = [*batch_recovery_artifacts, *repairs]
                error_messages.extend(repair_errors)
                if validation.errors:
                    raise RuntimeError("; ".join(issue.message for issue in validation.errors))
                provider_meta = dict(response.provider_meta or {})
                model_config = provider.model_config(route.model)
                effective_capabilities = provider.capabilities_for_model(route.model)
                if batch_recovery_artifacts:
                    provider_meta["batch_recovery_requests"] = len(batch_recovery_artifacts)
                    provider_meta["batch_recovered_rows"] = sum(
                        int(item.get("line_count") or 0) for item in batch_recovery_artifacts
                    )
                _notify_progress(
                    progress_callback,
                    mode="translate",
                    request_state="completed",
                    chunk_id=request_chunk.chunk_id,
                    segment_ids=request_chunk.segment_ids,
                    provider=route.provider,
                    model=route.model,
                    attempt=attempt + 1,
                    max_attempts=retries,
                    memory_entries=_memory_prompt_entry_count(memory_prompt),
                    provider_meta=provider_meta,
                )
                return {
                    "chunk_id": request_chunk.chunk_id,
                    "provider": route.provider,
                    "model": route.model,
                    "compat_mode": provider.compat_mode,
                    "base_url": provider.base_url,
                    "transport": provider_meta.get("transport", ""),
                    "http_version": provider_meta.get("http_version", ""),
                    "streaming": bool(provider_meta.get("streaming", False)),
                    "provider_meta": provider_meta,
                    "usage": dict(response.usage or {}),
                    "raw_text": response.raw_text,
                    "raw_text_chars": len(response.raw_text or ""),
                    "request": {
                        "source_lang": source_lang,
                        "target_lang": target_lang,
                        "line_count": len(request_chunk.lines),
                        "context_before_lines": len(request_chunk.context_before),
                        "context_after_lines": len(request_chunk.context_after),
                        "memory_entries": _memory_prompt_entry_count(memory_prompt),
                        "memory_prompt_chars": len(memory_prompt or ""),
                        "protocol_recovered": protocol_recovered,
                        "batch_recovery_requests": len(batch_recovery_artifacts),
                        "batch_recovery_usages": batch_recovery_usages,
                        "model_config": {
                            "max_batch_lines": int(effective_capabilities.max_batch_lines or 0),
                            "max_context_tokens": int(effective_capabilities.max_context_tokens or 0),
                            "max_output_tokens": int(effective_capabilities.max_output_tokens or 0),
                            "recommended_output_tokens": int(
                                effective_capabilities.recommended_output_tokens or 0
                            ),
                            "reasoning_effort": str(model_config.reasoning_effort or ""),
                        },
                        "chunk_meta": dict(request_chunk.meta or {}),
                    },
                    "rows": _rows_to_dicts(validation.rows),
                    "validation": validation_to_json(validation),
                    "repairs": repairs,
                    "errors": error_messages,
                }
            except Exception as exc:  # pragma: no cover - runtime network branches
                if isinstance(exc, TranslationProtocolIncompleteError):
                    raise
                error_messages.append(
                    {
                        "provider": route.provider,
                        "model": route.model,
                        "attempt": attempt + 1,
                        "error_type": classify_error(exc),
                        "message": str(exc),
                    }
                )
                if attempt + 1 < retries:
                    time.sleep(min(2**attempt, 5))
    raise RuntimeError(f"All translation routes failed: {error_messages}")


def translate_chunk_adaptive(
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
    memory_prompt: str = "",
    progress_callback: ProgressCallback | None = None,
    already_done: set[str] | None = None,
    *,
    parent_chunk_id: str | None = None,
    memory_prompt_builder: Callable[[Chunk], str] | None = None,
) -> list[dict]:
    already_done = already_done or set()
    if _chunk_completed(chunk, already_done):
        return []
    min_lines = max(1, int(config.pipeline.translation.batching.min_chunk_lines))
    parent_id = parent_chunk_id or chunk.chunk_id
    if _has_completed_child(chunk, already_done) and len(chunk.segment_ids) > 1:
        left, right = _split_chunk(chunk)
        results: list[dict] = []
        for child in (left, right):
            try:
                results.extend(
                    translate_chunk_adaptive(
                        config,
                        child,
                        source_lang,
                        target_lang,
                        memory_prompt=memory_prompt,
                        progress_callback=progress_callback,
                        already_done=already_done,
                        parent_chunk_id=parent_id,
                        memory_prompt_builder=memory_prompt_builder,
                    )
                )
            except AdaptiveTranslationError as exc:
                results.extend(exc.partial_results)
                raise AdaptiveTranslationError(str(exc), results) from exc
        return results
    try:
        chunk_memory_prompt = memory_prompt_builder(chunk) if memory_prompt_builder is not None else memory_prompt
        result = _call_translate_chunk(
            config,
            chunk,
            source_lang,
            target_lang,
            chunk_memory_prompt,
            progress_callback,
        )
        if parent_id != chunk.chunk_id:
            result["adaptive_parent_chunk"] = parent_id
        return [result]
    except Exception as exc:
        if (
            config.pipeline.translation.batching.mode != "adaptive"
            or len(chunk.segment_ids) <= min_lines
            or not _retryable_split_failure(exc)
        ):
            raise
        left, right = _split_chunk(chunk)
        _notify_progress(
            progress_callback,
            mode="adaptive_split",
            request_state="activity",
            chunk_id=chunk.chunk_id,
            chunk_ids=[left.chunk_id, right.chunk_id],
            adaptive_parent_chunk=parent_id,
            adaptive_child_chunks=[left.chunk_id, right.chunk_id],
        )
        results: list[dict] = []
        for child in (left, right):
            try:
                results.extend(
                    translate_chunk_adaptive(
                        config,
                        child,
                        source_lang,
                        target_lang,
                        memory_prompt=memory_prompt,
                        progress_callback=progress_callback,
                        already_done=already_done,
                        parent_chunk_id=parent_id,
                        memory_prompt_builder=memory_prompt_builder,
                    )
                )
            except Exception as child_exc:
                if isinstance(child_exc, AdaptiveTranslationError):
                    results.extend(child_exc.partial_results)
                raise AdaptiveTranslationError(str(child_exc), results) from child_exc
        return results


def iter_translate_all_chunks(
    config: AppConfig,
    chunks: list[Chunk],
    source_lang: str,
    target_lang: str,
    already_done: set[str] | None = None,
    memory_dir: Path | None = None,
    progress_callback: ProgressCallback | None = None,
):
    already_done = already_done or set()
    todo = [chunk for chunk in chunks if not _chunk_completed(chunk, already_done)]
    if not todo:
        return
    if translates_with_memory(config.pipeline.memory) and memory_dir is not None:
        yield from _iter_translate_all_chunks_with_memory(
            config,
            todo,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_dir=memory_dir,
            progress_callback=progress_callback,
            already_done=already_done,
        )
        return
    if config.pipeline.translation.batching.mode == "adaptive" and max(1, config.pipeline.default_concurrency) == 1:
        yield from _iter_translate_all_chunks_adaptive_serial(
            config,
            todo,
            source_lang=source_lang,
            target_lang=target_lang,
            already_done=already_done,
            progress_callback=progress_callback,
        )
        return
    max_workers = max(1, config.pipeline.default_concurrency)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            _submit_translate_chunk(pool, config, chunk, source_lang, target_lang, "", progress_callback, already_done): chunk
            for chunk in todo
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                result = future.result()
            except AdaptiveTranslationError as exc:
                for item in exc.partial_results:
                    yield item
                raise RuntimeError(str(exc)) from exc
            if isinstance(result, list):
                for item in result:
                    yield item
            else:
                yield result


def _iter_translate_all_chunks_adaptive_serial(
    config: AppConfig,
    chunks: list[Chunk],
    *,
    source_lang: str,
    target_lang: str,
    already_done: set[str],
    progress_callback: ProgressCallback | None = None,
):
    for chunk in chunks:
        if _chunk_completed(chunk, already_done):
            continue
        try:
            results = translate_chunk_adaptive(
                config,
                chunk,
                source_lang,
                target_lang,
                progress_callback=progress_callback,
                already_done=already_done,
            )
        except AdaptiveTranslationError as exc:
            for item in exc.partial_results:
                already_done.add(str(item.get("chunk_id")))
                yield item
            raise RuntimeError(str(exc)) from exc
        for result in results:
            already_done.add(str(result.get("chunk_id")))
            yield result


def _iter_translate_window(
    config: AppConfig,
    window: list[Chunk],
    *,
    source_lang: str,
    target_lang: str,
    memory_store: MemoryStore,
    progress_callback: ProgressCallback | None = None,
    already_done: set[str] | None = None,
):
    document = memory_store.load_effective(effective_memory_sources(config.pipeline.memory))

    def memory_prompt_for(chunk: Chunk) -> str:
        selected = select_memory_entries(document, chunk, config.pipeline.memory.inject)
        return build_memory_prompt(selected, config.pipeline.memory.inject)

    for chunk in window:
        try:
            result = _call_translate_chunk_or_adaptive(
                config,
                chunk,
                source_lang,
                target_lang,
                memory_prompt_for(chunk),
                progress_callback,
                already_done,
                memory_prompt_for,
            )
        except AdaptiveTranslationError as exc:
            for item in exc.partial_results:
                yield item
            raise RuntimeError(str(exc)) from exc
        result_items = result if isinstance(result, list) else [result]
        for item in result_items:
            yield item


def _iter_translate_all_chunks_with_static_memory(
    config: AppConfig,
    chunks: list[Chunk],
    *,
    source_lang: str,
    target_lang: str,
    memory_store: MemoryStore,
    progress_callback: ProgressCallback | None = None,
    already_done: set[str] | None = None,
):
    document = memory_store.load_effective(effective_memory_sources(config.pipeline.memory))

    def memory_prompt_for(chunk: Chunk) -> str:
        selected = select_memory_entries(document, chunk, config.pipeline.memory.inject)
        return build_memory_prompt(selected, config.pipeline.memory.inject)

    max_workers = max(1, config.pipeline.default_concurrency)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            _submit_translate_chunk(
                pool,
                config,
                chunk,
                source_lang,
                target_lang,
                memory_prompt_for(chunk),
                progress_callback,
                already_done,
                memory_prompt_for,
            ): chunk
            for chunk in chunks
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future_result = future.result()
            except AdaptiveTranslationError as exc:
                for item in exc.partial_results:
                    yield item
                raise RuntimeError(str(exc)) from exc
            result_items = future_result if isinstance(future_result, list) else [future_result]
            for result in result_items:
                yield result


def _uses_dynamic_memory_updates(config: AppConfig) -> bool:
    return dynamic_updates_enabled(config.pipeline.memory)


def _update_memory_after_window(
    config: AppConfig,
    window: list[Chunk],
    results: list[dict],
    *,
    source_lang: str,
    target_lang: str,
    memory_store: MemoryStore,
    progress_callback: ProgressCallback | None = None,
) -> None:
    if not results:
        return
    if not dynamic_updates_enabled(config.pipeline.memory):
        return
    chunks_by_id = {chunk.chunk_id: chunk for chunk in window}
    successful_window: list[Chunk] = []
    for result in results:
        chunk_id = str(result.get("chunk_id") or "")
        chunk = chunks_by_id.get(chunk_id)
        if chunk is not None:
            successful_window.append(chunk)
            continue
        rows = result.get("rows") or []
        if rows:
            lines = [f"[{item.get('id')}]" for item in rows if isinstance(item, dict)]
            successful_window.append(
                Chunk(
                    chunk_id=chunk_id,
                    segment_ids=[int(item.get("id")) for item in rows if isinstance(item, dict) and item.get("id") is not None],
                    lines=lines,
                )
            )
    if not successful_window:
        return
    patch_kwargs: dict[str, Any] = {"source_lang": source_lang, "target_lang": target_lang}
    if _generate_memory_patch_accepts_progress_callback():
        patch_kwargs["progress_callback"] = progress_callback
    patch, payload = generate_memory_patch(config, successful_window, results, **patch_kwargs)
    if payload is not None:
        memory_store.append_patch(payload)
    if patch is not None:
        document = memory_store.load_runtime()
        document, _conflicts = merge_patch(
            document,
            patch,
            store=memory_store,
            protected_entries=memory_store.load_selected_entries(),
            auto_confirm_high_confidence=config.pipeline.memory.merge.auto_confirm_high_confidence,
        )
        memory_store.save(document)


def _iter_translate_all_chunks_with_memory(
    config: AppConfig,
    chunks: list[Chunk],
    *,
    source_lang: str,
    target_lang: str,
    memory_dir: Path,
    progress_callback: ProgressCallback | None = None,
    already_done: set[str] | None = None,
):
    memory_store = MemoryStore(memory_dir)
    already_done = already_done or set()
    memory_store.ensure_runtime_document()
    if not _uses_dynamic_memory_updates(config):
        yield from _iter_translate_all_chunks_with_static_memory(
            config,
            chunks,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_store=memory_store,
            progress_callback=progress_callback,
            already_done=already_done,
        )
        return
    window_size = max(1, int(config.pipeline.memory.patch.window_chunks))
    snapshot_index = 0
    for start in range(0, len(chunks), window_size):
        window = chunks[start : start + window_size]
        patch_chunks: list[Chunk] = []
        patch_results: list[dict] = []
        def commit_patch_window() -> None:
            nonlocal snapshot_index
            if not patch_results:
                return
            _update_memory_after_window(
                config,
                patch_chunks,
                patch_results,
                source_lang=source_lang,
                target_lang=target_lang,
                memory_store=memory_store,
                progress_callback=progress_callback,
            )
            snapshot_index += 1
            memory_store.write_snapshot(memory_store.load_runtime(), snapshot_index)

        try:
            for result in _iter_translate_window(
                config,
                window,
                source_lang=source_lang,
                target_lang=target_lang,
                memory_store=memory_store,
                progress_callback=progress_callback,
                already_done=already_done,
            ):
                matching_chunk = next((chunk for chunk in window if chunk.chunk_id == result.get("chunk_id")), None)
                if matching_chunk is not None:
                    patch_chunks.append(matching_chunk)
                else:
                    rows = result.get("rows") or []
                    patch_chunks.append(
                        Chunk(
                            chunk_id=str(result.get("chunk_id") or ""),
                            segment_ids=[
                                int(item.get("id"))
                                for item in rows
                                if isinstance(item, dict) and item.get("id") is not None
                            ],
                            lines=[
                                f"[{item.get('id')}]"
                                for item in rows
                                if isinstance(item, dict) and item.get("id") is not None
                            ],
                        )
                    )
                patch_results.append(result)
                yield result
        except Exception:
            commit_patch_window()
            raise
        commit_patch_window()


def translate_all_chunks(
    config: AppConfig,
    chunks: list[Chunk],
    source_lang: str,
    target_lang: str,
    already_done: set[str] | None = None,
    memory_dir: Path | None = None,
    progress_callback: ProgressCallback | None = None,
) -> list[dict]:
    return list(
        iter_translate_all_chunks(
            config,
            chunks,
            source_lang=source_lang,
            target_lang=target_lang,
            already_done=already_done,
            memory_dir=memory_dir,
            progress_callback=progress_callback,
        )
    )
