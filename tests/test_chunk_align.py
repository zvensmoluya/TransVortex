from __future__ import annotations

from transvortex.core.aligner import (
    apply_translations,
    dedupe_overlap_segments,
    merge_asr_window_segments,
    normalize_timeline,
    validate_segments,
)
from transvortex.core.chunking import number_and_chunk_segments, plan_translation_chunks
from transvortex.app.models import AppConfig, CapabilityConfig, PipelineConfig, ProviderConfig, RouteTarget, RoutingConfig, Segment


def _planner_config(
    tmp_path,
    *,
    max_batch_lines: int = 1000,
    recommended_output_tokens: int = 0,
    max_output_tokens: int = 0,
    max_context_tokens: int = 0,
) -> AppConfig:
    provider = ProviderConfig(
        name="p1",
        api_type="openai-compatible",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(
            max_batch_lines=max_batch_lines,
            max_context_tokens=max_context_tokens,
            recommended_output_tokens=recommended_output_tokens,
            max_output_tokens=max_output_tokens,
        ),
    )
    return AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )


def test_chunk_and_align_mapping() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="A"),
        Segment(id=2, start=1.0, end=2.0, text_src="B"),
        Segment(id=3, start=2.0, end=3.0, text_src="C"),
    ]
    chunks = number_and_chunk_segments(segments, batch_size=2)
    assert chunks[0].segment_ids == [1, 2]
    assert chunks[1].segment_ids == [3]

    translated = [
        {
            "chunk_id": "c00000",
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": 1, "text_tgt": "甲"}, {"id": 2, "text_tgt": "乙"}],
        },
        {
            "chunk_id": "c00001",
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": 3, "text_tgt": "丙"}],
        },
    ]
    done = apply_translations(segments, translated)
    assert done[0].text_tgt == "甲"
    assert done[1].text_tgt == "乙"
    assert done[2].text_tgt == "丙"


def test_chunk_context_windows_do_not_enter_translate_only_lines() -> None:
    segments = [
        Segment(id=i, start=float(i), end=float(i + 1), text_src=f"line {i}")
        for i in range(1, 7)
    ]
    chunks = number_and_chunk_segments(
        segments,
        batch_size=2,
        context_before_lines=1,
        context_after_lines=2,
    )
    assert chunks[0].lines == ["[1] line 1", "[2] line 2"]
    assert chunks[0].context_before == []
    assert chunks[0].context_after == ["[3] line 3", "[4] line 4"]
    assert chunks[1].lines == ["[3] line 3", "[4] line 4"]
    assert chunks[1].context_before == ["[2] line 2"]
    assert chunks[1].context_after == ["[5] line 5", "[6] line 6"]
    assert chunks[2].lines == ["[5] line 5", "[6] line 6"]
    assert chunks[2].context_before == ["[4] line 4"]
    assert chunks[2].context_after == []


def test_chunk_marks_asr_uncertain_lines_from_confidence_and_density() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="stable line", confidence=-0.1),
        Segment(id=2, start=1.0, end=2.0, text_src="very uncertain", confidence=-1.4),
        Segment(id=3, start=2.0, end=2.2, text_src="too many source characters"),
    ]

    chunks = number_and_chunk_segments(segments, batch_size=3)

    assert chunks[0].asr_uncertain_ids == [2, 3]


def test_capacity_planner_keeps_short_input_in_single_chunk(tmp_path) -> None:
    config = _planner_config(tmp_path)
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src=f"line {i}") for i in range(1, 40)]

    chunks, warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert [warning["message"] for warning in warnings] == [
        "Input token budget disabled for providers without max_context_tokens"
    ]
    assert len(chunks) == 1
    assert chunks[0].segment_ids == list(range(1, 40))


def test_capacity_planner_uses_large_target_chunks(tmp_path) -> None:
    config = _planner_config(tmp_path)
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src=f"line {i}.") for i in range(1, 1001)]

    chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert [len(chunk.segment_ids) for chunk in chunks] == [400, 400, 200]


def test_capacity_planner_respects_provider_max_batch_lines(tmp_path) -> None:
    config = _planner_config(tmp_path, max_batch_lines=180)
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src=f"line {i}.") for i in range(1, 421)]

    chunks, warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert all(len(chunk.segment_ids) <= 180 for chunk in chunks)
    assert warnings[0]["details"]["effective_max_chunk_lines"] == 180


