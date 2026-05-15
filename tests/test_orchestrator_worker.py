from __future__ import annotations

import json
import shutil
from pathlib import Path

from transvortex.core.orchestrator import resume_pipeline, run_pipeline, task_status_json
from transvortex.artifacts.task_store import TaskStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
chunk_seconds: 60
chunk_overlap_seconds: 1
translation_batch_size: 2
default_concurrency: 1
max_cps: 8
asr:
  mode: local
  model_size: tiny
  device: cpu
  compute_type: int8
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
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )


class FakeAsrEngine:
    calls: list[str] = []

    def __init__(self, **_kwargs) -> None:
        pass

    def transcribe_segment(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        self.calls.append(audio_path.name)
        if segment_start_offset == 0:
            return [
                {"start": 0.0, "end": 1.0, "text": "Hello"},
                {"start": 1.2, "end": 2.0, "text": "World"},
            ]
        return [
            {"start": segment_start_offset, "end": segment_start_offset + 0.8, "text": "Hello"},
            {"start": segment_start_offset + 1.0, "end": segment_start_offset + 1.6, "text": "Again"},
        ]


def test_worker_pipeline_artifacts_events_and_resume(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 61.0}

    def fake_split_audio_for_asr(
        _audio_path: Path,
        segments_dir: Path,
        *,
        mode: str,
        window_seconds: int,
        overlap_seconds: int,
        short_audio_seconds: int,
        duration_seconds: float,
    ) -> list[dict]:
        assert mode == "auto"
        assert window_seconds == 300
        assert overlap_seconds == 30
        assert short_audio_seconds == 300
        assert duration_seconds == 61.0
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        second = segments_dir / "part_00001.wav"
        first.write_bytes(b"one")
        second.write_bytes(b"two")
        return [
            {
                "segment_index": 0,
                "start": 0.0,
                "duration": 60.0,
                "trusted_start": 0.0,
                "trusted_end": 59.5,
                "path": str(first),
            },
            {
                "segment_index": 1,
                "start": 59.0,
                "duration": 2.0,
                "trusted_start": 59.5,
                "trusted_end": 61.0,
                "path": str(second),
            },
        ]

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None):
        assert source_lang == "en"
        assert target_lang == "zh-CN"
        already_done = already_done or set()
        rows = []
        for chunk in chunks:
            if chunk.chunk_id in already_done:
                continue
            rows.append(
                {
                    "chunk_id": chunk.chunk_id,
                    "provider": "p1",
                    "model": "m1",
                    "compat_mode": "openai_chat",
                    "base_url": "https://example.com/v1",
                    "rows": [{"id": seg_id, "text_tgt": "translated " + ("x" * 40)} for seg_id in chunk.segment_ids],
                    "errors": [],
                }
            )
        return rows

    FakeAsrEngine.calls = []
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.status == "DONE"
    assert task.output_path and Path(task.output_path).exists()
    assert task.output_paths["srt"] == task.output_path
    assert task_status_json(task)["status"] == "DONE"

    task_dir = store.task_dir(task.task_id)
    for rel in [
        "task.json",
        "checkpoint.json",
        "events.jsonl",
        "media",
        "asr",
        "chunks",
        "translate",
        "final",
        "quality",
        "output",
    ]:
        assert (task_dir / rel).exists()

    events = store.read_events(task.task_id)
    assert any(event["type"] == "done" for event in events)
    assert any(event["type"] == "warning" and "max cps" in event["message"] for event in events)
    assert (task_dir / "translate" / "segments.translated.jsonl").exists()
    assert (task_dir / "translate" / "validation.jsonl").exists()
    assert (task_dir / "final" / "segments.aligned.json").exists()
    quality = json.loads((task_dir / "quality" / "subtitle_quality.json").read_text(encoding="utf-8"))
    assert quality["summary"]["segments"] >= 1
    assert len(FakeAsrEngine.calls) == 2

    resumed_id = resume_pipeline(root_dir=root, task_id=task.task_id)
    resumed = store.load_task(resumed_id)
    assert resumed.status == "DONE"
    assert len(FakeAsrEngine.calls) == 2
    checkpoint = json.loads((task_dir / "checkpoint.json").read_text(encoding="utf-8"))
    assert "error" not in checkpoint


