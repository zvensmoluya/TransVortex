from __future__ import annotations

import re
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable

from ..app.models import AppConfig, Chunk, NormalizedRequest, Segment, SubtitleQualityConfig
from ..memory.json_utils import json_object_from_model_text
from ..memory.injector import build_memory_prompt
from ..memory.selector import select_memory_entries
from ..memory.store import MemoryStore
from ..memory.plan import effective_memory_sources, translates_with_memory
from ..providers import build_provider_client, classify_error
from .subtitle_optimizer import optimize_subtitles
from .subtitle_quality import clean_subtitle_text
from .asr_quality import has_high_asr_risk


REFLOW_STYLE_PROMPT = (
    "Make translated subtitles concise, natural, and readable while preserving the source meaning and tone. "
    "Prefer merging adjacent fragments when the current split creates unreadable timing. Keep names and terms consistent."
)

REFLOW_SYSTEM_PROMPT = (
    "You are a subtitle post-editor. Repair readability and timing failures in already translated subtitles. "
    "Do not retranslate the whole scene, do not globally rewrite unaffected subtitles, and return only the requested schema."
)

ProgressCallback = Callable[[dict[str, Any]], None]


def _notify_progress(progress_callback: ProgressCallback | None, **payload: Any) -> None:
    if progress_callback is None:
        return
    try:
        progress_callback(payload)
    except Exception:
        pass


@dataclass
class ReflowWindow:
    window_index: int
    editable: list[Segment]
    context_before: list[Segment]
    context_after: list[Segment]

    @property
    def window_ids(self) -> list[int]:
        return [seg.id for seg in self.editable]


def _extract_json_object(raw_text: str) -> dict[str, Any]:
    try:
        return json_object_from_model_text(raw_text)
    except Exception as exc:
        raise RuntimeError("reflow response is not JSON") from exc


def _quality_rows_by_id(report: dict[str, Any]) -> dict[int, dict[str, Any]]:
    rows: dict[int, dict[str, Any]] = {}
    for row in report.get("segments", []):
        try:
            rows[int(row.get("id"))] = row
        except (TypeError, ValueError):
            continue
    return rows


def _issues_for_row(
    row: dict[str, Any],
    trigger: str,
    *,
    min_duration: float,
    max_duration: float,
) -> list[dict[str, Any]]:
    trigger = str(trigger or "fail_only").strip().lower()
    issues = [issue for issue in list(row.get("issues") or []) if isinstance(issue, dict)]
    if trigger == "fail_only":
        return [
            issue
            for issue in issues
            if issue.get("code") in {"duration_too_short", "cps_too_high", "too_many_lines", "line_too_wide"}
        ]
    if trigger == "warn_and_fail":
        try:
            duration = float(row.get("duration") or 0.0)
        except (TypeError, ValueError):
            duration = 0.0
        if duration < 1.0 and not any(issue.get("code") == "under_one_second" for issue in issues):
            issues.append({"code": "under_one_second", "message": f"duration {duration:.2f}s < 1.00s"})
        if duration > max_duration and not any(issue.get("code") == "over_max_duration" for issue in issues):
            issues.append({"code": "over_max_duration", "message": f"duration {duration:.2f}s > {max_duration:.2f}s"})
        if duration < min_duration and not any(issue.get("code") == "duration_too_short" for issue in issues):
            issues.append({"code": "duration_too_short", "message": f"duration {duration:.2f}s < {min_duration:.2f}s"})
    return issues


def _candidate_ids(report: dict[str, Any], trigger: str) -> list[int]:
    out: list[int] = []
    summary = dict(report.get("summary") or {})
    thresholds = dict(summary.get("thresholds") or {})
    min_duration = float(thresholds.get("min_duration_seconds") or 0.8)
    max_duration = float(thresholds.get("max_duration_seconds") or 6.0)
    for row in report.get("segments", []):
        if not isinstance(row, dict):
            continue
        issues = _issues_for_row(row, trigger, min_duration=min_duration, max_duration=max_duration)
        if issues:
            try:
                out.append(int(row.get("id")))
            except (TypeError, ValueError):
                continue
    return out


