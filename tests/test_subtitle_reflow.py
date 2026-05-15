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
from transvortex.core.subtitle_optimizer import optimize_subtitles
from transvortex.core.subtitle_reflow import reflow_subtitles
from transvortex.memory.schema import MemoryDocument, MemoryEntry
from transvortex.memory.store import MemoryStore


class FakeReflowClient:
    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, req):
        assert req.prompt_mode == "reflow"
        assert "duration" in req.repair_reason or "cps" in req.repair_reason
        return NormalizedResponse(
            numbered_lines=[],
            raw_text='{"replacements":[{"source_ids":[1,2],"text_tgt":"短句合并","reason":"merge short fragments"}]}',
        )


class BadReflowClient:
    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, _req):
        return NormalizedResponse(
            numbered_lines=[],
            raw_text='{"replacements":[{"source_ids":[1,2],"text_tgt":"这是一条仍然非常非常长的字幕","reason":"bad"}]}',
        )


class BatchReflowClient:
    calls = []

    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, req):
        BatchReflowClient.calls.append(req)
        assert req.prompt_mode == "reflow"
        assert "window_id: 1" in "\n".join(req.lines)
        assert "window_id: 2" in "\n".join(req.lines)
        return NormalizedResponse(
            numbered_lines=[],
            raw_text=(
                '{"windows":['
                '{"window_id":1,"replacements":[{"source_ids":[1,2],"text_tgt":"短句合并一","reason":"merge"}]},'
                '{"window_id":2,"replacements":[{"source_ids":[4,5],"text_tgt":"短句合并二","reason":"merge"}]}'
                "]}"
            ),
        )


class RetryThenFallbackClient:
    calls = []

    def __init__(self, _provider: ProviderConfig) -> None:
        pass

    def translate_request(self, req):
        RetryThenFallbackClient.calls.append(req)
        if len(req.lines) > 5:
            return NormalizedResponse(numbered_lines=[], raw_text="{bad json")
        text = "\n".join(req.lines)
        if "[1]" in text:
            window_id = 1
            source_ids = [1, 2]
            target = "短句合并一"
        else:
            window_id = 2
            source_ids = [4, 5]
            target = "短句合并二"
        return NormalizedResponse(
            numbered_lines=[],
            raw_text=(
                '{"windows":[{"window_id":'
                + str(window_id)
                + ',"replacements":[{"source_ids":'
                + str(source_ids).replace(" ", "")
                + ',"text_tgt":"'
                + target
                + '","reason":"fallback"}]}]}'
            ),
        )


def _config(tmp_path) -> AppConfig:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    pipeline = PipelineConfig(artifacts_dir=tmp_path)
    pipeline.subtitle.reflow.enabled = True
    pipeline.subtitle.reflow.max_window_segments = 4
    pipeline.subtitle.quality.min_duration_seconds = 0.8
    pipeline.subtitle.quality.hard_max_cps = 10
    pipeline.subtitle.quality.target_cps = 8
    return AppConfig(
        pipeline=pipeline,
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )


def _quality_config(config: AppConfig) -> None:
    config.pipeline.subtitle.quality.min_duration_seconds = 0.8
    config.pipeline.subtitle.quality.hard_max_cps = 10
    config.pipeline.subtitle.quality.target_cps = 8


def _two_failure_segments() -> list[Segment]:
    return [
        Segment(id=1, start=0.0, end=0.1, text_src="Subaru", text_tgt="这是一条很长的字幕"),
        Segment(id=2, start=0.5, end=1.6, text_src="arrives", text_tgt="下一句"),
        Segment(id=3, start=2.0, end=3.0, text_src="ok", text_tgt="正常"),
        Segment(id=4, start=4.0, end=4.1, text_src="Emilia", text_tgt="这是一条很长的字幕"),
        Segment(id=5, start=4.5, end=5.6, text_src="answers", text_tgt="下一句"),
    ]


def test_reflow_merges_quality_failure_window(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: FakeReflowClient(provider))
    config = _config(tmp_path)
    segments = [
        Segment(id=1, start=0.0, end=0.1, text_src="a", text_tgt="这是一条很长的字幕"),
        Segment(id=2, start=0.5, end=1.6, text_src="b", text_tgt="下一句"),
        Segment(id=3, start=2.0, end=3.0, text_src="c", text_tgt="正常"),
    ]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="ja",
        target_lang="zh-CN",
    )

    assert artifacts[0]["status"] == "reflowed"
    assert [seg.id for seg in out] == [1, 3]
    assert out[0].text_tgt == "短句合并"
    assert out[0].meta["source_ids"] == [1, 2]


def test_reflow_rejects_replacement_that_still_fails_quality(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: BadReflowClient(provider))
    config = _config(tmp_path)
    segments = [
        Segment(id=1, start=0.0, end=0.1, text_src="a", text_tgt="这是一条很长的字幕"),
        Segment(id=2, start=0.5, end=0.6, text_src="b", text_tgt="下一句"),
    ]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="ja",
        target_lang="zh-CN",
    )

    assert [seg.id for seg in out] == [1, 2]
    assert artifacts[0]["status"] == "failed"
    assert artifacts[0]["attempts"][0]["status"] == "rejected"


