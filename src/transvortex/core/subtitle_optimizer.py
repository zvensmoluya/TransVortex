from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any

from ..app.models import Segment, SubtitleQualityConfig
from .subtitle_quality import clean_subtitle_text, subtitle_line_width, wrap_subtitle_text


_QUALITY_EPSILON = 1e-6


@dataclass
class SubtitleQualityIssue:
    code: str
    level: str
    message: str


@dataclass
class SubtitleQualityRow:
    id: int
    start: float
    end: float
    duration: float
    cps: float
    max_line_width: int
    line_count: int
    actions: list[str]
    issues: list[SubtitleQualityIssue]


@dataclass
class SubtitleOptimizationResult:
    segments: list[Segment]
    report: dict[str, Any]


def subtitle_cps(seg: Segment) -> float:
    text = clean_subtitle_text(seg.text_tgt or seg.text_src)
    duration = max(float(seg.end) - float(seg.start), 0.001)
    return len(text) / duration


def _line_metrics(text: str, *, max_line_width: int) -> tuple[list[str], int]:
    lines = wrap_subtitle_text(text, max_line_width=max_line_width)
    return lines, max((subtitle_line_width(line) for line in lines), default=0)


def _segment_text(seg: Segment) -> str:
    return clean_subtitle_text(seg.text_tgt or seg.text_src)


def _with_text_cleanup(seg: Segment) -> tuple[Segment, list[str]]:
    actions: list[str] = []
    cleaned_src = clean_subtitle_text(seg.text_src)
    cleaned_tgt = None if seg.text_tgt is None else clean_subtitle_text(seg.text_tgt)
    if cleaned_src != seg.text_src or cleaned_tgt != seg.text_tgt:
        actions.append("clean_text")
    return replace(seg, text_src=cleaned_src, text_tgt=cleaned_tgt), actions


def _quality_row(seg: Segment, config: SubtitleQualityConfig, actions: list[str]) -> SubtitleQualityRow:
    text = _segment_text(seg)
    duration = max(float(seg.end) - float(seg.start), 0.0)
    cps = len(text) / max(duration, 0.001)
    lines, max_width = _line_metrics(text, max_line_width=config.max_line_width)
    issues: list[SubtitleQualityIssue] = []
    if duration + _QUALITY_EPSILON < config.min_duration_seconds:
        issues.append(
            SubtitleQualityIssue(
                code="duration_too_short",
                level="WARN",
                message=f"duration {duration:.2f}s < {config.min_duration_seconds:.2f}s",
            )
        )
    if cps > config.hard_max_cps + _QUALITY_EPSILON:
        issues.append(
            SubtitleQualityIssue(
                code="cps_too_high",
                level="WARN",
                message=f"cps {cps:.1f} > {config.hard_max_cps}",
            )
        )
    if len(lines) > config.max_lines:
        issues.append(
            SubtitleQualityIssue(
                code="too_many_lines",
                level="WARN",
                message=f"line count {len(lines)} > {config.max_lines}",
            )
        )
    if max_width > config.max_line_width:
        issues.append(
            SubtitleQualityIssue(
                code="line_too_wide",
                level="WARN",
                message=f"line width {max_width} > {config.max_line_width}",
            )
        )
    return SubtitleQualityRow(
        id=seg.id,
        start=float(seg.start),
        end=float(seg.end),
        duration=duration,
        cps=cps,
        max_line_width=max_width,
        line_count=len(lines),
        actions=actions,
        issues=issues,
    )


def _residual_counts(rows: list[SubtitleQualityRow], config: SubtitleQualityConfig) -> dict[str, int]:
    return {
        "under_min_duration": sum(1 for row in rows if row.duration + _QUALITY_EPSILON < config.min_duration_seconds),
        "under_one_second": sum(1 for row in rows if row.duration + _QUALITY_EPSILON < 1.0),
        "over_max_duration": sum(1 for row in rows if row.duration > config.max_duration_seconds + _QUALITY_EPSILON),
        "over_hard_cps": sum(1 for row in rows if row.cps > config.hard_max_cps + _QUALITY_EPSILON),
        "too_many_lines": sum(1 for row in rows if row.line_count > config.max_lines),
        "line_too_wide": sum(1 for row in rows if row.max_line_width > config.max_line_width),
    }


def _quality_status(residual_counts: dict[str, int], mode: str) -> str:
    if mode == "off":
        return "OFF"
    if (
        residual_counts.get("under_min_duration", 0)
        or residual_counts.get("over_hard_cps", 0)
        or residual_counts.get("too_many_lines", 0)
        or residual_counts.get("line_too_wide", 0)
    ):
        return "FAIL"
    if residual_counts.get("under_one_second", 0) or residual_counts.get("over_max_duration", 0):
        return "WARN"
    return "PASS"


def _report_payload(rows: list[SubtitleQualityRow], mode: str, config: SubtitleQualityConfig) -> dict[str, Any]:
    issue_counts: dict[str, int] = {}
    action_counts: dict[str, int] = {}
    for row in rows:
        for issue in row.issues:
            issue_counts[issue.code] = issue_counts.get(issue.code, 0) + 1
        for action in row.actions:
            action_counts[action] = action_counts.get(action, 0) + 1
    residual_counts = _residual_counts(rows, config)
    return {
        "summary": {
            "mode": mode,
            "status": _quality_status(residual_counts, mode),
            "segments": len(rows),
            "segments_with_issues": sum(1 for row in rows if row.issues),
            "issue_counts": issue_counts,
            "residual_counts": residual_counts,
            "action_counts": action_counts,
            "max_cps": max((row.cps for row in rows), default=0.0),
            "thresholds": {
                "target_cps": config.target_cps,
                "hard_max_cps": config.hard_max_cps,
                "max_line_width": config.max_line_width,
                "max_lines": config.max_lines,
                "min_duration_seconds": config.min_duration_seconds,
                "max_duration_seconds": config.max_duration_seconds,
                "min_gap_seconds": config.min_gap_seconds,
            },
        },
        "segments": [
            {
                "id": row.id,
                "start": row.start,
                "end": row.end,
                "duration": row.duration,
                "cps": row.cps,
                "max_line_width": row.max_line_width,
                "line_count": row.line_count,
                "actions": row.actions,
                "issues": [
                    {
                        "code": issue.code,
                        "level": issue.level,
                        "message": issue.message,
                    }
                    for issue in row.issues
                ],
            }
            for row in rows
        ],
    }


