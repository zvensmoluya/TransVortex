from __future__ import annotations

import re

from typing import Any

from ..app.models import AppConfig, Chunk, ProviderConfig, Segment
from ..memory.plan import translates_with_memory


LINE_TOKEN_OVERHEAD = 4
CONTEXT_SECTION_OVERHEAD = 24
MEMORY_SECTION_OVERHEAD = 64


def _numbered_line(seg: Segment) -> str:
    return f"[{seg.id}] {seg.text_src}"


def estimate_text_tokens(text: str) -> int:
    cjk = 0
    non_cjk = 0
    for char in str(text or ""):
        if char.isspace():
            continue
        codepoint = ord(char)
        if (
            0x3400 <= codepoint <= 0x9FFF
            or 0x3040 <= codepoint <= 0x30FF
            or 0xAC00 <= codepoint <= 0xD7AF
            or 0xF900 <= codepoint <= 0xFAFF
        ):
            cjk += 1
        else:
            non_cjk += 1
    return cjk + max(1 if non_cjk else 0, (non_cjk + 3) // 4)


def estimate_line_tokens(line: str) -> int:
    return estimate_text_tokens(line) + LINE_TOKEN_OVERHEAD


def _estimate_lines_tokens(lines: list[str]) -> int:
    return sum(estimate_line_tokens(line) for line in lines)


def _text_density(text: str, duration_seconds: float) -> float:
    duration = max(duration_seconds, 0.01)
    visible = re.sub(r"\s+", "", text)
    return len(visible) / duration


def _is_asr_uncertain(seg: Segment) -> bool:
    if seg.confidence is not None:
        try:
            # faster-whisper stores avg_logprob here; very low values usually mean unstable recognition.
            if float(seg.confidence) < -1.0:
                return True
        except (TypeError, ValueError):
            pass
    duration = max(0.0, float(seg.end) - float(seg.start))
    text = seg.text_src.strip()
    if duration < 0.4 and len(text) >= 8:
        return True
    if duration > 0.0 and _text_density(text, duration) > 24:
        return True
    return False


def _uncertain_ids(segments: list[Segment]) -> list[int]:
    return [seg.id for seg in segments if _is_asr_uncertain(seg)]


def _chunk_from_slice(
    segments: list[Segment],
    chunk_idx: int,
    start: int,
    end: int,
    *,
    context_before_lines: int = 0,
    context_after_lines: int = 0,
    max_input_tokens: int = 0,
    prompt_overhead_tokens: int = 0,
    memory_reserved_tokens: int = 0,
    provider_names: list[str] | None = None,
    cut_reason: str = "fixed_lines",
) -> Chunk:
    before_start = max(0, start - max(context_before_lines, 0))
    after_end = min(len(segments), end + max(context_after_lines, 0))
    current_segments = segments[start:end]
    current_lines = [_numbered_line(seg) for seg in current_segments]
    raw_context_before = [_numbered_line(item) for item in segments[before_start:start]]
    raw_context_after = [_numbered_line(item) for item in segments[end:after_end]]
    context_before, context_after, budget_meta = trim_context_for_budget(
        lines=current_lines,
        context_before=raw_context_before,
        context_after=raw_context_after,
        max_input_tokens=max_input_tokens,
        prompt_overhead_tokens=prompt_overhead_tokens,
        memory_reserved_tokens=memory_reserved_tokens,
    )
    return Chunk(
        chunk_id=f"c{chunk_idx:05d}",
        segment_ids=[seg.id for seg in current_segments],
        lines=current_lines,
        context_before=context_before,
        context_after=context_after,
        asr_uncertain_ids=_uncertain_ids(current_segments),
        meta={
            "estimated_output_tokens": sum(_estimated_output_tokens(seg) for seg in current_segments),
            "estimated_input_tokens": budget_meta["estimated_input_tokens"],
            "max_input_tokens": max_input_tokens,
            "prompt_overhead_tokens": prompt_overhead_tokens,
            "memory_reserved_tokens": memory_reserved_tokens,
            "context_before_lines": len(context_before),
            "context_after_lines": len(context_after),
            "dropped_context_before_lines": len(raw_context_before) - len(context_before),
            "dropped_context_after_lines": len(raw_context_after) - len(context_after),
            "cut_reason": cut_reason,
            "providers": provider_names or [],
        },
    )


def number_and_chunk_segments(
    segments: list[Segment],
    batch_size: int,
    *,
    context_before_lines: int = 0,
    context_after_lines: int = 0,
) -> list[Chunk]:
    chunks: list[Chunk] = []
    current_ids: list[int] = []
    current_lines: list[str] = []
    chunk_idx = 0
    chunk_start = 0
    for idx, seg in enumerate(segments):
        current_ids.append(seg.id)
        current_lines.append(_numbered_line(seg))
        if len(current_ids) >= batch_size:
            before_start = max(0, chunk_start - max(context_before_lines, 0))
            after_end = min(len(segments), idx + 1 + max(context_after_lines, 0))
            current_segments = segments[chunk_start : idx + 1]
            chunks.append(
                Chunk(
                    chunk_id=f"c{chunk_idx:05d}",
                    segment_ids=current_ids,
                    lines=current_lines,
                    context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                    context_after=[_numbered_line(item) for item in segments[idx + 1 : after_end]],
                    asr_uncertain_ids=_uncertain_ids(current_segments),
                )
            )
            chunk_idx += 1
            chunk_start = idx + 1
            current_ids = []
            current_lines = []
    if current_ids:
        before_start = max(0, chunk_start - max(context_before_lines, 0))
        current_segments = segments[chunk_start:]
        chunks.append(
            Chunk(
                chunk_id=f"c{chunk_idx:05d}",
                segment_ids=current_ids,
                lines=current_lines,
                context_before=[_numbered_line(item) for item in segments[before_start:chunk_start]],
                context_after=[],
                asr_uncertain_ids=_uncertain_ids(current_segments),
            )
        )
    return chunks


def _estimated_output_tokens(seg: Segment) -> int:
    text = str(seg.text_src or "")
    # Subtitle translation is usually shorter than raw source characters, but keep a
    # conservative floor so dense ASR and CJK text still influence planning.
    return max(4, int(estimate_text_tokens(text) * 1.2) + LINE_TOKEN_OVERHEAD)


def _nonzero_min(values: list[int]) -> int:
    nonzero = [max(0, int(item)) for item in values if int(item or 0) > 0]
    return min(nonzero) if nonzero else 0


def _provider_list(provider: ProviderConfig | list[ProviderConfig] | tuple[ProviderConfig, ...] | None) -> list[ProviderConfig]:
    if provider is None:
        return []
    if isinstance(provider, (list, tuple)):
        return [item for item in provider if item is not None]
    return [provider]


def _memory_reserved_tokens(config: AppConfig) -> int:
    if not translates_with_memory(config.pipeline.memory):
        return 0
    return MEMORY_SECTION_OVERHEAD + max(0, int(config.pipeline.memory.inject.max_prompt_tokens))


def translation_prompt_overhead_tokens(config: AppConfig) -> int:
    chunking = config.pipeline.translation.chunking
    return (
        max(0, int(chunking.prompt_overhead_tokens))
        + estimate_text_tokens(config.pipeline.translation.system_prompt)
        + estimate_text_tokens(config.pipeline.translation.style_prompt)
    )


def _input_budget_tokens(config: AppConfig, providers: list[ProviderConfig]) -> tuple[int, list[str]]:
    known_limits = [
        int(provider.capabilities.max_context_tokens)
        for provider in providers
        if int(provider.capabilities.max_context_tokens or 0) > 0
    ]
    warnings: list[str] = []
    if providers and len(known_limits) != len(providers):
        unknown = [
            provider.name
            for provider in providers
            if int(provider.capabilities.max_context_tokens or 0) <= 0
        ]
        warnings.append(", ".join(unknown))
        return 0, warnings
    if not known_limits:
        return 0, warnings
    safety = float(config.pipeline.translation.chunking.input_safety_ratio)
    safety = max(0.1, min(1.0, safety))
    return max(1, int(min(known_limits) * safety)), warnings


def _provider_target_output_tokens(config: AppConfig, providers: list[ProviderConfig] | ProviderConfig | None) -> tuple[int, int]:
    provider_items = _provider_list(providers)
    chunking = config.pipeline.translation.chunking
    hard = max(0, int(chunking.hard_output_tokens or 0))
    target = max(0, int(chunking.target_output_tokens or 0))
    if provider_items:
        provider_hard = _nonzero_min([provider.capabilities.max_output_tokens for provider in provider_items])
        provider_target = _nonzero_min([provider.capabilities.recommended_output_tokens for provider in provider_items])
        if hard <= 0:
            hard = provider_hard
        elif provider_hard > 0:
            hard = min(hard, provider_hard)
        if target <= 0:
            target = provider_target
        elif provider_target > 0:
            target = min(target, provider_target)
        if target <= 0 and hard > 0:
            target = max(1, hard // 2)
        if hard > 0 and target > hard:
            target = hard
    return target, hard


def estimate_prompt_tokens(
    *,
    lines: list[str],
    context_before: list[str],
    context_after: list[str],
    prompt_overhead_tokens: int,
    memory_reserved_tokens: int = 0,
    memory_prompt: str = "",
) -> int:
    memory_tokens = estimate_text_tokens(memory_prompt) if memory_prompt else memory_reserved_tokens
    return (
        max(0, int(prompt_overhead_tokens))
        + memory_tokens
        + CONTEXT_SECTION_OVERHEAD
        + _estimate_lines_tokens(lines)
        + _estimate_lines_tokens(context_before)
        + _estimate_lines_tokens(context_after)
    )


def trim_context_for_budget(
    *,
    lines: list[str],
    context_before: list[str],
    context_after: list[str],
    max_input_tokens: int,
    prompt_overhead_tokens: int,
    memory_reserved_tokens: int = 0,
    memory_prompt: str = "",
) -> tuple[list[str], list[str], dict[str, int]]:
    if max_input_tokens <= 0:
        estimated = estimate_prompt_tokens(
            lines=lines,
            context_before=context_before,
            context_after=context_after,
            prompt_overhead_tokens=prompt_overhead_tokens,
            memory_reserved_tokens=memory_reserved_tokens,
            memory_prompt=memory_prompt,
        )
        return list(context_before), list(context_after), {"estimated_input_tokens": estimated}

    selected_before: list[str] = []
    selected_after: list[str] = []
    base_tokens = estimate_prompt_tokens(
        lines=lines,
        context_before=[],
        context_after=[],
        prompt_overhead_tokens=prompt_overhead_tokens,
        memory_reserved_tokens=memory_reserved_tokens,
        memory_prompt=memory_prompt,
    )
    remaining = max_input_tokens - base_tokens
    if remaining > 0:
        before_reversed = list(reversed(context_before))
        max_distance = max(len(before_reversed), len(context_after))
        for distance in range(max_distance):
            candidates: list[tuple[str, str]] = []
            if distance < len(before_reversed):
                candidates.append(("before", before_reversed[distance]))
            if distance < len(context_after):
                candidates.append(("after", context_after[distance]))
            for side, line in candidates:
                line_tokens = estimate_line_tokens(line)
                if line_tokens > remaining:
                    continue
                if side == "before":
                    selected_before.append(line)
                else:
                    selected_after.append(line)
                remaining -= line_tokens
    selected_before.reverse()
    estimated = estimate_prompt_tokens(
        lines=lines,
        context_before=selected_before,
        context_after=selected_after,
        prompt_overhead_tokens=prompt_overhead_tokens,
        memory_reserved_tokens=memory_reserved_tokens,
        memory_prompt=memory_prompt,
    )
    return selected_before, selected_after, {"estimated_input_tokens": estimated}


def _sentence_boundary_score(text: str) -> int:
    stripped = text.strip()
    if not stripped:
        return 0
    score = 0
    if stripped.endswith((".", "?", "!", "。", "？", "！", "…")):
        score += 8
    if stripped.endswith(('"', "'", "”", "’", "」", "』", "）", ")")):
        score += 2
    if len(stripped) <= 18:
        score += 1
    return score


def _boundary_score(segments: list[Segment], cut_index: int) -> int:
    if cut_index <= 0 or cut_index >= len(segments):
        return -10_000
    previous = segments[cut_index - 1]
    current = segments[cut_index]
    pause = max(0.0, float(current.start) - float(previous.end))
    score = _sentence_boundary_score(previous.text_src)
    if pause >= 2.0:
        score += 12
    elif pause >= 1.0:
        score += 8
    elif pause >= 0.5:
        score += 4
    if _is_asr_uncertain(previous) or _is_asr_uncertain(current):
        score -= 12
    return score


def plan_translation_chunks(
    config: AppConfig,
    segments: list[Segment],
    provider: ProviderConfig | list[ProviderConfig] | tuple[ProviderConfig, ...] | None = None,
) -> tuple[list[Chunk], list[dict[str, Any]]]:
    chunking = config.pipeline.translation.chunking
    if str(chunking.mode or "").lower() != "capacity_aware":
        return (
            number_and_chunk_segments(
                segments,
                max(1, int(config.pipeline.translation.chunk_lines)),
                context_before_lines=config.pipeline.translation.context_before_lines,
                context_after_lines=config.pipeline.translation.context_after_lines,
            ),
            [],
        )
    if not segments:
        return [], []

    warnings: list[dict[str, Any]] = []
    providers = _provider_list(provider)
    provider_names = [item.name for item in providers]
    provider_max_lines = min(max(1, int(item.capabilities.max_batch_lines)) for item in providers) if providers else 0
    configured_max_lines = max(1, int(chunking.max_chunk_lines))
    max_lines = min(configured_max_lines, provider_max_lines) if provider_max_lines else configured_max_lines
    min_lines = max(1, min(int(chunking.min_chunk_lines), max_lines))
    target_lines = max(min_lines, min(int(chunking.target_chunk_lines), max_lines))
    target_tokens, hard_tokens = _provider_target_output_tokens(config, providers)
    max_input_tokens, unknown_context_providers = _input_budget_tokens(config, providers)
    prompt_overhead_tokens = translation_prompt_overhead_tokens(config)
    memory_reserved_tokens = _memory_reserved_tokens(config)
    boundary_window = max(1, int(chunking.boundary_window_lines))
    soft_boundary = bool(chunking.soft_boundary)
    if provider_max_lines and provider_max_lines < configured_max_lines:
        warnings.append(
            {
                "message": "Reduced capacity-aware chunk max lines to provider capability limit",
                "details": {
                    "configured_max_chunk_lines": configured_max_lines,
                    "provider_max_batch_lines": provider_max_lines,
                    "effective_max_chunk_lines": max_lines,
                    "providers": provider_names,
                },
            }
        )
    if unknown_context_providers:
        warnings.append(
            {
                "message": "Input token budget disabled for providers without max_context_tokens",
                "details": {
                    "providers": unknown_context_providers,
                    "known_max_input_tokens": max_input_tokens,
                },
            }
        )

    chunks: list[Chunk] = []
    start = 0
    chunk_idx = 0
    while start < len(segments):
        token_total = 0
        input_token_total = 0
        candidates: list[tuple[int, int]] = []
        cut = start
        cut_reason = "end"
        while cut < len(segments):
            next_line_count = cut - start + 1
            next_tokens = token_total + _estimated_output_tokens(segments[cut])
            next_input_tokens = input_token_total + estimate_line_tokens(_numbered_line(segments[cut]))
            next_prompt_tokens = prompt_overhead_tokens + memory_reserved_tokens + CONTEXT_SECTION_OVERHEAD + next_input_tokens
            if next_line_count > max_lines:
                cut_reason = "max_lines"
                break
            if hard_tokens > 0 and next_line_count >= min_lines and next_tokens > hard_tokens:
                cut_reason = "hard_output_tokens"
                break
            if max_input_tokens > 0 and next_line_count >= min_lines and next_prompt_tokens > max_input_tokens:
                cut_reason = "max_input_tokens"
                break
            token_total = next_tokens
            input_token_total = next_input_tokens
            cut += 1
            line_count = cut - start
            if line_count >= min_lines and soft_boundary and cut < len(segments):
                candidates.append((cut, _boundary_score(segments, cut)))
            if line_count >= target_lines and (target_tokens <= 0 or token_total >= target_tokens):
                cut_reason = "target_lines"
                break
            if target_tokens > 0 and line_count >= min_lines and token_total >= target_tokens:
                cut_reason = "target_output_tokens"
                break

        if cut <= start:
            cut = min(len(segments), start + 1)
            cut_reason = "minimum_single_line"
        line_count = cut - start
        if soft_boundary and candidates and cut < len(segments) and line_count >= min_lines:
            lower = max(start + min_lines, cut - boundary_window)
            upper = min(cut + boundary_window, start + max_lines, len(segments) - 1)
            window_candidates = [item for item in candidates if lower <= item[0] <= upper]
            if not window_candidates:
                for idx in range(lower, upper + 1):
                    if start < idx < len(segments):
                        window_candidates.append((idx, _boundary_score(segments, idx)))
            if window_candidates:
                best_cut, _score = max(window_candidates, key=lambda item: (item[1], -abs(item[0] - cut), item[0]))
                if start < best_cut <= len(segments):
                    cut = best_cut
                    cut_reason = "soft_boundary"

        chunks.append(
            _chunk_from_slice(
                segments,
                chunk_idx,
                start,
                cut,
                context_before_lines=config.pipeline.translation.context_before_lines,
                context_after_lines=config.pipeline.translation.context_after_lines,
                max_input_tokens=max_input_tokens,
                prompt_overhead_tokens=prompt_overhead_tokens,
                memory_reserved_tokens=memory_reserved_tokens,
                provider_names=provider_names,
                cut_reason=cut_reason,
            )
        )
        chunk_idx += 1
        start = cut
    return chunks, warnings
