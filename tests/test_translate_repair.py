from __future__ import annotations

import pytest

from transvortex.app.models import (
    AppConfig,
    Chunk,
    PipelineConfig,
    ProviderConfig,
    RouteTarget,
    RoutingConfig,
)
from transvortex.core.translate import (
    _adaptive_chunk_by_id,
    _iter_translate_all_chunks_adaptive_serial,
    _source_chunk_completed_count,
    translate_chunk,
    translate_chunk_adaptive,
    iter_translate_all_chunks,
)


class FakeProviderClient:
    calls = 0

    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, req):
        from transvortex.app.models import NormalizedResponse

        FakeProviderClient.calls += 1
        if req.prompt_mode == "repair":
            return NormalizedResponse(numbered_lines=["[1] 你好"], raw_text="[1] 你好")
        return NormalizedResponse(numbered_lines=["[1] "], raw_text="[1] ")


def _test_config(tmp_path) -> AppConfig:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    return AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )


def test_translate_chunk_repairs_empty_row(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    chunk = Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] hello"])
    FakeProviderClient.calls = 0
    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: FakeProviderClient(provider))
    result = translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")
    assert result["rows"] == [{"id": 1, "text_tgt": "你好"}]
    assert result["repairs"][0]["id"] == 1
    assert result["validation"]["issues"] == []
    assert FakeProviderClient.calls == 2


def test_translate_chunk_passes_memory_prompt_to_repair(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    seen_repair_memory = {"value": ""}

    class RepairMemoryClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            if req.prompt_mode == "repair":
                seen_repair_memory["value"] = req.memory_prompt
                return NormalizedResponse(numbered_lines=["[1] 斯巴鲁"], raw_text="[1] 斯巴鲁")
            return NormalizedResponse(numbered_lines=["[1] "], raw_text="[1] ")

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: RepairMemoryClient(provider))
    chunk = Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] Subaru"])
    translate_chunk(
        config,
        chunk,
        source_lang="en",
        target_lang="zh-CN",
        memory_prompt="LOCKED GLOSSARY\n- Subaru => 斯巴鲁",
    )
    assert "Subaru => 斯巴鲁" in seen_repair_memory["value"]


def test_translate_chunk_reports_v2_memory_prompt_entries(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )

    class SuccessClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            from transvortex.app.models import NormalizedResponse

            return NormalizedResponse(numbered_lines=["[1] 昴来了"], raw_text="[1] 昴来了")

    events: list[dict] = []
    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: SuccessClient(provider))
    chunk = Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] Subaru arrives"])
    result = translate_chunk(
        config,
        chunk,
        source_lang="en",
        target_lang="zh-CN",
        memory_prompt=(
            "TRANSLATION MEMORY\n"
            "Use according to policy.\n\n"
            "MUST_USE\n"
            "- Subaru -> 昴 | policy: exact\n"
            "- Emilia -> 爱蜜莉雅 | policy: preferred"
        ),
        progress_callback=events.append,
    )

    assert result["request"]["memory_entries"] == 2
    assert [event["memory_entries"] for event in events if event.get("mode") == "translate"] == [2, 2]


def test_translate_chunk_protocol_recovery_retries_same_chunk(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    chunk = Chunk(chunk_id="c00000", segment_ids=[1, 2], lines=["[1] hello", "[2] world"])
    seen_hints: list[str] = []
    seen_lines: list[list[str]] = []

    class ProtocolRecoveryClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            seen_hints.append(req.protocol_recovery_hint)
            seen_lines.append(list(req.lines))
            if not req.protocol_recovery_hint:
                return NormalizedResponse(
                    numbered_lines=[],
                    raw_text="Here is the translation:\n[1] 你好\n[2] 世界",
                )
            return NormalizedResponse(
                numbered_lines=["[1] 你好", "[2] 世界"],
                raw_text="[1] 你好\n[2] 世界",
            )

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: ProtocolRecoveryClient(provider))

    result = translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")

    assert result["rows"] == [{"id": 1, "text_tgt": "你好"}, {"id": 2, "text_tgt": "世界"}]
    assert seen_lines == [chunk.lines, chunk.lines]
    assert seen_hints[0] == ""
    assert "Previous output failed subtitle protocol validation" in seen_hints[1]
    assert result["request"]["protocol_recovered"] is True