def _windows_for_candidates(
    segments: list[Segment],
    candidate_ids: list[int],
    *,
    max_windows: int,
    max_window_segments: int,
    context_before_segments: int,
    context_after_segments: int,
) -> list[ReflowWindow]:
    if not candidate_ids:
        return []
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    index_by_id = {seg.id: idx for idx, seg in enumerate(ordered)}
    max_windows = max(0, int(max_windows or 0))
    max_window_segments = max(1, int(max_window_segments or 1))
    context_before_segments = max(0, int(context_before_segments or 0))
    context_after_segments = max(0, int(context_after_segments or 0))
    windows: list[ReflowWindow] = []
    covered: set[int] = set()
    for seg_id in candidate_ids:
        if max_windows and len(windows) >= max_windows:
            break
        idx = index_by_id.get(seg_id)
        if idx is None or seg_id in covered:
            continue
        start = idx
        end = min(len(ordered), start + max_window_segments)
        if end - start < max_window_segments:
            start = max(0, end - max_window_segments)
        editable = ordered[start:end]
        context_before = ordered[max(0, start - context_before_segments) : start]
        context_after = ordered[end : min(len(ordered), end + context_after_segments)]
        window = ReflowWindow(
            window_index=len(windows) + 1,
            editable=editable,
            context_before=context_before,
            context_after=context_after,
        )
        windows.append(window)
        covered.update(seg.id for seg in editable)
    return windows


def _line_for_segment(seg: Segment) -> str:
    source = clean_subtitle_text(seg.text_src)
    target = clean_subtitle_text(seg.text_tgt)
    return f"[{seg.id}] SRC: {source}\n[{seg.id}] TGT: {target}"


def _context_lines(segments: list[Segment]) -> list[str]:
    return [f"[{seg.id}] {clean_subtitle_text(seg.text_src)} => {clean_subtitle_text(seg.text_tgt)}" for seg in segments]


def _quality_reason(window: ReflowWindow, rows_by_id: dict[int, dict[str, Any]], config: AppConfig) -> str:
    thresholds = config.pipeline.subtitle.quality
    lines: list[str] = []
    for seg in window.editable:
        row = rows_by_id.get(seg.id) or {}
        issues = _issues_for_row(
            row,
            config.pipeline.subtitle.reflow.trigger,
            min_duration=float(thresholds.min_duration_seconds),
            max_duration=float(thresholds.max_duration_seconds),
        )
        if not issues:
            continue
        issue_text = "; ".join(str(issue.get("message") or issue.get("code") or "") for issue in issues)
        lines.append(f"window {window.window_index} [{seg.id}] {issue_text}")
    return "\n".join(lines)


def _window_lines(window: ReflowWindow) -> list[str]:
    lines = [f"window_id: {window.window_index}", f"allowed_source_ids: {window.window_ids}"]
    lines.extend(_line_for_segment(seg) for seg in window.editable)
    return lines


def _batch_lines(windows: list[ReflowWindow]) -> list[str]:
    lines: list[str] = []
    for window in windows:
        if lines:
            lines.append("")
        lines.extend(_window_lines(window))
    return lines


def _batch_context_before(windows: list[ReflowWindow]) -> list[str]:
    seen: set[int] = set()
    out: list[Segment] = []
    for window in windows:
        for seg in window.context_before:
            if seg.id not in seen:
                seen.add(seg.id)
                out.append(seg)
    return _context_lines(sorted(out, key=lambda item: (item.start, item.end, item.id)))


def _batch_context_after(windows: list[ReflowWindow]) -> list[str]:
    seen: set[int] = set()
    out: list[Segment] = []
    for window in windows:
        for seg in window.context_after:
            if seg.id not in seen:
                seen.add(seg.id)
                out.append(seg)
    return _context_lines(sorted(out, key=lambda item: (item.start, item.end, item.id)))