def test_capacity_planner_uses_route_minimum_batch_lines(tmp_path) -> None:
    config = _planner_config(tmp_path, max_batch_lines=1000)
    fallback = ProviderConfig(
        name="p2",
        api_type="openai-compatible",
        base_url="https://fallback.example/v1",
        env_key="KEY2",
        models=["m2"],
        capabilities=CapabilityConfig(max_batch_lines=90),
    )
    config.providers["p2"] = fallback
    config.routing.fallback = [RouteTarget(provider="p2", model="m2")]
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src=f"line {i}.") for i in range(1, 241)]

    chunks, warnings = plan_translation_chunks(config, segments, [config.providers["p1"], fallback])

    assert all(len(chunk.segment_ids) <= 90 for chunk in chunks)
    assert any(warning["details"]["effective_max_chunk_lines"] == 90 for warning in warnings)


def test_capacity_planner_disables_input_budget_when_route_context_unknown(tmp_path) -> None:
    config = _planner_config(tmp_path, max_batch_lines=1000, max_context_tokens=120)
    fallback = ProviderConfig(
        name="p2",
        api_type="openai-compatible",
        base_url="https://fallback.example/v1",
        env_key="KEY2",
        models=["m2"],
        capabilities=CapabilityConfig(max_batch_lines=1000, max_context_tokens=0),
    )
    config.providers["p2"] = fallback
    config.routing.fallback = [RouteTarget(provider="p2", model="m2")]
    config.pipeline.memory.enabled = False
    config.pipeline.translation.context_after_lines = 1
    config.pipeline.translation.chunking.min_chunk_lines = 1
    config.pipeline.translation.chunking.target_chunk_lines = 1
    config.pipeline.translation.chunking.max_chunk_lines = 1
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src="line") for i in range(1, 4)]

    chunks, warnings = plan_translation_chunks(config, segments, [config.providers["p1"], fallback])

    assert chunks[0].meta["max_input_tokens"] == 0
    assert chunks[0].context_after == ["[2] line"]
    assert any("p2" in warning["details"]["providers"] for warning in warnings)


def test_capacity_planner_trims_context_to_input_budget(tmp_path) -> None:
    config = _planner_config(tmp_path, max_context_tokens=180)
    config.pipeline.memory.enabled = False
    config.pipeline.translation.style_prompt = ""
    config.pipeline.translation.system_prompt = ""
    config.pipeline.translation.chunking.input_safety_ratio = 1.0
    config.pipeline.translation.chunking.prompt_overhead_tokens = 80
    config.pipeline.translation.chunking.min_chunk_lines = 2
    config.pipeline.translation.chunking.target_chunk_lines = 2
    config.pipeline.translation.chunking.max_chunk_lines = 2
    config.pipeline.translation.context_before_lines = 4
    config.pipeline.translation.context_after_lines = 4
    segments = [
        Segment(id=i, start=float(i), end=float(i + 1), text_src=("上下文" * 8 if i != 5 else "target"))
        for i in range(1, 10)
    ]

    chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    middle = chunks[2]
    assert middle.lines == ["[5] target", "[6] 上下文上下文上下文上下文上下文上下文上下文上下文"]
    assert len(middle.context_before) < 4 or len(middle.context_after) < 3
    assert middle.meta["dropped_context_before_lines"] + middle.meta["dropped_context_after_lines"] > 0


def test_capacity_planner_reserves_memory_budget(tmp_path) -> None:
    config = _planner_config(tmp_path, max_context_tokens=1000)
    config.pipeline.translation.chunking.input_safety_ratio = 1.0
    config.pipeline.translation.chunking.prompt_overhead_tokens = 80
    config.pipeline.translation.chunking.min_chunk_lines = 1
    config.pipeline.translation.chunking.target_chunk_lines = 1
    config.pipeline.translation.chunking.max_chunk_lines = 1
    config.pipeline.translation.context_before_lines = 3
    config.pipeline.translation.context_after_lines = 3
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src="context line words") for i in range(1, 5)]

    config.pipeline.memory.enabled = False
    no_memory_chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])
    config.pipeline.memory.enabled = True
    config.pipeline.memory.inject.enabled = True
    config.pipeline.memory.inject.intensity = "high"
    config.pipeline.memory.inject.max_prompt_tokens = 120
    memory_chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert memory_chunks[1].meta["memory_reserved_tokens"] == 184
    assert len(memory_chunks[1].context_before) + len(memory_chunks[1].context_after) < (
        len(no_memory_chunks[1].context_before) + len(no_memory_chunks[1].context_after)
    )