def test_translate_chunk_protocol_recovery_runs_once_per_route(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    chunk = Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] hello"])
    calls = 0

    class AlwaysBadFormatClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            nonlocal calls
            from transvortex.app.models import NormalizedResponse

            calls += 1
            return NormalizedResponse(numbered_lines=[], raw_text="Here is the translation")

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: AlwaysBadFormatClient(provider))

    with pytest.raises(RuntimeError, match="explanatory text|missing translation"):
        translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")

    assert calls == provider.limits.retry + 1


def test_translate_chunk_refusal_does_not_protocol_recover(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    chunk = Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] hello"])
    calls = 0

    class RefusalClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            nonlocal calls
            from transvortex.app.models import NormalizedResponse

            calls += 1
            return NormalizedResponse(numbered_lines=[], raw_text="I cannot translate this.")

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: RefusalClient(provider))

    with pytest.raises(RuntimeError, match="refusal"):
        translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")

    assert calls == config.providers["p1"].limits.retry


def test_translate_chunk_protocol_recovery_can_fall_through_to_row_repair(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.repair.enabled = True
    chunk = Chunk(chunk_id="c00000", segment_ids=[1, 2], lines=["[1] hello", "[2] world"])
    calls: list[str] = []

    class RecoveryThenRepairClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            calls.append(req.prompt_mode if req.prompt_mode == "repair" else ("recovery" if req.protocol_recovery_hint else "translate"))
            if req.prompt_mode == "repair":
                return NormalizedResponse(numbered_lines=["[2] 世界"], raw_text="[2] 世界")
            if not req.protocol_recovery_hint:
                return NormalizedResponse(numbered_lines=[], raw_text="Here is the translation")
            return NormalizedResponse(numbered_lines=["[1] 你好"], raw_text="[1] 你好")

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: RecoveryThenRepairClient(provider))

    result = translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")

    assert calls == ["translate", "recovery", "repair"]
    assert result["rows"] == [{"id": 1, "text_tgt": "你好"}, {"id": 2, "text_tgt": "世界"}]
    assert result["repairs"][0]["id"] == 2


def test_adaptive_translation_does_not_split_gateway_timeout(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2, 3, 4],
        lines=["[1] A", "[2] B", "[3] C", "[4] D"],
    )
    seen_chunks: list[str] = []
    events: list[dict] = []

    def fake_translate_chunk(_config, item, source_lang: str, target_lang: str, memory_prompt: str = "", progress_callback=None):
        seen_chunks.append(item.chunk_id)
        if item.chunk_id == "c00000":
            raise RuntimeError("All translation routes failed: [{'error_type': 'gateway_timeout'}]")
        return {
            "chunk_id": item.chunk_id,
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": seg_id, "text_tgt": f"ok {seg_id}"} for seg_id in item.segment_ids],
            "errors": [],
        }

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)

    with pytest.raises(RuntimeError, match="gateway_timeout"):
        translate_chunk_adaptive(
            config,
            chunk,
            source_lang="en",
            target_lang="zh-CN",
            progress_callback=events.append,
        )

    assert seen_chunks == ["c00000"]
    assert not any(event.get("mode") == "adaptive_split" for event in events)


def test_adaptive_translation_splits_batch_too_large_and_trims_child_context(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    config.pipeline.translation.chunking.input_safety_ratio = 2.0
    config.pipeline.translation.chunking.prompt_overhead_tokens = 40
    config.providers["p1"].capabilities.max_context_tokens = 1000
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2, 3, 4],
        lines=["[1] A", "[2] B", "[3] C", "[4] D"],
        context_before=["[0] " + "before " * 30],
        context_after=["[5] " + "after " * 30],
    )
    seen_contexts: dict[str, tuple[list[str], list[str]]] = {}
    seen_memory_prompts: dict[str, str] = {}

    class BatchLimitClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            first_id = int(req.lines[0].split("]", 1)[0].strip("["))
            chunk_key = "c00000" if len(req.lines) == 4 else ("c00000s0" if first_id == 1 else "c00000s1")
            seen_contexts[chunk_key] = (list(req.context_before), list(req.context_after))
            seen_memory_prompts[chunk_key] = req.memory_prompt
            if len(req.lines) == 4:
                raise RuntimeError("batch too large: 4 > 2")
            return NormalizedResponse(
                numbered_lines=[line.split("]", 1)[0] + "] ok" for line in req.lines],
                raw_text="\n".join(line.split("]", 1)[0] + "] ok" for line in req.lines),
            )

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: BatchLimitClient(provider))

    results = translate_chunk_adaptive(
        config,
        chunk,
        source_lang="en",
        target_lang="zh-CN",
        memory_prompt_builder=lambda item: f"memory for {item.chunk_id}",
    )

    assert [result["chunk_id"] for result in results] == ["c00000s0", "c00000s1"]
    assert "[3] C" in seen_contexts["c00000s0"][1]
    assert "[2] B" in seen_contexts["c00000s1"][0]
    assert seen_memory_prompts["c00000s0"] == "memory for c00000s0"
    assert seen_memory_prompts["c00000s1"] == "memory for c00000s1"