def _memory_prompt_for_batch(
    *,
    config: AppConfig,
    memory_dir: Path | None,
    windows: list[ReflowWindow],
    lines: list[str],
    context_before: list[str],
    context_after: list[str],
) -> tuple[str, int]:
    if not memory_dir or not translates_with_memory(config.pipeline.memory) or not config.pipeline.subtitle.reflow.memory:
        return "", 0
    store = MemoryStore(memory_dir)
    document = store.load_effective(effective_memory_sources(config.pipeline.memory))
    chunk = Chunk(
        chunk_id="reflow_" + "_".join(str(window.window_index) for window in windows),
        segment_ids=[seg.id for window in windows for seg in window.editable],
        lines=lines,
        context_before=context_before,
        context_after=context_after,
    )
    selected = select_memory_entries(document, chunk, config.pipeline.memory.inject)
    return build_memory_prompt(selected, config.pipeline.memory.inject), len(selected)


def _request_for_batch(
    *,
    config: AppConfig,
    route_model: str,
    windows: list[ReflowWindow],
    rows_by_id: dict[int, dict[str, Any]],
    source_lang: str,
    target_lang: str,
    memory_dir: Path | None,
) -> tuple[NormalizedRequest, int]:
    lines = _batch_lines(windows)
    context_before = _batch_context_before(windows)
    context_after = _batch_context_after(windows)
    memory_prompt, memory_entries = _memory_prompt_for_batch(
        config=config,
        memory_dir=memory_dir,
        windows=windows,
        lines=lines,
        context_before=context_before,
        context_after=context_after,
    )
    quality_reason = "\n".join(item for window in windows if (item := _quality_reason(window, rows_by_id, config)))
    req = NormalizedRequest(
        model=route_model,
        lines=lines,
        source_lang=source_lang,
        target_lang=target_lang,
        context_before=context_before,
        context_after=context_after,
        style_prompt=REFLOW_STYLE_PROMPT,
        memory_prompt=memory_prompt,
        prompt_mode="reflow",
        repair_reason=quality_reason,
        system_prompt=_reflow_system_prompt(config),
    )
    return req, memory_entries


def _reflow_system_prompt(config: AppConfig) -> str:
    return (
        REFLOW_SYSTEM_PROMPT
        + "\n\nProject instructions:\n"
        + "- Preserve faithful meaning, tone, names, terms, nicknames, and address flavor.\n"
        + "- Translation memory and style instructions guide wording, but JSON output contract wins.\n"
        + "- Never output numbered subtitle lines unless they are inside the requested JSON field values."
    )


def _request_size(req: NormalizedRequest) -> int:
    return sum(len(item) for item in req.lines) + sum(len(item) for item in req.context_before) + sum(len(item) for item in req.context_after) + len(req.memory_prompt) + len(req.repair_reason) + len(req.style_prompt)


