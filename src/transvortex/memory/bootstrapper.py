from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment
from ..providers import build_provider_client, classify_error
from ..utils import read_json, write_json
from .bootstrap_input import build_bootstrap_input_view, render_bootstrap_input_text, write_bootstrap_input_artifacts
from .merger import merge_patch, patch_from_payload
from .patcher import json_from_memory_text
from .schema import MEMORY_CONSTRAINTS, MEMORY_TYPES, ALIAS_KINDS
from .selector import is_generic_form
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
        '"confidence":0.0,"confidence_breakdown":{"source":0.0,"target":0.0,"link":0.0,"variant":0.0,"asr":0.0},'
        '"evidence_ids":[1],"aliases":[],' 
        '"alias_details":[{"source":"...","kind":"asr_error"}],'
        '"target_variants":[{"source":"...","target":"...","kind":"nickname","confidence":0.0,"speaker_scope":{},"notes":""}],'
        '"enforcement_policy":{"translation":"recognize_only","qa":"info","naturalness_override":true},'
        '"provenance":[{"kind":"bootstrap","source_evidence":"source_only"}],"scope":{},'
        '"notes":""}]}\n'
        "When no useful candidate exists, return the same shape with an empty actions array."
    )


def _extract_prompt(config: AppConfig, bootstrap_input_text: str, source_lang: str) -> str:
    max_candidates = max(1, int(config.pipeline.memory.bootstrap.max_candidates))
    return (
        f"Source language: {source_lang}\n"
        f"Maximum source-side candidates: {max_candidates}\n\n"
        "FULL SOURCE SUBTITLES\n"
        "Each item is a soft-cleaned ASR view. Extract source-side evidence only; do not translate.\n\n"
        + bootstrap_input_text
        + "\n\nReturn JSON exactly in this shape:\n"
        '{"candidates":[{"surface":"...","occurrence_ids":[1],"nearby_forms":["..."],'
        '"candidate_kind":"name|place|organization|title|term|phrase|asr_variant|address_form|unknown",'
        '"asr_risk":0.0,"recurrence":1,"local_context":["short evidence quote"],"reason":"short reason"}]}\n'
        "When no useful candidate exists, return the same shape with an empty candidates array."
    )


def _classify_prompt(
    config: AppConfig,
    candidates_payload: dict[str, Any],
    source_lang: str,
    target_lang: str,
) -> str:
    max_candidates = max(1, int(config.pipeline.memory.bootstrap.max_candidates))
    candidates = candidates_payload.get("candidates", []) if isinstance(candidates_payload, dict) else []
    return (
        f"Source language: {source_lang}\n"
        f"Target language: {target_lang}\n"
        f"Maximum memory candidates: {max_candidates}\n\n"
        "SOURCE-SIDE CANDIDATE EVIDENCE\n"
        f"{candidates}\n\n"
        "Convert source-side candidates into conservative translation memory actions.\n"
        "- Prefer precision over recall.\n"
        "- Do not create hard memory from source-only evidence.\n"
        "- Use target only when obvious, low-risk, or supplied by existing preset evidence.\n"
        "- Put nicknames, honorifics, and ASR variants under the canonical source when possible.\n\n"
        "Return JSON exactly in this shape:\n"
        '{"chunk_ids":["bootstrap"],"actions":[{"action":"upsert","source":"...","target":"...",'
        '"category":"term","status":"proposed","memory_type":"term","constraint":"hint",'
        '"confidence":0.0,"confidence_breakdown":{"source":0.0,"target":0.0,"link":0.0,"variant":0.0,"asr":0.0},'
        '"evidence_ids":[1],"aliases":[],' 
        '"alias_details":[{"source":"...","kind":"asr_error"}],'
        '"target_variants":[{"source":"...","target":"...","kind":"nickname","confidence":0.0,"speaker_scope":{},"notes":""}],'
        '"enforcement_policy":{"translation":"recognize_only","qa":"info","naturalness_override":true},'
        '"provenance":[{"kind":"bootstrap","source_evidence":"source_only"}],"scope":{},'
        '"notes":""}]}\n'
        "When no useful candidate exists, return the same shape with an empty actions array."
    )


def _target_too_long(target: str) -> bool:
    target = str(target or "").strip()
    return bool(target and len(target) > 32)


