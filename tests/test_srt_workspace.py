from __future__ import annotations

from pathlib import Path

from transvortex.core.orchestrator import run_pipeline
from transvortex.providers.admin import save_provider_routing
from transvortex.artifacts.result_workspace import open_task_result, reexport_task, save_task_segments
from transvortex.formats.srt import parse_srt_text
from transvortex.artifacts.task_store import TaskStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
translation_batch_size: 2
default_concurrency: 1
max_cps: 40
providers:
        """.strip(),
        encoding="utf-8",
    )
    (root / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
  - name: p2
    api_type: openai
    base_url: https://fallback.example/v1
    env_key: PROVIDER_KEY
    models: [m2]
routing:
  primary: {provider: p1, model: m1}
  fallback: []
        """.strip(),
        encoding="utf-8",
    )


def test_parse_srt_text_multiline_and_commas() -> None:
    rows = parse_srt_text(
        """
1
00:00:01,000 --> 00:00:02,500
Hello
world

2
00:00:03.000 --> 00:00:04.000
Next
        """.strip()
    )
    assert len(rows) == 2
    assert rows[0].start == 1.0
    assert rows[0].end == 2.5
    assert rows[0].text_src == "Hello\nworld"


def test_srt_translate_skips_asr_and_result_workspace(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    monkeypatch.setenv("PROVIDER_KEY", "key")
    srt_file = root / "中文 路径.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:02,000
Hello

2
00:00:03,000 --> 00:00:04,000
World
        """.strip(),
        encoding="utf-8",
    )

    def fake_translate_all_chunks(config, chunks, source_lang: str, target_lang: str, already_done=None):
        assert source_lang == "en"
        assert target_lang == "zh-CN"
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": f"译文 {seg_id}"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in chunks
            if chunk.chunk_id not in (already_done or set())
        ]

    def fail_asr(*_args, **_kwargs):
        raise AssertionError("ASR should not run for srt_translate")

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", fail_asr)

    task_id = run_pipeline(
        root_dir=root,
        input_file=srt_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=True,
        input_type="srt_translate",
        cli_overrides={"output_format": "both"},
    )

    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.status == "DONE"
    assert task.settings["input_type"] == "srt_translate"
    assert set(task.output_paths) == {"srt", "ass"}
    assert (store.task_dir(task_id) / "asr" / "segments.raw.jsonl").exists()
    assert not (store.task_dir(task_id) / "media" / "audio_full.m4a").exists()

    result = open_task_result(root_dir=root, task_id=task_id)
    assert result["segments"][0]["provider"] == "p1"
    assert result["segments"][0]["model"] == "m1"

    edited = result["segments"]
    edited[0]["text_tgt"] = "改过的译文"
    saved = save_task_segments(root_dir=root, task_id=task_id, segments_payload=edited)
    assert saved["segments"][0]["text_tgt"] == "改过的译文"
    reexported = reexport_task(root_dir=root, task_id=task_id, output_format="srt")
    assert Path(reexported["output_paths"]["srt"]).read_text(encoding="utf-8").find("改过的译文") >= 0
    events = store.read_events(task_id)
    assert any(event["type"] == "edited" for event in events)
    assert any(event["type"] == "reexported" for event in events)


def test_save_provider_routing_writes_primary_and_fallback(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    payload = save_provider_routing(
        root_dir=root,
        routing={
            "primary": {"provider": "p1", "model": "m1"},
            "fallback": [{"provider": "p2", "model": "m2"}],
        },
    )
    assert payload["routing"]["primary"]["provider"] == "p1"
    assert payload["routing"]["fallback"][0]["model"] == "m2"
    raw = (root / "providers.local.yaml").read_text(encoding="utf-8")
    assert "fallback" in raw
