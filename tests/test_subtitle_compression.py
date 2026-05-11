from __future__ import annotations

from transvortex.app.models import (
    AppConfig,
    NormalizedResponse,
    PipelineConfig,
    ProviderConfig,
    RouteTarget,
    RoutingConfig,
    Segment,
)
from transvortex.core.subtitle_compression import compress_overlong_subtitles


class FakeCompressionClient:
    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, req):
        assert req.prompt_mode == "compress"
        return NormalizedResponse(numbered_lines=["[1] 太长了"], raw_text="[1] 太长了")


class FailingCompressionClient:
    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, _req):
        raise RuntimeError("boom")


class TooLongCompressionClient:
    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, _req):
        return NormalizedResponse(numbered_lines=["[1] 这是一条仍然非常非常长的字幕"], raw_text="[1] 这是一条仍然非常非常长的字幕")


def _config(tmp_path, *, enabled: bool = True) -> AppConfig:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    pipeline = PipelineConfig(artifacts_dir=tmp_path)
    pipeline.subtitle.compression.enabled = enabled
    pipeline.subtitle.quality.hard_max_cps = 5
    pipeline.subtitle.quality.target_cps = 4
    return AppConfig(
        pipeline=pipeline,
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )


def test_compression_shortens_overlong_subtitle(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        "transvortex.core.subtitle_compression.build_provider_client",
        lambda provider: FakeCompressionClient(provider),
    )
    segments = [Segment(id=1, start=0.0, end=1.0, text_src="hello", text_tgt="这是一条非常非常长的字幕")]
    out, artifacts = compress_overlong_subtitles(
        config=_config(tmp_path),
        segments=segments,
        source_lang="en",
        target_lang="zh-CN",
    )
    assert out[0].text_tgt == "太长了"
    assert out[0].meta["compressed"] is True
    assert artifacts[0]["status"] == "compressed"


def test_compression_failure_keeps_original_text(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        "transvortex.core.subtitle_compression.build_provider_client",
        lambda provider: FailingCompressionClient(provider),
    )
    segments = [Segment(id=1, start=0.0, end=1.0, text_src="hello", text_tgt="这是一条非常非常长的字幕")]
    out, artifacts = compress_overlong_subtitles(
        config=_config(tmp_path),
        segments=segments,
        source_lang="en",
        target_lang="zh-CN",
    )
    assert out[0].text_tgt == segments[0].text_tgt
    assert artifacts[0]["status"] == "failed"


def test_compression_rejects_text_that_is_not_shorter_or_readable(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        "transvortex.core.subtitle_compression.build_provider_client",
        lambda provider: TooLongCompressionClient(provider),
    )
    segments = [Segment(id=1, start=0.0, end=1.0, text_src="hello", text_tgt="这是一条非常非常长的字幕")]
    out, artifacts = compress_overlong_subtitles(
        config=_config(tmp_path),
        segments=segments,
        source_lang="en",
        target_lang="zh-CN",
    )
    assert out[0].text_tgt == segments[0].text_tgt
    assert artifacts[0]["status"] == "failed"
    assert "did not shorten" in artifacts[0]["errors"][0]["message"] or "still exceeds" in artifacts[0]["errors"][0]["message"]