def test_reflow_batches_multiple_windows_and_injects_memory(monkeypatch, tmp_path) -> None:
    BatchReflowClient.calls = []
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: BatchReflowClient(provider))
    config = _config(tmp_path)
    config.pipeline.memory.enabled = True
    config.pipeline.subtitle.reflow.batch_windows = 10
    config.pipeline.subtitle.reflow.max_window_segments = 2
    config.pipeline.subtitle.reflow.context_before_segments = 2
    config.pipeline.subtitle.reflow.context_after_segments = 2
    _quality_config(config)
    memory_dir = tmp_path / "memory"
    memory_store = MemoryStore(memory_dir)
    memory_store.save(
        MemoryDocument(
            entries=[
                MemoryEntry(id="m1", source="Subaru", target="斯巴鲁", status="locked", priority=100),
                MemoryEntry(id="m2", source="Emilia", target="爱蜜莉雅", status="confirmed", priority=90),
            ]
        )
    )
    segments = _two_failure_segments()
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
        memory_dir=memory_dir,
    )

    assert len(BatchReflowClient.calls) == 1
    req = BatchReflowClient.calls[0]
    assert "LOCKED TERMS" in req.memory_prompt
    assert "Subaru => 斯巴鲁" in req.memory_prompt
    assert "Emilia => 爱蜜莉雅" in req.memory_prompt
    assert len(artifacts) == 2
    assert all(row["batch_index"] == 1 for row in artifacts)
    assert all(row["batch_size"] == 2 for row in artifacts)
    assert all(row["memory_entries"] == 2 for row in artifacts)
    assert [seg.id for seg in out] == [1, 3, 4]
    assert out[0].text_tgt == "短句合并一"
    assert out[-1].text_tgt == "短句合并二"


def test_reflow_retries_batch_parse_failure_then_falls_back_to_single_windows(monkeypatch, tmp_path) -> None:
    RetryThenFallbackClient.calls = []
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: RetryThenFallbackClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.batch_windows = 10
    config.pipeline.subtitle.reflow.max_attempts = 2
    config.pipeline.subtitle.reflow.max_window_segments = 2
    _quality_config(config)
    segments = _two_failure_segments()
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(RetryThenFallbackClient.calls) == 4
    assert len(artifacts) == 2
    assert all(row["fallback"] is True for row in artifacts)
    assert all(row["status"] == "reflowed" for row in artifacts)
    assert [seg.id for seg in out] == [1, 3, 4]


def test_reflow_respects_max_windows(monkeypatch, tmp_path) -> None:
    BatchReflowClient.calls = []
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: BatchReflowClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.max_windows = 1
    config.pipeline.subtitle.reflow.max_window_segments = 2
    _quality_config(config)
    segments = _two_failure_segments()
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    _out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(artifacts) == 1
    assert artifacts[0]["window_index"] == 1


def test_reflow_splits_batches_by_input_budget(monkeypatch, tmp_path) -> None:
    class SingleWindowClient:
        calls = []

        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            SingleWindowClient.calls.append(req)
            text = "\n".join(req.lines)
            if "[1]" in text:
                return NormalizedResponse(
                    numbered_lines=[],
                    raw_text='{"windows":[{"window_id":1,"replacements":[{"source_ids":[1,2],"text_tgt":"短句合并一","reason":"merge"}]}]}',
                )
            return NormalizedResponse(
                numbered_lines=[],
                raw_text='{"windows":[{"window_id":2,"replacements":[{"source_ids":[4,5],"text_tgt":"短句合并二","reason":"merge"}]}]}',
            )

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: SingleWindowClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.batch_windows = 10
    config.pipeline.subtitle.reflow.max_input_chars = 2600
    config.pipeline.subtitle.reflow.max_window_segments = 2
    _quality_config(config)
    segments = _two_failure_segments()
    segments[1].text_src = "x" * 900
    segments[4].text_src = "y" * 900
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    _out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(SingleWindowClient.calls) == 2
    assert {row["batch_index"] for row in artifacts} == {1, 2}


def test_reflow_skips_single_window_over_input_budget(monkeypatch, tmp_path) -> None:
    class NeverCalledClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            raise AssertionError("over-budget window should be skipped")

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: NeverCalledClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.batch_windows = 10
    config.pipeline.subtitle.reflow.max_input_chars = 1000
    config.pipeline.subtitle.reflow.max_window_segments = 2
    _quality_config(config)
    segments = [
        Segment(id=1, start=0.0, end=0.1, text_src="x" * 2000, text_tgt="这是一条很长的字幕"),
        Segment(id=2, start=0.5, end=1.6, text_src="next", text_tgt="下一句"),
    ]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert out == segments
    assert artifacts[0]["status"] == "skipped"
    assert artifacts[0]["skipped_reason"] == "reflow_input_budget_exceeded"