def _batch_requests(
    *,
    config: AppConfig,
    windows: list[ReflowWindow],
    rows_by_id: dict[int, dict[str, Any]],
    source_lang: str,
    target_lang: str,
    memory_dir: Path | None,
    route_model: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    reflow_config = config.pipeline.subtitle.reflow
    max_batch = max(1, int(reflow_config.batch_windows or 1))
    max_chars = max(1000, int(reflow_config.max_input_chars or 1000))
    batches: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    idx = 0
    while idx < len(windows):
        current: list[ReflowWindow] = []
        last_req: NormalizedRequest | None = None
        last_memory_entries = 0
        while idx < len(windows) and len(current) < max_batch:
            window = windows[idx]
            candidate = [*current, window]
            req, memory_entries = _request_for_batch(
                config=config,
                route_model=route_model,
                windows=candidate,
                rows_by_id=rows_by_id,
                source_lang=source_lang,
                target_lang=target_lang,
                memory_dir=memory_dir,
            )
            request_size = _request_size(req)
            if request_size <= max_chars:
                current = candidate
                last_req = req
                last_memory_entries = memory_entries
                idx += 1
                continue
            if not current:
                shrunken = _shrink_window_context(window, 0, 0)
                shrunk_req, shrunk_memory_entries = _request_for_batch(
                    config=config,
                    route_model=route_model,
                    windows=[shrunken],
                    rows_by_id=rows_by_id,
                    source_lang=source_lang,
                    target_lang=target_lang,
                    memory_dir=memory_dir,
                )
                shrunk_size = _request_size(shrunk_req)
                if shrunk_size <= max_chars:
                    current = [shrunken]
                    last_req = shrunk_req
                    last_memory_entries = shrunk_memory_entries
                    idx += 1
                    break
                skipped.append(
                    {
                        "window_index": window.window_index,
                        "window_ids": window.window_ids,
                        "status": "skipped",
                        "skipped_reason": "reflow_input_budget_exceeded",
                        "input_chars": shrunk_size,
                        "original_input_chars": request_size,
                        "attempts": [],
                    }
                )
                idx += 1
            break
        if not current or last_req is None:
            continue
        batches.append(
            {
                "batch_index": len(batches) + 1,
                "windows": current,
                "request": last_req,
                "input_chars": _request_size(last_req),
                "memory_entries": last_memory_entries,
            }
        )
    return batches, skipped


def _shrink_window_context(window: ReflowWindow, keep_before: int, keep_after: int) -> ReflowWindow:
    keep_before = max(0, keep_before)
    keep_after = max(0, keep_after)
    return ReflowWindow(
        window_index=window.window_index,
        editable=window.editable,
        context_before=window.context_before[-keep_before:] if keep_before else [],
        context_after=window.context_after[:keep_after] if keep_after else [],
    )


def _replacement_payloads_for_windows(raw_text: str, windows: list[ReflowWindow]) -> dict[int, list[dict[str, Any]]]:
    payload = _extract_json_object(raw_text)
    if isinstance(payload.get("windows"), list):
        out: dict[int, list[dict[str, Any]]] = {}
        for row in payload["windows"]:
            if not isinstance(row, dict):
                continue
            try:
                window_id = int(row.get("window_id"))
            except (TypeError, ValueError):
                continue
            replacements = row.get("replacements")
            if not isinstance(replacements, list):
                raise RuntimeError("reflow window missing replacements list")
            out[window_id] = [item for item in replacements if isinstance(item, dict)]
        return out
    replacements = payload.get("replacements")
    if isinstance(replacements, list) and len(windows) == 1:
        return {windows[0].window_index: [row for row in replacements if isinstance(row, dict)]}
    raise RuntimeError("reflow response missing windows list")


def _limited_replacements(replacements: list[dict[str, Any]], limit: int) -> tuple[list[dict[str, Any]], bool]:
    limit = max(0, int(limit or 0))
    if limit <= 0 or len(replacements) <= limit:
        return replacements, False
    return replacements[:limit], True


def _apply_replacements(
    segments: list[Segment],
    window: ReflowWindow,
    replacements: list[dict[str, Any]],
    quality: SubtitleQualityConfig,
    *,
    allow_merge: bool,
    allow_drop: bool,
    max_output_replacements: int,
) -> tuple[list[Segment], list[dict[str, Any]]]:
    replacements, truncated = _limited_replacements(replacements, max_output_replacements)
    by_id = {seg.id: seg for seg in segments}
    window_ids = {seg.id for seg in window.editable}
    consumed: set[int] = set()
    new_segments: list[Segment] = []
    artifacts: list[dict[str, Any]] = []
    if truncated:
        artifacts.append({"status": "rejected", "reason": "replacement limit exceeded"})

    for replacement_payload in replacements:
        raw_ids = replacement_payload.get("source_ids")
        if not isinstance(raw_ids, list):
            artifacts.append({"status": "rejected", "reason": "source_ids must be a list", "payload": replacement_payload})
            continue
        try:
            source_ids = [int(item) for item in raw_ids]
        except (TypeError, ValueError):
            artifacts.append({"status": "rejected", "reason": "source_ids must contain integers", "payload": replacement_payload})
            continue
        if not source_ids:
            artifacts.append({"status": "rejected", "reason": "source_ids is empty", "payload": replacement_payload})
            continue
        if len(set(source_ids)) != len(source_ids):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "source_ids contains duplicates"})
            continue
        if any(seg_id not in window_ids for seg_id in source_ids):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "source_ids outside window"})
            continue
        if any(seg_id in consumed for seg_id in source_ids):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "source id reused"})
            continue
        if any(seg_id not in by_id for seg_id in source_ids):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "source id no longer exists"})
            continue
        ordered_window_ids = [seg.id for seg in sorted(window.editable, key=lambda item: (item.start, item.end, item.id))]
        positions = sorted(ordered_window_ids.index(seg_id) for seg_id in source_ids)
        if positions != list(range(positions[0], positions[-1] + 1)):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "source_ids must be contiguous"})
            continue
        source_ids = [ordered_window_ids[position] for position in positions]
        if len(source_ids) > 1 and not allow_merge:
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "merge is disabled"})
            continue
        source_segments = [by_id[seg_id] for seg_id in source_ids]
        source_segments.sort(key=lambda seg: (seg.start, seg.end, seg.id))
        if len(source_ids) > 1 and any(has_high_asr_risk(seg) for seg in source_segments):
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "merge contains high-risk ASR segment"})
            continue
        text = clean_subtitle_text(replacement_payload.get("text_tgt"))
        if not text and not allow_drop:
            artifacts.append({"status": "rejected", "source_ids": source_ids, "reason": "empty replacement text"})
            continue
        if not text:
            consumed.update(source_ids)
            artifacts.append(
                {
                    "status": "accepted",
                    "source_ids": source_ids,
                    "replacement_id": None,
                    "text_tgt": "",
                    "reason": str(replacement_payload.get("reason") or ""),
                    "action": "drop",
                }
            )
            continue
        merged_src = "\n".join(clean_subtitle_text(seg.text_src) for seg in source_segments if clean_subtitle_text(seg.text_src))
        start = min(seg.start for seg in source_segments)
        end = max(seg.end for seg in source_segments)
        meta = dict(source_segments[0].meta)
        meta["reflowed"] = True
        meta["source_ids"] = source_ids
        meta["reflow_reason"] = str(replacement_payload.get("reason") or "")
        candidate = replace(source_segments[0], start=start, end=end, text_src=merged_src, text_tgt=text or None, meta=meta)
        validation_quality = replace(quality, enabled=False, mode="off")
        row = optimize_subtitles([candidate], validation_quality).report["segments"][0]
        if row.get("issues"):
            artifacts.append(
                {
                    "status": "rejected",
                    "source_ids": source_ids,
                    "reason": "replacement failed quality validation",
                    "issues": row.get("issues"),
                }
            )
            continue
        consumed.update(source_ids)
        new_segments.append(candidate)
        artifacts.append(
            {
                "status": "accepted",
                "source_ids": source_ids,
                "replacement_id": candidate.id,
                "text_tgt": candidate.text_tgt,
                "reason": meta["reflow_reason"],
            }
        )

    if not consumed:
        return segments, artifacts
    output: list[Segment] = []
    inserted_ids = {seg.id for seg in new_segments}
    new_by_id = {seg.id: seg for seg in new_segments}
    for seg in sorted(segments, key=lambda item: (item.start, item.end, item.id)):
        if seg.id in consumed:
            if seg.id in inserted_ids:
                output.append(new_by_id[seg.id])
            continue
        output.append(seg)
    return sorted(output, key=lambda item: (item.start, item.end, item.id)), artifacts