def test_pipeline_can_export_srt_and_ass_and_freeze_translation_settings(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "trusted_start": 0.0, "trusted_end": 1.0, "path": str(first)}]

    def fake_translate_all_chunks(config, chunks, source_lang: str, target_lang: str, already_done=None):
        assert config.pipeline.translation.style_prompt == "Use dramatic subtitles."
        assert config.pipeline.translation.style_preset == "localized"
        already_done = already_done or set()
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "你好"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in chunks
            if chunk.chunk_id not in already_done
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=True,
        cli_overrides={
            "output_format": "both",
            "translation_style_preset": "localized",
            "translation_style_prompt": "Use dramatic subtitles.",
            "translation_chunk_lines": 8,
        },
    )
    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)

    assert task.status == "DONE"
    assert set(task.output_paths) == {"srt", "ass"}
    assert Path(task.output_paths["srt"]).exists()
    assert Path(task.output_paths["ass"]).exists()
    assert task.output_paths["srt"].endswith("demo.zh-CN.srt")
    assert task.output_paths["ass"].endswith("demo.zh-CN.ass")
    assert task.output_path == task.output_paths["srt"]
    assert task.settings["output_format"] == "both"
    assert task.settings["translation"]["style_preset"] == "localized"
    assert task.settings["translation"]["style_prompt"] == "Use dramatic subtitles."
    assert task.settings["translation"]["chunk_lines"] == 8
    events = store.read_events(task_id)
    done = next(event for event in events if event["type"] == "done")
    assert set(done["details"]["output_paths"]) == {"srt", "ass"}
    assert any(event["stage"] == "QUALITY" and event["type"] == "artifact" for event in events)


def test_resume_backfills_missing_translation_validation_without_retranslation(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "trusted_start": 0.0, "trusted_end": 1.0, "path": str(first)}]

    call_count = {"requested_chunks": 0}

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None):
        already_done = already_done or set()
        todo = [chunk for chunk in chunks if chunk.chunk_id not in already_done]
        call_count["requested_chunks"] += len(todo)
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "ok"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in todo
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    validation_file = task_dir / "translate" / "validation.jsonl"
    validation_file.unlink()
    checkpoint_file = task_dir / "checkpoint.json"
    checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
    checkpoint["error"] = "old failure"
    checkpoint_file.write_text(json.dumps(checkpoint), encoding="utf-8")

    call_count["requested_chunks"] = 0
    resume_pipeline(root_dir=root, task_id=task_id)

    assert call_count["requested_chunks"] == 0
    final_checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
    assert "error" not in final_checkpoint
    events = store.read_events(task_id)
    assert any("Backfilled validation" in event["message"] for event in events)
    rows = [json.loads(line) for line in validation_file.read_text(encoding="utf-8").splitlines()]
    assert rows
    assert all(not row["issues"] for row in rows)


def test_status_reports_translation_attempt_detail_and_resume_clears_checkpoint_error(
    tmp_path: Path,
    monkeypatch,
) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "segments.jsonl"
    input_file.write_text(
        "\n".join(
            [
                json.dumps({"id": 1, "start": 0, "end": 1, "text_src": "Hello"}),
                json.dumps({"id": 2, "start": 1, "end": 2, "text_src": "World"}),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": []})

    call_count = {"value": 0}

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None, progress_callback=None):
        already_done = already_done or set()
        for chunk in chunks:
            if chunk.chunk_id in already_done:
                continue
            call_count["value"] += 1
            if progress_callback is not None:
                progress_callback(
                    {
                        "mode": "translate",
                        "chunk_id": chunk.chunk_id,
                        "provider": "p1",
                        "model": "m1",
                        "attempt": 1,
                        "max_attempts": 3,
                        "memory_entries": 0,
                    }
                )
            if call_count["value"] == 1:
                raise RuntimeError("All translation routes failed: [{'error_type': 'gateway_timeout'}]")
            yield {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "ok"} for seg_id in chunk.segment_ids],
                "errors": [],
            }

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    try:
        run_pipeline(
            root_dir=root,
            input_file=input_file,
            source_lang="en",
            target_lang="zh-CN",
            input_type="segments_translate",
            cli_overrides={"translation_chunk_lines": 1},
        )
    except Exception:
        pass
    else:
        raise AssertionError("expected first translation attempt to fail")

    store = TaskStore(root / "artifacts")
    task = store.list_tasks()[0]
    checkpoint_file = store.checkpoint_file(task.task_id)
    checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
    assert checkpoint["error_info"]["type"] == "provider_timeout"
    assert checkpoint["translate_current_chunk"] == "c00000"
    status = task_status_json(store.load_task(task.task_id), store=store)
    assert status["progress_detail"]["translate_current_chunk"] == "c00000"
    assert status["progress_detail"]["translate_current_attempt"] == 1
    events = store.read_events(task.task_id)
    assert any(event["type"] == "provider_attempt" for event in events)

    call_count["value"] = 1
    resume_pipeline(root_dir=root, task_id=task.task_id, cli_overrides={"translation_chunk_lines": 1})

    final_checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
    assert "error" not in final_checkpoint
    assert "error_info" not in final_checkpoint
    assert final_checkpoint["status"] == "DONE"