def test_adaptive_translation_adds_capacity_retry_context_hint(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2],
        lines=["[1] A", "[2] B"],
    )
    seen_hints: dict[str, str] = {}

    class BatchLimitClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            seen_hints[req.lines[0]] = req.adaptive_context_hint
            if len(req.lines) == 2:
                raise RuntimeError("request too large")
            return NormalizedResponse(numbered_lines=[req.lines[0].split("]", 1)[0] + "] ok"], raw_text=req.lines[0].split("]", 1)[0] + "] ok")

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: BatchLimitClient(provider))

    results = translate_chunk_adaptive(config, chunk, source_lang="en", target_lang="zh-CN")

    assert [result["chunk_id"] for result in results] == ["c00000s0", "c00000s1"]
    assert "capacity retry" in seen_hints["[1] A"]
    assert "translate only TRANSLATE_ONLY ids" in seen_hints["[2] B"]


def test_translate_chunk_treats_many_missing_rows_as_protocol_failure(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.repair.enabled = True
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=list(range(1, 31)),
        lines=[f"[{idx}] line {idx}" for idx in range(1, 31)],
    )

    class MissingRowsClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            from transvortex.app.models import NormalizedResponse

            return NormalizedResponse(
                numbered_lines=[f"[{idx}] ok {idx}" for idx in range(1, 25)],
                raw_text="\n".join(f"[{idx}] ok {idx}" for idx in range(1, 25)),
            )

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: MissingRowsClient(provider))

    with pytest.raises(RuntimeError) as exc_info:
        translate_chunk(config, chunk, source_lang="en", target_lang="zh-CN")

    message = str(exc_info.value)
    assert "translation protocol incomplete" in message
    assert "truncated" not in message


def test_adaptive_translation_does_not_split_protocol_completion_failure(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    config.pipeline.translation.repair.enabled = False
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=list(range(1, 31)),
        lines=[f"[{idx}] line {idx}" for idx in range(1, 31)],
    )
    events: list[dict] = []

    class MissingRowsClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            from transvortex.app.models import NormalizedResponse

            return NormalizedResponse(
                numbered_lines=[f"[{idx}] ok {idx}" for idx in range(1, 25)],
                raw_text="\n".join(f"[{idx}] ok {idx}" for idx in range(1, 25)),
            )

    monkeypatch.setattr("transvortex.core.translate.build_provider_client", lambda provider: MissingRowsClient(provider))

    with pytest.raises(RuntimeError, match="translation protocol incomplete"):
        translate_chunk_adaptive(
            config,
            chunk,
            source_lang="en",
            target_lang="zh-CN",
            progress_callback=events.append,
        )

    assert not any(event.get("mode") == "adaptive_split" for event in events)


def test_adaptive_translation_respects_min_chunk_lines(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 2
    chunk = Chunk(chunk_id="c00000", segment_ids=[1, 2], lines=["[1] A", "[2] B"])

    def fake_translate_chunk(_config, item, source_lang: str, target_lang: str, memory_prompt: str = "", progress_callback=None):
        raise RuntimeError("All translation routes failed: [{'error_type': 'gateway_timeout'}]")

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)

    try:
        translate_chunk_adaptive(config, chunk, source_lang="en", target_lang="zh-CN")
    except RuntimeError as exc:
        assert "gateway_timeout" in str(exc)
    else:
        raise AssertionError("expected min-size adaptive chunk to fail fast")


