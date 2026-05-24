from __future__ import annotations

import html
import re
from dataclasses import dataclass, fields, replace
from typing import Any, Literal

from ..app.models import AssStyleConfig, Segment
from ..core.subtitle_quality import (
    clean_subtitle_text,
    subtitle_line_width,
    visual_width,
    wrap_subtitle_text,
)


SubtitleFormat = Literal["srt", "ass", "vtt"]


@dataclass(frozen=True)
class SubtitleCanvas:
    width: int = 1920
    height: int = 1080
    safe_margin_x: int = 96
    safe_margin_y: int = 54


@dataclass(frozen=True)
class SubtitleTextBlock:
    role: Literal["target", "source"]
    lines: list[str]
    max_line_width: int
    overflow_lines: int
    overflow_width: int

    @property
    def text(self) -> str:
        return "\n".join(self.lines)


@dataclass(frozen=True)
class SubtitleCueLayout:
    segment_id: int
    start: float
    end: float
    target: SubtitleTextBlock
    source: SubtitleTextBlock | None
    issues: list[dict[str, Any]]


@dataclass(frozen=True)
class SubtitleRenderPlan:
    format: SubtitleFormat
    style: AssStyleConfig
    canvas: SubtitleCanvas
    bilingual: bool
    cues: list[SubtitleCueLayout]


ASS_STYLE_PRESETS: dict[str, dict[str, Any]] = {
    "default": {},
    "bilingual_clean": {},
    "cinematic": {
        "font_size": 39,
        "source_font_size": 25,
        "primary_color": "&H00F6F1EA",
        "source_primary_color": "&H00D2CBC2",
        "outline_color": "&H8A000000",
        "source_outline_color": "&H96000000",
        "back_color": "&H82000000",
        "source_back_color": "&H84000000",
        "outline": 1.35,
        "source_outline": 1.05,
        "shadow": 0.18,
        "source_shadow": 0.14,
        "margin_v": 76,
        "source_margin_v": 128,
        "bilingual_gap": 12,
        "target_max_width": 40,
        "source_max_width": 44,
        "hard_max_width": 52,
    },
    "documentary": {
        "font_size": 42,
        "source_font_size": 29,
        "primary_color": "&H00F2F7F5",
        "source_primary_color": "&H00CBD8D5",
        "outline_color": "&H8C0A0A0A",
        "margin_v": 70,
        "target_max_width": 40,
        "source_max_width": 54,
    },
    "minimal": {
        "font_size": 40,
        "source_font_size": 28,
        "outline": 1.2,
        "shadow": 0.2,
        "back_color": "&H00000000",
        "margin_v": 64,
        "bilingual_gap": 12,
    },
    "mobile_readable": {
        "play_res_x": 1080,
        "play_res_y": 1920,
        "font_size": 54,
        "source_font_size": 38,
        "margin_l": 64,
        "margin_r": 64,
        "safe_margin_x": 64,
        "safe_margin_y": 96,
        "margin_v": 122,
        "source_margin_v": 206,
        "target_max_width": 24,
        "source_max_width": 30,
        "hard_max_width": 34,
        "bilingual_gap": 18,
    },
    "high_contrast": {
        "font_size": 46,
        "source_font_size": 32,
        "primary_color": "&H00FFFFFF",
        "source_primary_color": "&H00E8E8E8",
        "outline_color": "&H00000000",
        "source_outline_color": "&H00000000",
        "outline": 2.5,
        "source_outline": 2.0,
        "shadow": 0.8,
        "back_color": "&H70000000",
    },
    "soft_reading": {
        "font_size": 42,
        "source_font_size": 29,
        "primary_color": "&H00EFEAE2",
        "source_primary_color": "&H00C9C1B8",
        "outline_color": "&HA0000000",
        "source_outline_color": "&HA4000000",
        "outline": 1.3,
        "shadow": 0.3,
        "bilingual_gap": 16,
    },
    "anime": {
        "font_size": 45,
        "source_font_size": 30,
        "primary_color": "&H00F9F6FF",
        "source_primary_color": "&H00D5D0E2",
        "outline": 1.9,
        "shadow": 0.6,
        "target_max_width": 36,
    },
}

_ASS_COLOR_RE = re.compile(r"^&H[0-9A-Fa-f]{8}$")
_STYLE_NAME_RE = re.compile(r"^[A-Za-z0-9_ -]+$")
_WEBVTT_TIMESTAMP_CHARS = re.compile(r"[\r\n\t]")