def test_resume_rebuilds_missing_asr_artifact_even_if_checkpoint_says_done(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "trusted_start": 0.0, "trusted_end": 1.0, "path": str(first)}]

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None):
        already_done = already_done or set()
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "ok"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in chunks
            if chunk.chunk_id not in already_done
        ]

    FakeAsrEngine.calls = []
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    asr_file = task_dir / "asr" / "segment_00000.json"
    asr_file.unlink()

    resume_pipeline(root_dir=root, task_id=task_id)

    assert asr_file.exists()
    assert FakeAsrEngine.calls.count("part_00000.wav") == 2


def test_video_auto_source_uses_matching_embedded_subtitle_and_skips_asr(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mkv"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fail_asr(*_args, **_kwargs):
        raise AssertionError("ASR should not run when matching embedded subtitles are available")

    def fake_list_subtitle_streams(_path: Path) -> list[dict]:
        return [
            {
                "index": 2,
                "codec_name": "subrip",
                "language": "en",
                "title": "English",
                "default": True,
                "forced": False,
                "supported": True,
            }
        ]

    def fake_extract_subtitle_stream(_video_path: Path, output_srt: Path, *, stream_index: int) -> None:
        assert stream_index == 2
        output_srt.parent.mkdir(parents=True, exist_ok=True)
        output_srt.write_text("1\n00:00:00,000 --> 00:00:01,000\nHello\n", encoding="utf-8")

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None):
        return [
            {
                "chunk_id": chunks[0].chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "你好"} for seg_id in chunks[0].segment_ids],
                "errors": [],
            }
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", fail_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.list_subtitle_streams", fake_list_subtitle_streams)
    monkeypatch.setattr("transvortex.core.orchestrator.extract_subtitle_stream", fake_extract_subtitle_stream)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")

    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    assert (task_dir / "media" / "embedded_subtitle.srt").exists()
    assert (task_dir / "media" / "subtitle_streams.json").exists()
    assert (task_dir / "asr" / "segments.raw.jsonl").exists()
    events = store.read_events(task_id)
    warning = next(event for event in events if "Auto-selected embedded subtitle stream" in event.get("message", ""))
    assert warning["level"] == "warning"
    assert warning["details"]["stream"]["index"] == 2


def test_worker_streams_events_and_route_override(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "trusted_start": 0.0, "trusted_end": 1.0, "path": str(first)}]

    def fake_translate_all_chunks(config, chunks, source_lang: str, target_lang: str, already_done=None):
        assert config.routing.primary.provider == "p1"
        assert config.routing.primary.model == "m1"
        return [
            {
                "chunk_id": chunks[0].chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "ok"} for seg_id in chunks[0].segment_ids],
                "errors": [],
            }
        ]

    streamed: list[dict] = []
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        provider_name="p1",
        model="m1",
        event_sink=streamed.append,
    )

    assert task_id
    assert any(event["type"] == "task_created" for event in streamed)
    assert any(event["type"] == "done" for event in streamed)