def _validate_bootstrap_payload(payload: dict[str, Any]) -> dict[str, Any]:
    actions: list[dict[str, Any]] = []
    for row in payload.get("actions", []) or []:
        if not isinstance(row, dict):
            continue
        source = str(row.get("source") or "").strip()
        if not source or is_generic_form(source):
            continue
        target = str(row.get("target") or "").strip()
        status = str(row.get("status") or "proposed").strip().lower()
        constraint = str(row.get("constraint") or "hint").strip().lower()
        memory_type = str(row.get("memory_type") or "").strip().lower()
        if status in {"locked", "confirmed"}:
            row["status"] = "proposed"
        if constraint == "must_use":
            row["constraint"] = "hint"
        if constraint and constraint not in MEMORY_CONSTRAINTS:
            row["constraint"] = "hint"
        if memory_type and memory_type not in MEMORY_TYPES:
            row["memory_type"] = "term"
        if _target_too_long(target):
            row["target"] = ""
            row["constraint"] = "hint"
        aliases = [
            item
            for item in row.get("alias_details", []) or []
            if isinstance(item, dict)
            and str(item.get("source") or "").strip()
            and not is_generic_form(str(item.get("source") or ""))
            and str(item.get("kind") or "spelling").strip().lower() in ALIAS_KINDS
        ]
        row["alias_details"] = aliases
        row["aliases"] = [
            str(item).strip()
            for item in row.get("aliases", []) or []
            if str(item or "").strip() and not is_generic_form(str(item))
        ]
        variants = [
            item
            for item in row.get("target_variants", []) or []
            if isinstance(item, dict)
            and str(item.get("source") or "").strip()
            and str(item.get("target") or "").strip()
            and not is_generic_form(str(item.get("source") or ""))
            and not _target_too_long(str(item.get("target") or ""))
        ]
        row["target_variants"] = variants
        if not row.get("target") and not aliases and not variants and row.get("memory_type") != "concept_hint":
            continue
        actions.append(row)
    payload["actions"] = actions
    return payload


def _extract_candidates(
    *,
    client: Any,
    route_model: str,
    config: AppConfig,
    bootstrap_input_text: str,
    source_lang: str,
    target_lang: str,
) -> tuple[dict[str, Any], str]:
    req = NormalizedRequest(
        model=route_model,
        lines=[],
        source_lang=source_lang,
        target_lang=target_lang,
        context_before=[],
        context_after=[],
        style_prompt=_extract_prompt(config, bootstrap_input_text, source_lang),
        prompt_mode="memory_patch",
        system_prompt=config.pipeline.memory.bootstrap.system_prompt,
    )
    response = client.translate_request(req)
    payload = json_from_memory_text(response.raw_text)
    if not isinstance(payload.get("candidates", []), list):
        payload["candidates"] = []
    return payload, response.raw_text


def _classify_candidates(
    *,
    client: Any,
    route_model: str,
    config: AppConfig,
    candidates_payload: dict[str, Any],
    source_lang: str,
    target_lang: str,
) -> tuple[dict[str, Any], str, dict[str, Any], dict[str, Any]]:
    req = NormalizedRequest(
        model=route_model,
        lines=[],
        source_lang=source_lang,
        target_lang=target_lang,
        context_before=[],
        context_after=[],
        style_prompt=_classify_prompt(config, candidates_payload, source_lang, target_lang),
        prompt_mode="memory_patch",
        system_prompt=config.pipeline.memory.bootstrap.system_prompt,
    )
    response = client.translate_request(req)
    payload = _validate_bootstrap_payload(json_from_memory_text(response.raw_text))
    return (
        payload,
        response.raw_text,
        dict(getattr(response, "usage", {}) or {}),
        dict(getattr(response, "provider_meta", {}) or {}),
    )


def _single_pass_bootstrap(
    *,
    client: Any,
    route_model: str,
    config: AppConfig,
    bootstrap_input_text: str,
    source_lang: str,
    target_lang: str,
) -> tuple[dict[str, Any], str, dict[str, Any], dict[str, Any], dict[str, Any] | None]:
    req = NormalizedRequest(
        model=route_model,
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
    payload = _validate_bootstrap_payload(json_from_memory_text(response.raw_text))
    return payload, response.raw_text, dict(getattr(response, "usage", {}) or {}), dict(getattr(response, "provider_meta", {}) or {}), None


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
            candidates_payload = None
            if str(config.pipeline.memory.bootstrap.pipeline or "").strip().lower() == "staged":
                candidates_payload, extract_raw_text = _extract_candidates(
                    client=client,
                    route_model=route.model,
                    config=config,
                    bootstrap_input_text=bootstrap_input_text,
                    source_lang=source_lang,
                    target_lang=target_lang,
                )
                payload, raw_text, usage, provider_meta = _classify_candidates(
                    client=client,
                    route_model=route.model,
                    config=config,
                    candidates_payload=candidates_payload,
                    source_lang=source_lang,
                    target_lang=target_lang,
                )
                payload["extract_raw_text"] = extract_raw_text
                payload["extract_candidates"] = len(candidates_payload.get("candidates", []))
            else:
                payload, raw_text, usage, provider_meta, candidates_payload = _single_pass_bootstrap(
                    client=client,
                    route_model=route.model,
                    config=config,
                    bootstrap_input_text=bootstrap_input_text,
                    source_lang=source_lang,
                    target_lang=target_lang,
                )
            payload.setdefault("chunk_ids", ["bootstrap"])
            payload["provider"] = route.provider
            payload["model"] = route.model
            payload["raw_text"] = raw_text
            payload["usage"] = usage
            payload["provider_meta"] = provider_meta
            payload["bootstrap_pipeline"] = str(config.pipeline.memory.bootstrap.pipeline or "single")
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