def _window_artifact(
    *,
    window: ReflowWindow,
    batch_index: int,
    batch_size: int,
    input_chars: int,
    memory_entries: int,
    fallback: bool,
) -> dict[str, Any]:
    return {
        "batch_index": batch_index,
        "batch_size": batch_size,
        "window_index": window.window_index,
        "window_ids": window.window_ids,
        "status": "failed",
        "fallback": fallback,
        "input_chars": input_chars,
        "memory_entries": memory_entries,
        "attempts": [],
    }


def _apply_batch_payload(
    *,
    output: list[Segment],
    windows: list[ReflowWindow],
    payload_by_window: dict[int, list[dict[str, Any]]],
    config: AppConfig,
    artifacts_by_window: dict[int, dict[str, Any]],
    response_meta: dict[str, Any],
) -> tuple[list[Segment], bool]:
    reflow_config = config.pipeline.subtitle.reflow
    any_accepted = False
    for window in windows:
        row_artifact = artifacts_by_window[window.window_index]
        replacements = payload_by_window.get(window.window_index, [])
        updated, applied = _apply_replacements(
            output,
            window,
            replacements,
            config.pipeline.subtitle.quality,
            allow_merge=reflow_config.allow_merge,
            allow_drop=reflow_config.allow_drop,
            max_output_replacements=reflow_config.max_output_replacements,
        )
        accepted = any(item.get("status") == "accepted" for item in applied)
        row_artifact["attempts"].append(
            {
                **response_meta,
                "status": "applied" if accepted else "rejected",
                "results": applied,
            }
        )
        if accepted:
            output = updated
            row_artifact["status"] = "reflowed"
            any_accepted = True
    return output, any_accepted