def resolve_ass_style(style: AssStyleConfig | None = None) -> AssStyleConfig:
    base = style or AssStyleConfig()
    preset_id = str(base.preset or "cinematic").strip().lower()
    overrides = ASS_STYLE_PRESETS.get(preset_id, ASS_STYLE_PRESETS["cinematic"])
    resolved = replace(AssStyleConfig(), preset=preset_id if preset_id in ASS_STYLE_PRESETS else "cinematic")
    for key, value in overrides.items():
        if hasattr(resolved, key):
            resolved = replace(resolved, **{key: value})
    explicit_fields = getattr(base, "_explicit_fields", None)
    default_style = AssStyleConfig()
    for field in fields(AssStyleConfig):
        if field.name == "preset":
            continue
        if explicit_fields is not None:
            if field.name not in explicit_fields:
                continue
        elif getattr(base, field.name) == getattr(default_style, field.name):
            continue
        value = getattr(base, field.name)
        resolved = replace(resolved, **{field.name: value})
    if not resolved.source_font_name:
        resolved = replace(resolved, source_font_name=resolved.font_name)
    return resolved


def style_font_stack(style: AssStyleConfig, *, source: bool = False) -> list[str]:
    primary = style.source_font_name if source and style.source_font_name else style.font_name
    fonts = [primary, *style.font_fallbacks]
    out: list[str] = []
    seen: set[str] = set()
    for font in fonts:
        value = str(font or "").strip()
        if not value or value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def format_font_stack_for_notes(style: AssStyleConfig, *, source: bool = False) -> str:
    return ", ".join(style_font_stack(style, source=source))


def _block(
    role: Literal["target", "source"],
    text: str | None,
    *,
    max_width: int,
    hard_max_width: int,
    max_lines: int,
) -> SubtitleTextBlock:
    lines = wrap_subtitle_text(text, max_line_width=max_width)
    if len(lines) > max_lines and hard_max_width > max_width:
        wider_lines = wrap_subtitle_text(text, max_line_width=hard_max_width)
        if len(wider_lines) <= len(lines):
            lines = wider_lines
    overflow_lines = max(0, len(lines) - max_lines)
    max_line_width = max((subtitle_line_width(line) for line in lines), default=0)
    overflow_width = max(0, max_line_width - max_width)
    return SubtitleTextBlock(
        role=role,
        lines=lines,
        max_line_width=max_line_width,
        overflow_lines=overflow_lines,
        overflow_width=overflow_width,
    )


def _target_text(segment: Segment) -> str:
    return clean_subtitle_text(segment.text_tgt or segment.text_src)


def build_render_plan(
    segments: list[Segment],
    *,
    output_format: SubtitleFormat,
    bilingual: bool,
    style: AssStyleConfig | None = None,
) -> SubtitleRenderPlan:
    resolved = resolve_ass_style(style)
    canvas = SubtitleCanvas(
        width=max(320, int(resolved.play_res_x or 1920)),
        height=max(240, int(resolved.play_res_y or 1080)),
        safe_margin_x=max(0, int(resolved.safe_margin_x or 0)),
        safe_margin_y=max(0, int(resolved.safe_margin_y or 0)),
    )
    cues: list[SubtitleCueLayout] = []
    for segment in segments:
        target = _block(
            "target",
            _target_text(segment),
            max_width=max(8, int(resolved.target_max_width or 38)),
            hard_max_width=max(8, int(resolved.hard_max_width or 56)),
            max_lines=max(1, int(resolved.max_target_lines or 2)),
        )
        source = None
        if bilingual and clean_subtitle_text(segment.text_src):
            source = _block(
                "source",
                segment.text_src,
                max_width=max(8, int(resolved.source_max_width or resolved.target_max_width or 42)),
                hard_max_width=max(8, int(resolved.hard_max_width or 56)),
                max_lines=max(1, int(resolved.max_source_lines or 2)),
            )
        cues.append(
            SubtitleCueLayout(
                segment_id=segment.id,
                start=float(segment.start),
                end=float(segment.end),
                target=target,
                source=source,
                issues=_layout_issues(segment, target=target, source=source, style=resolved, canvas=canvas),
            )
        )
    return SubtitleRenderPlan(
        format=output_format,
        style=resolved,
        canvas=canvas,
        bilingual=bilingual,
        cues=cues,
    )


def _estimated_text_height(block: SubtitleTextBlock, font_size: int, line_spacing: float) -> float:
    if not block.lines:
        return 0.0
    return len(block.lines) * max(1.0, float(font_size)) * max(1.0, float(line_spacing))


def _layout_issues(
    segment: Segment,
    *,
    target: SubtitleTextBlock,
    source: SubtitleTextBlock | None,
    style: AssStyleConfig,
    canvas: SubtitleCanvas,
) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    if target.overflow_lines:
        issues.append(
            {
                "code": "target_too_many_lines",
                "level": "WARN",
                "message": f"target text needs {len(target.lines)} lines",
            }
        )
    if source and source.overflow_lines:
        issues.append(
            {
                "code": "source_too_many_lines",
                "level": "WARN",
                "message": f"source text needs {len(source.lines)} lines",
            }
        )
    hard_max = max(8, int(style.hard_max_width or 56))
    if target.max_line_width > hard_max or (source and source.max_line_width > hard_max):
        issues.append(
            {
                "code": "visual_width_exceeds_hard_limit",
                "level": "WARN",
                "message": f"visual width exceeds {hard_max}",
            }
        )
    text_height = _estimated_text_height(target, style.font_size, style.line_spacing)
    if source:
        text_height += style.bilingual_gap + _estimated_text_height(source, style.source_font_size, style.line_spacing)
    safe_height = max(0, canvas.height - canvas.safe_margin_y * 2)
    if text_height > safe_height * 0.28:
        issues.append(
            {
                "code": "subtitle_stack_tall",
                "level": "WARN",
                "message": f"estimated subtitle stack {text_height:.0f}px may crowd the frame",
            }
        )
    duration = max(float(segment.end) - float(segment.start), 0.0)
    if duration <= 0:
        issues.append({"code": "non_positive_duration", "level": "FAIL", "message": "cue duration must be positive"})
    return issues


