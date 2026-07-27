from __future__ import annotations

import hashlib
import math
import threading
from pathlib import Path
from typing import Any, Iterator

from ..utils import FileLock, gen_task_id, read_json, write_json


_USAGE_LOCK = threading.RLock()


def _usage_lock_path(source_dir: Path) -> Path:
    return source_dir / "asr" / ".openrouter_usage.lock"


def _receipt_paths(source_dir: Path) -> list[Path]:
    receipts_dir = source_dir / "asr" / "usage_receipts"
    if not receipts_dir.is_dir():
        return []
    return [path for path in receipts_dir.glob("*.json") if path.is_file()]


def _receipt_name_hash(name: str) -> int:
    return int.from_bytes(hashlib.sha256(name.encode("utf-8")).digest(), "big")


def _receipt_manifest(receipt_paths: list[Path]) -> dict[str, Any]:
    digest = 0
    for receipt_path in receipt_paths:
        digest ^= _receipt_name_hash(receipt_path.name)
    return {
        "receipt_file_count": len(receipt_paths),
        "receipt_set_digest": f"{digest:064x}",
    }


def _summary_receipt_manifest(summary: dict[str, Any]) -> dict[str, Any] | None:
    count = summary.get("receipt_file_count")
    digest = summary.get("receipt_set_digest")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        return None
    if not isinstance(digest, str) or len(digest) != 64:
        return None
    try:
        int(digest, 16)
    except ValueError:
        return None
    return {"receipt_file_count": count, "receipt_set_digest": digest.lower()}


def _advance_receipt_manifest(summary: dict[str, Any], receipt_name: str) -> bool:
    manifest = _summary_receipt_manifest(summary)
    if manifest is None:
        return False
    digest = int(str(manifest["receipt_set_digest"]), 16) ^ _receipt_name_hash(receipt_name)
    summary["receipt_file_count"] = int(manifest["receipt_file_count"]) + 1
    summary["receipt_set_digest"] = f"{digest:064x}"
    return True


def _iter_response_payloads(raw_response: dict[str, Any]) -> Iterator[dict[str, Any]]:
    if any(key in raw_response for key in ("text", "segments", "words", "usage")):
        yield raw_response

    related = raw_response.get("_related_responses")
    if isinstance(related, list):
        for item in related:
            if isinstance(item, dict):
                yield from _iter_response_payloads(item)

    if raw_response.get("split_retry") is True:
        children = raw_response.get("children")
        if isinstance(children, list):
            for item in children:
                if isinstance(item, dict):
                    yield from _iter_response_payloads(item)


def _generation_id(response: dict[str, Any]) -> str:
    direct = str(response.get("generation_id") or "").strip()
    if direct:
        return direct
    transport_meta = response.get("_transport_meta")
    if isinstance(transport_meta, dict):
        return str(transport_meta.get("generation_id") or "").strip()
    return ""


def _response_identity(response: dict[str, Any], *, fallback: str) -> str:
    generation_id = _generation_id(response)
    if generation_id:
        return f"generation:{generation_id}"
    receipt_id = str(
        response.get("_usage_receipt_id")
        or response.get("receipt_id")
        or ""
    ).strip()
    if receipt_id:
        return f"receipt:{receipt_id}"
    return fallback


def _response_model(response: dict[str, Any], *, fallback: str = "") -> str:
    direct = str(response.get("model") or "").strip()
    if direct:
        return direct
    transport_meta = response.get("_transport_meta")
    if isinstance(transport_meta, dict):
        transported = str(transport_meta.get("openrouter_model") or "").strip()
        if transported:
            return transported
    return str(fallback or "").strip()


def _nonnegative_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number) or number < 0:
        return None
    return number


def _nonnegative_integer(value: Any) -> int | None:
    number = _nonnegative_number(value)
    if number is None or not number.is_integer():
        return None
    return int(number)


