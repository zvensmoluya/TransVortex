from __future__ import annotations

from transvortex.app.models import (
    AppConfig,
    Chunk,
    PipelineConfig,
    ProviderConfig,
    RouteTarget,
    RoutingConfig,
)
from transvortex.core.translate import translate_chunk


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