def delivery_quality_report(plan: SubtitleRenderPlan) -> dict[str, Any]:
    issue_counts: dict[str, int] = {}
    style_issues = _style_issues(plan.style)
    for issue in style_issues:
        issue_counts[issue["code"]] = issue_counts.get(issue["code"], 0) + 1
    segment_rows: list[dict[str, Any]] = []
    for cue in plan.cues:
        for issue in cue.issues:
            issue_counts[issue["code"]] = issue_counts.get(issue["code"], 0) + 1
        segment_rows.append(
            {
                "id": cue.segment_id,
                "start": cue.start,
                "end": cue.end,
                "target_lines": len(cue.target.lines),
                "source_lines": len(cue.source.lines) if cue.source else 0,
                "target_max_line_width": cue.target.max_line_width,
                "source_max_line_width": cue.source.max_line_width if cue.source else 0,
                "issues": cue.issues,
            }
        )
    status = "PASS"
    if any(issue.get("level") == "FAIL" for issue in style_issues) or any(
        issue.get("level") == "FAIL" for cue in plan.cues for issue in cue.issues
    ):
        status = "FAIL"
    elif issue_counts:
        status = "WARN"
    return {
        "summary": {
            "format": plan.format,
            "status": status,
            "preset": plan.style.preset,
            "segments": len(plan.cues),
            "segments_with_issues": sum(1 for cue in plan.cues if cue.issues),
            "issue_counts": issue_counts,
            "canvas": {
                "width": plan.canvas.width,
                "height": plan.canvas.height,
                "safe_margin_x": plan.canvas.safe_margin_x,
                "safe_margin_y": plan.canvas.safe_margin_y,
            },
            "fonts": {
                "target": format_font_stack_for_notes(plan.style),
                "source": format_font_stack_for_notes(plan.style, source=True),
                "font_file": plan.style.font_file,
            },
        },
        "style_issues": style_issues,
        "segments": segment_rows,
    }


def _style_issues(style: AssStyleConfig) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    for field_name in [
        "primary_color",
        "secondary_color",
        "outline_color",
        "back_color",
        "source_primary_color",
        "source_outline_color",
        "source_back_color",
    ]:
        value = str(getattr(style, field_name, "") or "")
        if value and not _ASS_COLOR_RE.fullmatch(value):
            issues.append({"code": "invalid_ass_color", "level": "FAIL", "message": f"{field_name} is not ASS &HAABBGGRR"})
    if style.bilingual_order not in {"source_target", "target_source"}:
        issues.append({"code": "invalid_bilingual_order", "level": "FAIL", "message": "bilingual_order must be source_target or target_source"})
    if style.border_style not in {1, 3}:
        issues.append({"code": "invalid_ass_border_style", "level": "FAIL", "message": "border_style must be 1 or 3"})
    if style.font_size <= 0 or style.source_font_size <= 0:
        issues.append({"code": "invalid_font_size", "level": "FAIL", "message": "font sizes must be positive"})
    return issues


def ass_text(value: str) -> str:
    return value.replace("\\", r"\\").replace("{", r"\{").replace("}", r"\}").replace("\n", r"\N")


def ass_style_name(value: str) -> str:
    name = value.strip() or "Default"
    if not _STYLE_NAME_RE.fullmatch(name):
        name = re.sub(r"[^A-Za-z0-9_ -]+", "_", name).strip() or "Default"
    return name


def vtt_text(value: str) -> str:
    return "\n".join(_WEBVTT_TIMESTAMP_CHARS.sub(" ", html.escape(line, quote=False)) for line in value.splitlines())


def plain_srt_lines(segment: Segment, *, bilingual: bool, max_line_width: int = 42, source_first: bool = True) -> list[str]:
    source_lines = wrap_subtitle_text(segment.text_src, max_line_width=max_line_width)
    target_lines = wrap_subtitle_text(segment.text_tgt or segment.text_src, max_line_width=max_line_width)
    if not bilingual:
        return target_lines
    return source_lines + target_lines if source_first else target_lines + source_lines


def max_visual_width(lines: list[str]) -> int:
    return max((visual_width(line) for line in lines), default=0)