def test_adaptive_translation_skips_completed_child_on_resume(monkeypatch, tmp_path) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2, 3, 4],
        lines=["[1] A", "[2] B", "[3] C", "[4] D"],
    )
    seen_chunks: list[str] = []

    def fake_translate_chunk(_config, item, source_lang: str, target_lang: str, memory_prompt: str = "", progress_callback=None):
        seen_chunks.append(item.chunk_id)
        return {
            "chunk_id": item.chunk_id,
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": seg_id, "text_tgt": f"ok {seg_id}"} for seg_id in item.segment_ids],
            "errors": [],
        }

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)

    results = translate_chunk_adaptive(
        config,
        chunk,
        source_lang="en",
        target_lang="zh-CN",
        already_done={"c00000s0"},
    )

    assert seen_chunks == ["c00000s1"]
    assert [result["chunk_id"] for result in results] == ["c00000s1"]


def test_adaptive_child_lookup_and_source_completion_count() -> None:
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2, 3, 4],
        lines=["[1] A", "[2] B", "[3] C", "[4] D"],
    )

    child = _adaptive_chunk_by_id([chunk], "c00000s1s0")

    assert child is not None
    assert child.chunk_id == "c00000s1s0"
    assert child.segment_ids == [3]
    assert _source_chunk_completed_count([chunk], {"c00000s0", "c00000s1"}) == 1
    assert _source_chunk_completed_count([chunk], {"c00000s0"}) == 0


def test_adaptive_serial_scheduler_does_not_shrink_following_chunks(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.default_concurrency = 1
    config.pipeline.translation.chunk_lines = 4
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    chunks = [
        Chunk(chunk_id="c00000", segment_ids=[1, 2, 3, 4], lines=["[1] A", "[2] B", "[3] C", "[4] D"]),
        Chunk(chunk_id="c00001", segment_ids=[5, 6, 7, 8], lines=["[5] E", "[6] F", "[7] G", "[8] H"]),
        Chunk(chunk_id="c00002", segment_ids=[9, 10, 11, 12], lines=["[9] I", "[10] J", "[11] K", "[12] L"]),
    ]
    seen: list[str] = []

    def fake_translate_chunk(_config, item, source_lang: str, target_lang: str, memory_prompt: str = "", progress_callback=None):
        seen.append(item.chunk_id)
        if item.chunk_id == "c00000":
            raise RuntimeError("batch too large: 4 > 2")
        return {
            "chunk_id": item.chunk_id,
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": seg_id, "text_tgt": f"ok {seg_id}"} for seg_id in item.segment_ids],
            "errors": [],
        }

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)

    results = list(
        _iter_translate_all_chunks_adaptive_serial(
            config,
            chunks,
            source_lang="en",
            target_lang="zh-CN",
            already_done=set(),
        )
    )

    assert seen == ["c00000", "c00000s0", "c00000s1", "c00001", "c00002"]
    assert [result["chunk_id"] for result in results] == ["c00000s0", "c00000s1", "c00001", "c00002"]


def test_auto_bootstrap_memory_workflow_allows_parallel_windows(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.memory.workflow = "auto_bootstrap"
    config.pipeline.default_concurrency = 2
    chunks = [
        Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] A"]),
        Chunk(chunk_id="c00001", segment_ids=[2], lines=["[2] B"]),
    ]
    seen: list[str] = []

    def fake_submit(
        _pool,
        _config,
        chunk,
        _source_lang,
        _target_lang,
        _memory_prompt,
        _progress_callback,
        _already_done=None,
        _memory_prompt_builder=None,
    ):
        seen.append(chunk.chunk_id)

        class Done:
            def result(self):
                return {"chunk_id": chunk.chunk_id, "rows": [{"id": chunk.segment_ids[0], "text_tgt": "ok"}]}

        return Done()

    monkeypatch.setattr("transvortex.core.translate._submit_translate_chunk", fake_submit)
    monkeypatch.setattr("transvortex.core.translate.concurrent.futures.as_completed", lambda futures: list(futures))

    list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))

    assert seen == ["c00000", "c00001"]


def test_experimental_dynamic_memory_workflow_uses_serial_windows(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.memory.workflow = "experimental_dynamic"
    config.pipeline.default_concurrency = 2
    chunks = [
        Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] A"]),
        Chunk(chunk_id="c00001", segment_ids=[2], lines=["[2] B"]),
    ]
    window_sizes: list[int] = []

    def fake_iter_window(_config, window, **_kwargs):
        window_sizes.append(len(window))
        for chunk in window:
            yield {"chunk_id": chunk.chunk_id, "rows": [{"id": chunk.segment_ids[0], "text_tgt": "ok"}]}

    monkeypatch.setattr("transvortex.core.translate._iter_translate_window", fake_iter_window)

    list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))

    assert window_sizes == [1, 1]
