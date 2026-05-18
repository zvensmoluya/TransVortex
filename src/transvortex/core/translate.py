from __future__ import annotations

import concurrent.futures
import inspect
import time
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment
from ..memory.injector import build_memory_prompt
from ..memory.merger import merge_patch
from ..memory.patcher import generate_memory_patch
from ..memory.selector import select_memory_entries
from ..memory.store import MemoryStore
from ..providers import build_provider_client, classify_error
from .translation_validation import (
    ParsedTranslationRow,
    TranslationValidationIssue,
    TranslationValidationResult,
    validate_translation_response,
    validation_to_json,
)


ProgressCallback = Callable[[dict[str, Any]], None]


@dataclass
class AdaptiveBatchState:
    target_lines: int
    original_lines: int
    min_lines: int
    grow_after_successes: int
    successes: int = 0

    def split(self) -> None:
        next_target = max(self.min_lines, max(1, self.target_lines // 2))
        if next_target == self.target_lines and self.target_lines > self.min_lines:
            next_target = self.min_lines
        self.target_lines = next_target
        self.successes = 0

    def success(self) -> None:
        if self.target_lines >= self.original_lines:
            return
        self.successes += 1
        if self.successes >= self.grow_after_successes:
            self.target_lines = min(self.original_lines, max(self.target_lines + 1, self.target_lines * 2))
            self.successes = 0


class AdaptiveTranslationError(RuntimeError):
    def __init__(self, message: str, partial_results: list[dict] | None = None) -> None:
        super().__init__(message)
        self.partial_results = partial_results or []


def _notify_progress(progress_callback: ProgressCallback | None, **payload: Any) -> None:
    if progress_callback is None:
        return
    try:
        progress_callback(payload)
    except Exception:
        pass


_RETRYABLE_SPLIT_ERRORS = {
    "provider_timeout",
    "connect_timeout",
    "read_timeout",
    "write_timeout",
    "pool_timeout",
    "timeout",
    "gateway_timeout",
    "bad_gateway",
    "service_unavailable",
    "provider_server_error",
}


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
        context_after=right_lines + chunk.context_after,
        asr_uncertain_ids=[item for item in chunk.asr_uncertain_ids if item in left_ids],
    )
    right = replace(
        chunk,
        chunk_id=f"{chunk.chunk_id}s1",
        segment_ids=right_ids,
        lines=right_lines,
        context_before=chunk.context_before + left_lines,
        asr_uncertain_ids=[item for item in chunk.asr_uncertain_ids if item in right_ids],
    )
    return left, right


def _partition_chunk_to_target_lines(chunk: Chunk, target_lines: int) -> list[Chunk]:
    target_lines = max(1, target_lines)
    if len(chunk.segment_ids) <= target_lines:
        return [chunk]
    left, right = _split_chunk(chunk)
    return [
        *_partition_chunk_to_target_lines(left, target_lines),
        *_partition_chunk_to_target_lines(right, target_lines),
    ]


def _build_adaptive_batch_state(config: AppConfig) -> AdaptiveBatchState:
    configured_lines = max(1, int(config.pipeline.translation.chunk_lines))
    min_lines = max(1, int(config.pipeline.translation.batching.min_chunk_lines))
    return AdaptiveBatchState(
        target_lines=configured_lines,
        original_lines=configured_lines,
        min_lines=min_lines,
        grow_after_successes=max(1, int(config.pipeline.translation.batching.grow_after_successes)),
    )


def _retryable_split_failure(exc: Exception) -> bool:
    text = str(exc)
    return any(f"'error_type': '{item}'" in text or f'"error_type": "{item}"' in text or item in text for item in _RETRYABLE_SPLIT_ERRORS)


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
                context_before=chunk.context_before,
                context_after=chunk.context_after,
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
    rows = list(validation.rows)
    repair_artifacts: list[dict] = []
    repair_errors: list[dict] = []
    for issue in validation.repairable_errors:
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
        for attempt in range(retries):
            try:
                _notify_progress(
                    progress_callback,
                    mode="translate",
                    chunk_id=chunk.chunk_id,
                    segment_ids=chunk.segment_ids,
                    provider=route.provider,
                    model=route.model,
                    attempt=attempt + 1,
                    max_attempts=retries,
                    memory_entries=memory_prompt.count(" => "),
                )
                req = _base_request(
                    config=config,
                    chunk=chunk,
                    source_lang=source_lang,
                    target_lang=target_lang,
                    model=route.model,
                    memory_prompt=memory_prompt,
                )
                response = client.translate_request(req)
                validation = _validate(
                    config,
                    chunk,
                    numbered_lines=response.numbered_lines,
                    raw_text=response.raw_text,
                )
                if validation.has_chunk_errors:
                    raise RuntimeError("; ".join(issue.message for issue in validation.errors))
                validation, repairs, repair_errors = _repair_rows(
                    config=config,
                    chunk=chunk,
                    source_lang=source_lang,
                    target_lang=target_lang,
                    provider_name=route.provider,
                    model=route.model,
                    validation=validation,
                    memory_prompt=memory_prompt,
                    progress_callback=progress_callback,
                )
                error_messages.extend(repair_errors)
                if validation.errors:
                    raise RuntimeError("; ".join(issue.message for issue in validation.errors))
                provider_meta = dict(response.provider_meta or {})
                _notify_progress(
                    progress_callback,
                    mode="translate",
                    chunk_id=chunk.chunk_id,
                    segment_ids=chunk.segment_ids,
                    provider=route.provider,
                    model=route.model,
                    attempt=attempt + 1,
                    max_attempts=retries,
                    memory_entries=memory_prompt.count(" => "),
                    provider_meta=provider_meta,
                )
                return {
                    "chunk_id": chunk.chunk_id,
                    "provider": route.provider,
                    "model": route.model,
                    "compat_mode": provider.compat_mode,
                    "base_url": provider.base_url,
                    "transport": provider_meta.get("transport", ""),
                    "http_version": provider_meta.get("http_version", ""),
                    "streaming": bool(provider_meta.get("streaming", False)),
                    "provider_meta": provider_meta,
                    "rows": _rows_to_dicts(validation.rows),
                    "validation": validation_to_json(validation),
                    "repairs": repairs,
                    "errors": error_messages,
                }
            except Exception as exc:  # pragma: no cover - runtime network branches
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
                    )
                )
            except AdaptiveTranslationError as exc:
                results.extend(exc.partial_results)
                raise AdaptiveTranslationError(str(exc), results) from exc
        return results
    try:
        result = _call_translate_chunk(
            config,
            chunk,
            source_lang,
            target_lang,
            memory_prompt,
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
    if config.pipeline.memory.enabled and memory_dir is not None:
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
    state = _build_adaptive_batch_state(config)
    queue: deque[Chunk] = deque(chunks)
    while queue:
        chunk = queue.popleft()
        if _chunk_completed(chunk, already_done):
            continue
        partitions = _partition_chunk_to_target_lines(chunk, state.target_lines)
        if len(partitions) > 1:
            queue.extendleft(reversed(partitions))
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
                state.success()
                yield item
            state.split()
            raise RuntimeError(str(exc)) from exc
        except Exception:
            state.split()
            raise
        if len(results) > 1 or any(result.get("adaptive_parent_chunk") for result in results):
            state.split()
        for result in results:
            already_done.add(str(result.get("chunk_id")))
            state.success()
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
    document = memory_store.load_effective()
    chunk_memory_prompts = {}
    for chunk in window:
        selected = select_memory_entries(document, chunk, config.pipeline.memory.inject)
        chunk_memory_prompts[chunk.chunk_id] = build_memory_prompt(selected)
    max_workers = max(1, config.pipeline.default_concurrency)
    if config.pipeline.memory.mode in {"consistency_first", "dynamic_patch"}:
        max_workers = 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            _submit_translate_chunk(
                pool,
                config,
                chunk,
                source_lang,
                target_lang,
                chunk_memory_prompts.get(chunk.chunk_id, ""),
                progress_callback,
                already_done,
            ): chunk
            for chunk in window
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
    if config.pipeline.memory.patch.enabled and config.pipeline.memory.patch.after_each_window:
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
    window_size = max(1, config.pipeline.default_concurrency)
    if config.pipeline.memory.mode in {"consistency_first", "dynamic_patch"}:
        window_size = 1
    snapshot_index = 0
    patch_chunks: list[Chunk] = []
    patch_results: list[dict] = []
    patch_window_chunks = max(1, int(config.pipeline.memory.patch.window_chunks))
    try:
        for start in range(0, len(chunks), window_size):
            window = chunks[start : start + window_size]
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
                if len(patch_results) >= patch_window_chunks:
                    _update_memory_after_window(
                        config,
                        patch_chunks,
                        patch_results,
                        source_lang=source_lang,
                        target_lang=target_lang,
                        memory_store=memory_store,
                        progress_callback=progress_callback,
                    )
                    patch_chunks = []
                    patch_results = []
            snapshot_index += 1
            memory_store.write_snapshot(memory_store.load_runtime(), snapshot_index)
    finally:
        if patch_results:
            _update_memory_after_window(
                config,
                patch_chunks,
                patch_results,
                source_lang=source_lang,
                target_lang=target_lang,
                memory_store=memory_store,
                progress_callback=progress_callback,
            )


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
