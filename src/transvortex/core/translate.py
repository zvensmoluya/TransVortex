from __future__ import annotations

import concurrent.futures
import time
from dataclasses import replace
from pathlib import Path

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment
from ..memory.injector import build_memory_prompt
from ..memory.merger import merge_patch
from ..memory.patcher import generate_memory_patch
from ..memory.selector import select_memory_entries
from ..memory.store import MemoryStore
from ..providers import build_provider_client, classify_error
from ..providers.factory import TRANSLATION_SYSTEM_PROMPT
from .translation_validation import (
    ParsedTranslationRow,
    TranslationValidationIssue,
    TranslationValidationResult,
    validate_translation_response,
    validation_to_json,
)


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
        style_prompt=config.pipeline.translation.style_prompt,
        memory_prompt=memory_prompt,
        system_prompt=TRANSLATION_SYSTEM_PROMPT,
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
            req = NormalizedRequest(
                model=model,
                lines=repair_chunk.lines,
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=chunk.context_before,
                context_after=chunk.context_after,
                style_prompt=config.pipeline.translation.style_prompt,
                memory_prompt=memory_prompt,
                prompt_mode="repair",
                repair_reason=issue.message,
                bad_translation=bad_translation,
                system_prompt=TRANSLATION_SYSTEM_PROMPT,
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
                )
                error_messages.extend(repair_errors)
                if validation.errors:
                    raise RuntimeError("; ".join(issue.message for issue in validation.errors))
                return {
                    "chunk_id": chunk.chunk_id,
                    "provider": route.provider,
                    "model": route.model,
                    "compat_mode": provider.compat_mode,
                    "base_url": provider.base_url,
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


def iter_translate_all_chunks(
    config: AppConfig,
    chunks: list[Chunk],
    source_lang: str,
    target_lang: str,
    already_done: set[str] | None = None,
    memory_dir: Path | None = None,
):
    already_done = already_done or set()
    todo = [chunk for chunk in chunks if chunk.chunk_id not in already_done]
    if not todo:
        return
    if config.pipeline.memory.enabled and memory_dir is not None:
        yield from _iter_translate_all_chunks_with_memory(
            config,
            todo,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_dir=memory_dir,
        )
        return
    max_workers = max(1, config.pipeline.default_concurrency)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            pool.submit(translate_chunk, config, chunk, source_lang, target_lang): chunk
            for chunk in todo
        }
        for future in concurrent.futures.as_completed(futures):
            yield future.result()


def _iter_translate_window(
    config: AppConfig,
    window: list[Chunk],
    *,
    source_lang: str,
    target_lang: str,
    memory_store: MemoryStore,
):
    document = memory_store.load()
    chunk_memory_prompts = {}
    for chunk in window:
        selected = select_memory_entries(document, chunk, config.pipeline.memory.inject)
        chunk_memory_prompts[chunk.chunk_id] = build_memory_prompt(selected)
    max_workers = max(1, config.pipeline.default_concurrency)
    if config.pipeline.memory.mode == "consistency_first":
        max_workers = 1
    results: list[dict] = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = {
                pool.submit(
                    translate_chunk,
                    config,
                    chunk,
                    source_lang,
                    target_lang,
                    chunk_memory_prompts.get(chunk.chunk_id, ""),
                ): chunk
                for chunk in window
            }
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
                yield result
    finally:
        _update_memory_after_window(
            config,
            window,
            results,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_store=memory_store,
        )


def _update_memory_after_window(
    config: AppConfig,
    window: list[Chunk],
    results: list[dict],
    *,
    source_lang: str,
    target_lang: str,
    memory_store: MemoryStore,
) -> None:
    if not results:
        return
    if config.pipeline.memory.patch.enabled and config.pipeline.memory.patch.after_each_window:
        successful_chunk_ids = {str(result.get("chunk_id") or "") for result in results}
        successful_window = [chunk for chunk in window if chunk.chunk_id in successful_chunk_ids]
        if not successful_window:
            return
        patch, payload = generate_memory_patch(
            config,
            successful_window,
            results,
            source_lang=source_lang,
            target_lang=target_lang,
        )
        if payload is not None:
            memory_store.append_patch(payload)
        if patch is not None:
            document = memory_store.load()
            document, _conflicts = merge_patch(
                document,
                patch,
                store=memory_store,
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
):
    memory_store = MemoryStore(memory_dir)
    memory_store.ensure()
    window_size = max(1, config.pipeline.default_concurrency)
    if config.pipeline.memory.mode == "consistency_first":
        window_size = 1
    snapshot_index = 0
    for start in range(0, len(chunks), window_size):
        window = chunks[start : start + window_size]
        for result in _iter_translate_window(
            config,
            window,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_store=memory_store,
        ):
            yield result
        snapshot_index += 1
        memory_store.write_snapshot(memory_store.load(), snapshot_index)


def translate_all_chunks(
    config: AppConfig,
    chunks: list[Chunk],
    source_lang: str,
    target_lang: str,
    already_done: set[str] | None = None,
    memory_dir: Path | None = None,
) -> list[dict]:
    return list(
        iter_translate_all_chunks(
            config,
            chunks,
            source_lang=source_lang,
            target_lang=target_lang,
            already_done=already_done,
            memory_dir=memory_dir,
        )
    )
