from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment
from ..providers import build_provider_client, classify_error
from ..utils import read_json, write_json
from .bootstrap_input import build_bootstrap_input_view, render_bootstrap_input_text, write_bootstrap_input_artifacts
from .merger import merge_patch, patch_from_payload
from .patcher import json_from_memory_text
from .store import MemoryStore


ProgressCallback = Callable[[dict[str, Any]], None]


def _notify_progress(progress_callback: ProgressCallback | None, **payload: Any) -> None:
    if progress_callback is None:
        return
    try:
        progress_callback(payload)
    except Exception:
        pass


def _numbered_source_lines(segments: list[Segment]) -> list[str]:
    return [f"[{segment.id}] {segment.text_src}" for segment in segments]


def _write_bootstrap_input(memory_dir: Path, segments: list[Segment]) -> str:
    view = build_bootstrap_input_view(segments)
    rendered_text = render_bootstrap_input_text(view)
    write_bootstrap_input_artifacts(memory_dir, view, rendered_text)
    return rendered_text


def _bootstrap_prompt(config: AppConfig, bootstrap_input_text: str, source_lang: str, target_lang: str) -> str:
    max_candidates = max(1, int(config.pipeline.memory.bootstrap.max_candidates))
    return (
        f"Source language: {source_lang}\n"
        f"Target language: {target_lang}\n"
        f"Maximum memory candidates: {max_candidates}\n\n"
        "FULL SOURCE SUBTITLES\n"
        "Each item is a soft-cleaned ASR view. Treat raw text as source evidence, clean text as a readability aid, "
        "and flags as risk hints. Low-info/noise/filler rows are usually weak evidence, but may still contain names, "
        "address forms, or ASR variants.\n\n"
        + bootstrap_input_text
        + "\n\nReturn JSON exactly in this shape:\n"
        '{"chunk_ids":["bootstrap"],"actions":[{"action":"upsert","source":"...","target":"...",'
        '"category":"term","status":"proposed","memory_type":"term","constraint":"hint",'
        '"confidence":0.0,"evidence_ids":[1],"aliases":[],'
        '"alias_details":[{"source":"...","kind":"asr_error"}],'
        '"target_variants":[{"source":"...","target":"...","kind":"nickname"}],'
        '"notes":""}]}\n'
        "When no useful candidate exists, return the same shape with an empty actions array."
    )


def bootstrap_memory(
    config: AppConfig,
    segments: list[Segment],
    *,
    source_lang: str,
    target_lang: str,
    memory_dir: Path,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, Any]:
    store = MemoryStore(memory_dir)
    store.ensure_runtime_document()
    bootstrap_file = memory_dir / "bootstrap.json"
    if bootstrap_file.exists():
        if segments and not (memory_dir / "bootstrap_input.json").exists():
            _write_bootstrap_input(memory_dir, segments)
        payload = read_json(bootstrap_file)
        return payload if isinstance(payload, dict) else {"status": "skipped", "reason": "invalid_existing_bootstrap"}
    if not config.pipeline.memory.enabled or not config.pipeline.memory.bootstrap.enabled:
        payload = {"status": "skipped", "reason": "memory_bootstrap_disabled"}
        write_json(bootstrap_file, payload)
        return payload
    if config.pipeline.memory.bootstrap.mode != "whole_document":
        payload = {"status": "skipped", "reason": "unsupported_bootstrap_mode", "mode": config.pipeline.memory.bootstrap.mode}
        write_json(bootstrap_file, payload)
        return payload
    if not segments:
        payload = {"status": "skipped", "reason": "empty_source"}
        write_json(bootstrap_file, payload)
        return payload

    bootstrap_input_text = _write_bootstrap_input(memory_dir, segments)
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    errors: list[dict[str, Any]] = []
    for attempt, route in enumerate(route_candidates, start=1):
        provider = config.providers.get(route.provider)
        if provider is None:
            errors.append({"provider": route.provider, "model": route.model, "error_type": "bad_schema", "message": "provider not found"})
            continue
        client = build_provider_client(provider)
        try:
            _notify_progress(
                progress_callback,
                mode="memory_bootstrap",
                chunk_ids=["bootstrap"],
                provider=route.provider,
                model=route.model,
                attempt=attempt,
                max_attempts=len(route_candidates),
            )
            req = NormalizedRequest(
                model=route.model,
                lines=[],
                source_lang=source_lang,
                target_lang=target_lang,
                context_before=[],
                context_after=[],
                style_prompt=_bootstrap_prompt(config, bootstrap_input_text, source_lang, target_lang),
                prompt_mode="memory_patch",
                system_prompt=config.pipeline.memory.bootstrap.system_prompt,
            )
            response = client.translate_request(req)
            payload = json_from_memory_text(response.raw_text)
            payload.setdefault("chunk_ids", ["bootstrap"])
            payload["provider"] = route.provider
            payload["model"] = route.model
            payload["raw_text"] = response.raw_text
            payload["usage"] = dict(getattr(response, "usage", {}) or {})
            payload["provider_meta"] = dict(getattr(response, "provider_meta", {}) or {})
            payload["status"] = "completed"
            patch = patch_from_payload(payload)
            store.append_patch({"bootstrap": True, **payload})
            document = store.load_runtime()
            document, conflicts = merge_patch(
                document,
                patch,
                store=store,
                protected_entries=store.load_selected_entries(),
                auto_confirm_high_confidence=config.pipeline.memory.merge.auto_confirm_high_confidence,
            )
            store.save(document)
            payload["conflicts"] = len(conflicts)
            write_json(bootstrap_file, payload)
            return payload
        except Exception as exc:  # pragma: no cover - runtime network branches
            errors.append(
                {
                    "provider": route.provider,
                    "model": route.model,
                    "error_type": classify_error(exc),
                    "message": str(exc),
                }
            )
    payload = {"status": "failed", "errors": errors}
    write_json(bootstrap_file, payload)
    return payload


def chunks_from_segments(segments: list[Segment]) -> list[Chunk]:
    return [Chunk(chunk_id="bootstrap", segment_ids=[segment.id for segment in segments], lines=_numbered_source_lines(segments))]