def _can_merge(left: Segment, right: Segment, config: SubtitleQualityConfig) -> bool:
    gap = float(right.start) - float(left.end)
    if gap < -0.001 or gap > 0.35:
        return False
    duration = float(right.end) - float(left.start)
    if duration > config.max_duration_seconds:
        return False
    text_tgt = "\n".join(
        item
        for item in [
            clean_subtitle_text(left.text_tgt),
            clean_subtitle_text(right.text_tgt),
        ]
        if item
    )
    text_src = "\n".join(
        item
        for item in [
            clean_subtitle_text(left.text_src),
            clean_subtitle_text(right.text_src),
        ]
        if item
    )
    merged = replace(left, end=right.end, text_src=text_src, text_tgt=text_tgt or None)
    row = _quality_row(merged, config, [])
    return row.cps <= config.hard_max_cps and row.line_count <= config.max_lines


def _merge_segments(left: Segment, right: Segment) -> Segment:
    source_ids = []
    for seg in [left, right]:
        raw_ids = seg.meta.get("source_ids") if isinstance(seg.meta, dict) else None
        if isinstance(raw_ids, list):
            source_ids.extend(int(item) for item in raw_ids)
        else:
            source_ids.append(int(seg.id))
    text_tgt = "\n".join(
        item
        for item in [
            clean_subtitle_text(left.text_tgt),
            clean_subtitle_text(right.text_tgt),
        ]
        if item
    )
    text_src = "\n".join(
        item
        for item in [
            clean_subtitle_text(left.text_src),
            clean_subtitle_text(right.text_src),
        ]
        if item
    )
    meta = dict(left.meta)
    meta["source_ids"] = source_ids
    return replace(left, end=right.end, text_src=text_src, text_tgt=text_tgt or None, meta=meta)


def optimize_subtitles(segments: list[Segment], config: SubtitleQualityConfig) -> SubtitleOptimizationResult:
    mode = "off" if not config.enabled else (config.mode or "balanced").lower()
    ordered = sorted(segments, key=lambda seg: (seg.start, seg.end, seg.id))
    if mode == "off":
        rows = [_quality_row(seg, config, []) for seg in ordered]
        return SubtitleOptimizationResult(segments=ordered, report=_report_payload(rows, mode, config))

    optimized: list[Segment] = []
    pending = list(ordered)
    idx = 0
    while idx < len(pending):
        seg, actions = _with_text_cleanup(pending[idx])
        if (
            mode == "balanced"
            and config.merge_short_segments
            and idx + 1 < len(pending)
            and float(seg.end) - float(seg.start) < config.min_duration_seconds
            and _can_merge(seg, pending[idx + 1], config)
        ):
            seg = _merge_segments(seg, pending[idx + 1])
            actions.append("merge_next")
            idx += 1
        if actions:
            meta = dict(seg.meta)
            meta["_quality_actions"] = list(actions)
            seg = replace(seg, meta=meta)
        optimized.append(seg)
        idx += 1

    adjusted: list[Segment] = []
    for idx, seg in enumerate(optimized):
        actions = list(seg.meta.get("_quality_actions", [])) if isinstance(seg.meta.get("_quality_actions"), list) else []
        start = max(0.0, float(seg.start))
        if adjusted and start < adjusted[-1].end + config.min_gap_seconds:
            start = adjusted[-1].end + config.min_gap_seconds
            actions.append("shift_start")
        end = max(float(seg.end), start + 0.001)
        next_start = None
        if idx + 1 < len(optimized):
            next_start = max(0.0, float(optimized[idx + 1].start))
        cap = next_start - config.min_gap_seconds if next_start is not None else None
        if config.adjust_timing:
            min_end = start + config.min_duration_seconds
            if end < min_end and (cap is None or min_end <= cap):
                end = min_end
                actions.append("extend_min_duration")
            text = _segment_text(seg)
            target_duration = min(config.max_duration_seconds, len(text) / max(config.target_cps, 1))
            target_end = start + max(config.min_duration_seconds, target_duration)
            if end < target_end and (cap is None or target_end <= cap):
                end = target_end
                actions.append("extend_target_cps")
        if cap is not None and end > cap:
            end = max(start + 0.001, cap)
            actions.append("cap_before_next")
        meta = dict(seg.meta)
        meta["_quality_actions"] = actions
        adjusted.append(replace(seg, start=start, end=end, meta=meta))

    rows: list[SubtitleQualityRow] = []
    final_segments: list[Segment] = []
    for seg in adjusted:
        actions = list(seg.meta.get("_quality_actions", [])) if isinstance(seg.meta.get("_quality_actions"), list) else []
        meta = dict(seg.meta)
        meta.pop("_quality_actions", None)
        clean_seg = replace(seg, meta=meta)
        final_segments.append(clean_seg)
        rows.append(_quality_row(clean_seg, config, actions))
    return SubtitleOptimizationResult(segments=final_segments, report=_report_payload(rows, mode, config))