def test_reflow_over_budget_window_does_not_skip_next_window(monkeypatch, tmp_path) -> None:
    class SecondWindowClient:
        calls = []

        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            SecondWindowClient.calls.append(req)
            assert "[4]" in "\n".join(req.lines)
            return NormalizedResponse(
                numbered_lines=[],
                raw_text='{"windows":[{"window_id":2,"replacements":[{"source_ids":[4,5],"text_tgt":"短句合并二","reason":"merge"}]}]}',
            )

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: SecondWindowClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.batch_windows = 10
    config.pipeline.subtitle.reflow.max_input_chars = 1200
    config.pipeline.subtitle.reflow.max_window_segments = 2
    _quality_config(config)
    segments = _two_failure_segments()
    segments[0].text_src = "x" * 2000
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(SecondWindowClient.calls) == 1
    assert [row["status"] for row in artifacts] == ["skipped", "reflowed"]
    assert artifacts[0]["window_index"] == 1
    assert artifacts[1]["window_index"] == 2
    assert [seg.id for seg in out] == [1, 2, 3, 4]


def test_reflow_shrinks_context_before_skipping_over_input_budget(monkeypatch, tmp_path) -> None:
    class ContextShrunkClient:
        calls = []

        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            ContextShrunkClient.calls.append(req)
            assert req.context_before == []
            assert req.context_after == []
            return NormalizedResponse(
                numbered_lines=[],
                raw_text='{"windows":[{"window_id":1,"replacements":[{"source_ids":[2,3],"text_tgt":"短句合并","reason":"merge"}]}]}',
            )

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: ContextShrunkClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.max_input_chars = 1300
    config.pipeline.subtitle.reflow.max_window_segments = 2
    config.pipeline.subtitle.reflow.context_before_segments = 1
    config.pipeline.subtitle.reflow.context_after_segments = 1
    _quality_config(config)
    segments = [
        Segment(id=1, start=0.0, end=0.8, text_src="context " + "x" * 1000, text_tgt="上下文"),
        Segment(id=2, start=1.0, end=1.1, text_src="short", text_tgt="这是一条很长的字幕"),
        Segment(id=3, start=1.5, end=2.6, text_src="next", text_tgt="下一句"),
    ]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(ContextShrunkClient.calls) == 1
    assert artifacts[0]["status"] == "reflowed"
    assert [seg.id for seg in out] == [1, 2]


def test_reflow_warn_and_fail_includes_warn_only_duration_rows(monkeypatch, tmp_path) -> None:
    class WarnOnlyClient:
        calls = []

        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, req):
            WarnOnlyClient.calls.append(req)
            assert "duration 0.90s < 1.00s" in req.repair_reason
            return NormalizedResponse(
                numbered_lines=[],
                raw_text='{"windows":[{"window_id":1,"replacements":[{"source_ids":[1,2],"text_tgt":"短句合并","reason":"warn-only"}]}]}',
            )

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: WarnOnlyClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.trigger = "warn_and_fail"
    config.pipeline.subtitle.reflow.max_window_segments = 2
    config.pipeline.subtitle.quality.min_duration_seconds = 0.8
    config.pipeline.subtitle.quality.hard_max_cps = 50
    config.pipeline.subtitle.quality.target_cps = 50
    segments = [
        Segment(id=1, start=0.0, end=0.9, text_src="a", text_tgt="短"),
        Segment(id=2, start=1.2, end=2.4, text_src="b", text_tgt="下一句"),
    ]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report
    assert quality_report["summary"]["status"] == "WARN"
    assert quality_report["summary"]["issue_counts"] == {}

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert len(WarnOnlyClient.calls) == 1
    assert artifacts[0]["status"] == "reflowed"
    assert [seg.id for seg in out] == [1]


def test_reflow_fail_only_ignores_warn_only_duration_rows(monkeypatch, tmp_path) -> None:
    class NeverCalledClient:
        def __init__(self, _provider: ProviderConfig) -> None:
            pass

        def translate_request(self, _req):
            raise AssertionError("warn-only rows should not be reflowed by fail_only")

    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: NeverCalledClient(provider))
    config = _config(tmp_path)
    config.pipeline.subtitle.reflow.trigger = "fail_only"
    config.pipeline.subtitle.quality.min_duration_seconds = 0.8
    config.pipeline.subtitle.quality.hard_max_cps = 50
    segments = [Segment(id=1, start=0.0, end=0.9, text_src="a", text_tgt="短")]
    quality_report = optimize_subtitles(segments, config.pipeline.subtitle.quality).report

    out, artifacts = reflow_subtitles(
        config=config,
        segments=segments,
        quality_report=quality_report,
        source_lang="en",
        target_lang="zh-CN",
    )

    assert out == segments
    assert artifacts == []