def test_capacity_planner_skips_memory_budget_when_inject_disabled(tmp_path) -> None:
    config = _planner_config(tmp_path, max_context_tokens=1000)
    config.pipeline.translation.chunking.input_safety_ratio = 1.0
    config.pipeline.translation.chunking.prompt_overhead_tokens = 80
    config.pipeline.translation.chunking.min_chunk_lines = 1
    config.pipeline.translation.chunking.target_chunk_lines = 1
    config.pipeline.translation.chunking.max_chunk_lines = 1
    config.pipeline.memory.inject.enabled = False
    config.pipeline.memory.inject.max_prompt_tokens = 120
    segments = [Segment(id=i, start=float(i), end=float(i + 1), text_src="context line words") for i in range(1, 5)]

    chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert chunks[1].meta["memory_reserved_tokens"] == 0


def test_capacity_planner_prefers_pause_sentence_boundary(tmp_path) -> None:
    config = _planner_config(tmp_path)
    config.pipeline.translation.chunking.target_chunk_lines = 6
    config.pipeline.translation.chunking.max_chunk_lines = 10
    config.pipeline.translation.chunking.min_chunk_lines = 3
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="a"),
        Segment(id=2, start=1.0, end=2.0, text_src="b"),
        Segment(id=3, start=2.0, end=3.0, text_src="end."),
        Segment(id=4, start=8.0, end=9.0, text_src="next"),
        Segment(id=5, start=9.0, end=10.0, text_src="next"),
        Segment(id=6, start=10.0, end=11.0, text_src="next"),
        Segment(id=7, start=11.0, end=12.0, text_src="next"),
    ]

    chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert chunks[0].segment_ids == [1, 2, 3]


def test_capacity_planner_avoids_uncertain_boundary_when_possible(tmp_path) -> None:
    config = _planner_config(tmp_path)
    config.pipeline.translation.chunking.target_chunk_lines = 4
    config.pipeline.translation.chunking.max_chunk_lines = 8
    config.pipeline.translation.chunking.min_chunk_lines = 3
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="a"),
        Segment(id=2, start=1.0, end=2.0, text_src="uncertain", confidence=-1.5),
        Segment(id=3, start=2.0, end=3.0, text_src="bad boundary."),
        Segment(id=4, start=3.0, end=4.0, text_src="continue"),
        Segment(id=5, start=8.0, end=9.0, text_src="better."),
        Segment(id=6, start=9.0, end=10.0, text_src="next"),
    ]

    chunks, _warnings = plan_translation_chunks(config, segments, config.providers["p1"])

    assert chunks[0].segment_ids == [1, 2, 3, 4]


def test_overlap_dedupe_reassigns_ids() -> None:
    segments = [
        Segment(id=10, start=0.0, end=1.0, text_src="Hello"),
        Segment(id=11, start=0.9, end=1.4, text_src=" hello "),
        Segment(id=12, start=2.0, end=3.0, text_src="World"),
    ]
    out = dedupe_overlap_segments(segments)
    assert [seg.text_src for seg in out] == ["Hello", "World"]
    assert [seg.id for seg in out] == [1, 2]


def test_trusted_region_merge_filters_overlap_context_and_fuzzy_duplicates() -> None:
    windows = [
        (
            {"segment_index": 0, "start": 0.0, "duration": 300.0, "trusted_start": 0.0, "trusted_end": 285.0},
            [
                Segment(id=1, start=10.0, end=12.0, text_src="opening line"),
                Segment(id=2, start=286.0, end=288.0, text_src="context only"),
            ],
        ),
        (
            {"segment_index": 1, "start": 270.0, "duration": 300.0, "trusted_start": 285.0, "trusted_end": 555.0},
            [
                Segment(id=3, start=283.0, end=284.0, text_src="context only"),
                Segment(id=4, start=300.0, end=302.0, text_src="This is almost the same subtitle line."),
                Segment(id=5, start=301.0, end=303.0, text_src="This is almost the same subtitle lines"),
                Segment(id=6, start=310.0, end=311.0, text_src="No"),
                Segment(id=7, start=310.2, end=311.2, text_src="No"),
            ],
        ),
    ]

    out = merge_asr_window_segments(windows, fuzzy_dedupe=True)

    assert [seg.text_src for seg in out] == ["opening line", "This is almost the same subtitle line.", "No"]
    assert [seg.id for seg in out] == [1, 2, 3]


def test_timeline_normalization_and_quality_warnings() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="A", text_tgt="short"),
        Segment(id=2, start=0.5, end=0.4, text_src="B", text_tgt="x" * 80),
    ]
    normalized = normalize_timeline(segments)
    assert normalized[1].start > normalized[0].end
    assert normalized[1].end > normalized[1].start
    errors, warnings = validate_segments(normalized, max_cps=20, max_line_chars=42)
    assert errors == []
    assert any("max cps" in warning for warning in warnings)
    assert any("line too long" in warning for warning in warnings)