def _summarize(
    raw_responses: list[dict[str, Any]],
    *,
    model: str,
    usage_receipts: list[dict[str, Any]] | None = None,
) -> dict[str, Any] | None:
    candidates: list[tuple[str, dict[str, Any]]] = []
    for index, receipt in enumerate(usage_receipts or []):
        candidates.append((f"receipt_file:{index}", receipt))
    for raw_index, raw_response in enumerate(raw_responses):
        for response_index, response in enumerate(_iter_response_payloads(raw_response)):
            candidates.append((f"legacy_raw:{raw_index}:{response_index}", response))

    responses: list[dict[str, Any]] = []
    seen_response_ids: set[str] = set()
    for fallback_id, response in candidates:
        identity = _response_identity(response, fallback=fallback_id)
        if identity in seen_response_ids:
            continue
        seen_response_ids.add(identity)
        responses.append(response)
    if not responses:
        return None

    costs: list[float] = []
    audio_seconds: list[float] = []
    token_totals: dict[str, list[int]] = {
        "total_tokens": [],
        "input_tokens": [],
        "output_tokens": [],
    }
    usage_response_count = 0
    generation_ids: set[str] = set()
    models: set[str] = set()
    for response in responses:
        usage = response.get("usage")
        if isinstance(usage, dict):
            usage_response_count += 1
            cost = _nonnegative_number(usage.get("cost"))
            if cost is not None:
                costs.append(cost)
            seconds = _nonnegative_number(usage.get("seconds"))
            if seconds is not None:
                audio_seconds.append(seconds)
            for field in token_totals:
                value = _nonnegative_integer(usage.get(field))
                if value is not None:
                    token_totals[field].append(value)
        generation_id = _generation_id(response)
        if generation_id:
            generation_ids.add(generation_id)
        response_model = _response_model(response, fallback=model)
        if response_model:
            models.add(response_model)

    request_count = len(responses)
    summary: dict[str, Any] = {
        "schema_version": 1,
        "provider": "openrouter",
        "model": next(iter(models)) if len(models) == 1 else "",
        "models": sorted(models),
        "currency": "USD",
        "scope": "successful_responses",
        "request_count": request_count,
        "usage_response_count": usage_response_count,
        "generation_count": len(generation_ids),
        "usage_complete": usage_response_count == request_count,
        "cost_complete": len(costs) == request_count,
    }
    if costs:
        summary["cost_usd"] = math.fsum(costs)
    if audio_seconds:
        summary["audio_seconds"] = math.fsum(audio_seconds)
    for field, values in token_totals.items():
        if values:
            summary[field] = sum(values)
    return summary


def _summary_models(summary: dict[str, Any]) -> list[str]:
    raw_models = summary.get("models")
    models = raw_models if isinstance(raw_models, list) else []
    values = [*models, summary.get("model")]
    return [str(item).strip() for item in values if str(item or "").strip()]


def _merge_summaries(
    current: dict[str, Any],
    added: dict[str, Any],
) -> dict[str, Any]:
    current_requests = int(current.get("request_count") or 0)
    added_requests = int(added.get("request_count") or 0)
    models = set(_summary_models(current) + _summary_models(added))
    merged: dict[str, Any] = {
        "schema_version": 1,
        "provider": "openrouter",
        "model": next(iter(models)) if len(models) == 1 else "",
        "models": sorted(models),
        "currency": "USD",
        "scope": "successful_responses",
        "request_count": current_requests + added_requests,
        "usage_response_count": int(current.get("usage_response_count") or 0)
        + int(added.get("usage_response_count") or 0),
        "generation_count": int(current.get("generation_count") or 0)
        + int(added.get("generation_count") or 0),
        "usage_complete": bool(current.get("usage_complete", current_requests == 0))
        and bool(added.get("usage_complete", added_requests == 0)),
        "cost_complete": bool(current.get("cost_complete", current_requests == 0))
        and bool(added.get("cost_complete", added_requests == 0)),
    }
    for field in ("cost_usd", "audio_seconds"):
        values = [
            value
            for value in (
                _nonnegative_number(current.get(field)),
                _nonnegative_number(added.get(field)),
            )
            if value is not None
        ]
        if values:
            merged[field] = math.fsum(values)
    for field in ("total_tokens", "input_tokens", "output_tokens"):
        values = [
            value
            for value in (
                _nonnegative_integer(current.get(field)),
                _nonnegative_integer(added.get(field)),
            )
            if value is not None
        ]
        if values:
            merged[field] = sum(values)
    current_manifest = _summary_receipt_manifest(current)
    if current_manifest is not None:
        merged.update(current_manifest)
    return merged


def _artifact_is_current(source_dir: Path) -> bool:
    usage_path = source_dir / "asr" / "openrouter_usage.json"
    receipts_dir = source_dir / "asr" / "usage_receipts"
    if not usage_path.is_file() or not receipts_dir.is_dir():
        return False
    try:
        cached = read_json(usage_path)
    except Exception:
        return False
    if not isinstance(cached, dict):
        return False
    expected_manifest = _summary_receipt_manifest(cached)
    if expected_manifest is None:
        return False
    return _receipt_manifest(_receipt_paths(source_dir)) == expected_manifest