def _run_batch(
    *,
    config: AppConfig,
    output: list[Segment],
    batch: dict[str, Any],
    route_candidates: list[Any],
    source_lang: str,
    target_lang: str,
    rows_by_id: dict[int, dict[str, Any]],
    memory_dir: Path | None,
    fallback: bool = False,
    progress_callback: ProgressCallback | None = None,
) -> tuple[list[Segment], list[dict[str, Any]], bool]:
    reflow_config = config.pipeline.subtitle.reflow
    windows: list[ReflowWindow] = list(batch["windows"])
    artifacts_by_window = {
        window.window_index: _window_artifact(
            window=window,
            batch_index=int(batch["batch_index"]),
            batch_size=len(windows),
            input_chars=int(batch.get("input_chars") or 0),
            memory_entries=int(batch.get("memory_entries") or 0),
            fallback=fallback,
        )
        for window in windows
    }
    attempts = max(1, int(reflow_config.max_attempts or 1))
    batch_failed = False
    for route in route_candidates:
        provider = config.providers.get(route.provider)
        if not provider:
            for row_artifact in artifacts_by_window.values():
                row_artifact["attempts"].append(
                    {"provider": route.provider, "model": route.model, "status": "failed", "message": "provider not found"}
                )
            batch_failed = True
            continue
        client = build_provider_client(provider)
        req = batch["request"]
        if req.model != route.model:
            req, memory_entries = _request_for_batch(
                config=config,
                route_model=route.model,
                windows=windows,
                rows_by_id=rows_by_id,
                source_lang=source_lang,
                target_lang=target_lang,
                memory_dir=memory_dir,
            )
            batch["request"] = req
            batch["input_chars"] = _request_size(req)
            batch["memory_entries"] = memory_entries
            for row_artifact in artifacts_by_window.values():
                row_artifact["input_chars"] = batch["input_chars"]
                row_artifact["memory_entries"] = memory_entries
        for attempt in range(attempts):
            try:
                _notify_progress(
                    progress_callback,
                    mode="quality_reflow",
                    request_state="started",
                    chunk_id=f"reflow_{int(batch['batch_index'])}",
                    segment_ids=[segment_id for window in windows for segment_id in window.window_ids],
                    provider=route.provider,
                    model=route.model,
                    attempt=attempt + 1,
                    max_attempts=attempts,
                )
                response = client.translate_request(req)
                payload_by_window = _replacement_payloads_for_windows(response.raw_text, windows)
                output, _any_accepted = _apply_batch_payload(
                    output=output,
                    windows=windows,
                    payload_by_window=payload_by_window,
                    config=config,
                    artifacts_by_window=artifacts_by_window,
                    response_meta={
                        "provider": route.provider,
                        "model": route.model,
                        "attempt": attempt + 1,
                        "raw_text": response.raw_text,
                    },
                )
                return output, list(artifacts_by_window.values()), True
            except Exception as exc:
                batch_failed = True
                for row_artifact in artifacts_by_window.values():
                    row_artifact["attempts"].append(
                        {
                            "provider": route.provider,
                            "model": route.model,
                            "attempt": attempt + 1,
                            "status": "failed",
                            "error_type": classify_error(exc),
                            "message": str(exc),
                        }
                    )
                if attempt + 1 < attempts:
                    time.sleep(min(2**attempt, 5))
        if any(row.get("status") == "reflowed" for row in artifacts_by_window.values()):
            break
    return output, list(artifacts_by_window.values()), not batch_failed


