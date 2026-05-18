from __future__ import annotations

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
    _build_adaptive_batch_state,
    _iter_translate_all_chunks_adaptive_serial,
    _partition_chunk_to_target_lines,
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


def test_adaptive_translation_splits_retryable_chunk(monkeypatch, tmp_path) -> None:
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

    results = translate_chunk_adaptive(
        config,
        chunk,
        source_lang="en",
        target_lang="zh-CN",
        progress_callback=events.append,
    )

    assert seen_chunks == ["c00000", "c00000s0", "c00000s1"]
    assert [result["chunk_id"] for result in results] == ["c00000s0", "c00000s1"]
    assert all(result["adaptive_parent_chunk"] == "c00000" for result in results)
    assert any(event["mode"] == "adaptive_split" for event in events)


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


def test_adaptive_batch_state_splits_and_grows(tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.translation.chunk_lines = 8
    config.pipeline.translation.batching.min_chunk_lines = 2
    config.pipeline.translation.batching.grow_after_successes = 2
    state = _build_adaptive_batch_state(config)

    state.split()
    assert state.target_lines == 4
    state.split()
    assert state.target_lines == 2
    state.success()
    assert state.target_lines == 2
    state.success()
    assert state.target_lines == 4
    state.success()
    state.success()
    assert state.target_lines == 8


def test_partition_chunk_to_target_lines_uses_stable_adaptive_children() -> None:
    chunk = Chunk(
        chunk_id="c00000",
        segment_ids=[1, 2, 3, 4, 5],
        lines=["[1] A", "[2] B", "[3] C", "[4] D", "[5] E"],
    )

    parts = _partition_chunk_to_target_lines(chunk, 2)

    assert [part.chunk_id for part in parts] == ["c00000s0", "c00000s1s0", "c00000s1s1"]
    assert [part.segment_ids for part in parts] == [[1, 2], [3], [4, 5]]


def test_adaptive_serial_scheduler_shrinks_then_grows(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.default_concurrency = 1
    config.pipeline.translation.chunk_lines = 4
    config.pipeline.translation.batching.mode = "adaptive"
    config.pipeline.translation.batching.min_chunk_lines = 1
    config.pipeline.translation.batching.grow_after_successes = 3
    chunks = [
        Chunk(chunk_id="c00000", segment_ids=[1, 2, 3, 4], lines=["[1] A", "[2] B", "[3] C", "[4] D"]),
        Chunk(chunk_id="c00001", segment_ids=[5, 6, 7, 8], lines=["[5] E", "[6] F", "[7] G", "[8] H"]),
        Chunk(chunk_id="c00002", segment_ids=[9, 10, 11, 12], lines=["[9] I", "[10] J", "[11] K", "[12] L"]),
    ]
    seen: list[str] = []

    def fake_translate_chunk(_config, item, source_lang: str, target_lang: str, memory_prompt: str = "", progress_callback=None):
        seen.append(item.chunk_id)
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

    results = list(
        _iter_translate_all_chunks_adaptive_serial(
            config,
            chunks,
            source_lang="en",
            target_lang="zh-CN",
            already_done=set(),
        )
    )

    assert seen == ["c00000", "c00000s0", "c00000s1", "c00001s0", "c00001s1", "c00002"]
    assert [result["chunk_id"] for result in results] == ["c00000s0", "c00000s1", "c00001s0", "c00001s1", "c00002"]


def test_bootstrap_first_memory_mode_allows_parallel_windows(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.memory.enabled = True
    config.pipeline.memory.mode = "bootstrap_first"
    config.pipeline.default_concurrency = 2
    chunks = [
        Chunk(chunk_id="c00000", segment_ids=[1], lines=["[1] A"]),
        Chunk(chunk_id="c00001", segment_ids=[2], lines=["[2] B"]),
    ]
    seen: list[str] = []

    def fake_submit(_pool, _config, chunk, _source_lang, _target_lang, _memory_prompt, _progress_callback, _already_done=None):
        seen.append(chunk.chunk_id)

        class Done:
            def result(self):
                return {"chunk_id": chunk.chunk_id, "rows": [{"id": chunk.segment_ids[0], "text_tgt": "ok"}]}

        return Done()

    monkeypatch.setattr("transvortex.core.translate._submit_translate_chunk", fake_submit)
    monkeypatch.setattr("transvortex.core.translate.concurrent.futures.as_completed", lambda futures: list(futures))

    list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))

    assert seen == ["c00000", "c00001"]


def test_dynamic_patch_memory_mode_uses_serial_windows(monkeypatch, tmp_path) -> None:
    config = _test_config(tmp_path)
    config.pipeline.memory.enabled = True
    config.pipeline.memory.mode = "dynamic_patch"
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