def write_openrouter_asr_usage_artifact(
    paths: dict[str, Path],
    provider: Any,
    *,
    force_rebuild: bool = False,
) -> tuple[Path | None, dict[str, Any] | None]:
    usage_path = paths["source"] / "asr" / "openrouter_usage.json"
    with _USAGE_LOCK, FileLock(_usage_lock_path(paths["source"])):
        if not force_rebuild and _artifact_is_current(paths["source"]):
            try:
                cached = read_json(usage_path)
            except Exception:
                cached = None
            if isinstance(cached, dict) and int(cached.get("request_count") or 0) > 0:
                return usage_path, cached

        receipt_paths = _receipt_paths(paths["source"])
        usage_receipts: list[dict[str, Any]] = []
        for receipt_path in sorted(receipt_paths):
            try:
                payload = read_json(receipt_path)
            except Exception:
                continue
            if isinstance(payload, dict):
                usage_receipts.append(payload)

        raw_responses: list[dict[str, Any]] = []
        if str(getattr(provider, "protocol", "")) == "openrouter_stt":
            raw_dir = paths["source"] / "asr" / "raw"
            if raw_dir.exists():
                for raw_path in sorted(raw_dir.glob("segment_*.json")):
                    try:
                        payload = read_json(raw_path)
                    except Exception:
                        continue
                    if isinstance(payload, dict):
                        raw_responses.append(payload)
        summary = _summarize(
            raw_responses,
            model=str(getattr(provider, "model", "")),
            usage_receipts=usage_receipts,
        )
        if summary is None:
            usage_path.unlink(missing_ok=True)
            return None, None
        summary.update(_receipt_manifest(receipt_paths))
        write_json(usage_path, summary)
        return usage_path, summary


def record_openrouter_asr_usage_receipt(
    *,
    source_dir: Path,
    provider: Any,
    raw_response: dict | None,
    transport_meta: dict[str, Any],
) -> dict | None:
    if raw_response is None or str(getattr(provider, "protocol", "")) != "openrouter_stt":
        return raw_response
    response_with_transport = (
        {**raw_response, "_transport_meta": transport_meta}
        if transport_meta
        else raw_response
    )
    generation_id = _generation_id(response_with_transport)
    receipt_id = f"generation:{generation_id}" if generation_id else f"response:{gen_task_id()}"
    tagged_response = {**raw_response, "_usage_receipt_id": receipt_id}
    receipt: dict[str, Any] = {
        "receipt_id": receipt_id,
        "provider": "openrouter",
        "model": str(getattr(provider, "model", "")).strip(),
    }
    usage = raw_response.get("usage")
    if isinstance(usage, dict):
        receipt["usage"] = usage
    if generation_id:
        receipt["generation_id"] = generation_id
    receipt_name = hashlib.sha256(receipt_id.encode("utf-8")).hexdigest() + ".json"
    receipt_path = source_dir / "asr" / "usage_receipts" / receipt_name
    with _USAGE_LOCK, FileLock(_usage_lock_path(source_dir)):
        receipt_exists = receipt_path.is_file()
        artifact_was_current = _artifact_is_current(source_dir)
        current_summary: dict[str, Any] | None = None
        usage_path = source_dir / "asr" / "openrouter_usage.json"
        if artifact_was_current:
            try:
                payload = read_json(usage_path)
            except Exception:
                payload = None
            if isinstance(payload, dict):
                current_summary = payload
            else:
                artifact_was_current = False

        if receipt_exists:
            if not artifact_was_current:
                write_openrouter_asr_usage_artifact(
                    {"source": source_dir},
                    provider,
                    force_rebuild=True,
                )
            return tagged_response

        had_receipts = receipt_path.parent.is_dir() and any(receipt_path.parent.glob("*.json"))
        raw_dir = source_dir / "asr" / "raw"
        had_raw_responses = raw_dir.is_dir() and any(raw_dir.glob("segment_*.json"))
        write_json(receipt_path, receipt)
        added_summary = _summarize(
            [],
            model=str(getattr(provider, "model", "")),
            usage_receipts=[receipt],
        )
        if current_summary is not None and added_summary is not None:
            merged_summary = _merge_summaries(current_summary, added_summary)
            if _advance_receipt_manifest(merged_summary, receipt_name):
                write_json(usage_path, merged_summary)
            else:
                write_openrouter_asr_usage_artifact(
                    {"source": source_dir},
                    provider,
                    force_rebuild=True,
                )
        elif not had_receipts and not had_raw_responses and added_summary is not None:
            added_summary.update(
                {
                    "receipt_file_count": 1,
                    "receipt_set_digest": f"{_receipt_name_hash(receipt_name):064x}",
                }
            )
            write_json(usage_path, added_summary)
        else:
            write_openrouter_asr_usage_artifact(
                {"source": source_dir},
                provider,
                force_rebuild=True,
            )
    return tagged_response