def _single_window_batches(
    *,
    config: AppConfig,
    windows: list[ReflowWindow],
    rows_by_id: dict[int, dict[str, Any]],
    source_lang: str,
    target_lang: str,
    memory_dir: Path | None,
    route_model: str,
    batch_index_start: int,
) -> list[dict[str, Any]]:
    batches: list[dict[str, Any]] = []
    for window in windows:
        req, memory_entries = _request_for_batch(
            config=config,
            route_model=route_model,
            windows=[window],
            rows_by_id=rows_by_id,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_dir=memory_dir,
        )
        batches.append(
            {
                "batch_index": batch_index_start + len(batches),
                "windows": [window],
                "request": req,
                "input_chars": _request_size(req),
                "memory_entries": memory_entries,
            }
        )
    return batches


def reflow_subtitles(
    *,
    config: AppConfig,
    segments: list[Segment],
    quality_report: dict[str, Any],
    source_lang: str,
    target_lang: str,
    memory_dir: Path | None = None,
    progress_callback: ProgressCallback | None = None,
) -> tuple[list[Segment], list[dict[str, Any]]]:
    reflow_config = config.pipeline.subtitle.reflow
    if not reflow_config.enabled:
        return segments, []
    rows_by_id = _quality_rows_by_id(quality_report)
    candidate_ids = _candidate_ids(quality_report, reflow_config.trigger)
    windows = _windows_for_candidates(
        segments,
        candidate_ids,
        max_windows=reflow_config.max_windows,
        max_window_segments=reflow_config.max_window_segments,
        context_before_segments=reflow_config.context_before_segments,
        context_after_segments=reflow_config.context_after_segments,
    )
    if not windows:
        return segments, []

    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    output = list(segments)
    artifacts: list[dict[str, Any]] = []
    primary_model = config.routing.primary.model
    batches, skipped = _batch_requests(
        config=config,
        windows=windows,
        rows_by_id=rows_by_id,
        source_lang=source_lang,
        target_lang=target_lang,
        memory_dir=memory_dir,
        route_model=primary_model,
    )
    artifacts.extend(skipped)

    for batch in batches:
        output, rows, parse_ok = _run_batch(
            config=config,
            output=output,
            batch=batch,
            route_candidates=route_candidates,
            source_lang=source_lang,
            target_lang=target_lang,
            rows_by_id=rows_by_id,
            memory_dir=memory_dir,
            progress_callback=progress_callback,
        )
        if parse_ok or len(batch["windows"]) == 1:
            artifacts.extend(rows)
            continue
        fallback_batches = _single_window_batches(
            config=config,
            windows=batch["windows"],
            rows_by_id=rows_by_id,
            source_lang=source_lang,
            target_lang=target_lang,
            memory_dir=memory_dir,
            route_model=primary_model,
            batch_index_start=len(batches) + len(artifacts) + 1,
        )
        for fallback_batch in fallback_batches:
            output, fallback_rows, _ = _run_batch(
                config=config,
                output=output,
                batch=fallback_batch,
                route_candidates=route_candidates,
                source_lang=source_lang,
                target_lang=target_lang,
                rows_by_id=rows_by_id,
                memory_dir=memory_dir,
                fallback=True,
                progress_callback=progress_callback,
            )
            artifacts.extend(fallback_rows)
    return output, artifacts
