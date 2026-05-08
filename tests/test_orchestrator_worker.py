from __future__ import annotations

import json
import shutil
from pathlib import Path

from transvortex.orchestrator import resume_pipeline, run_pipeline, task_status_json
from transvortex.task_store import TaskStore


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
            {"start": 0.0, "end": 0.8, "text": "Hello"},
            {"start": 1.0, "end": 1.6, "text": "Again"},
        ]


def test_worker_pipeline_artifacts_events_and_resume(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 61.0}

    def fake_split_audio_with_overlap(
        _audio_path: Path,
        segments_dir: Path,
        *,
        chunk_seconds: int,
        overlap_seconds: int,
        duration_seconds: float,
    ) -> list[dict]:
        assert chunk_seconds == 60
        assert overlap_seconds == 1
        assert duration_seconds == 61.0
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        second = segments_dir / "part_00001.wav"
        first.write_bytes(b"one")
        second.write_bytes(b"two")
        return [
            {"segment_index": 0, "start": 0.0, "duration": 60.0, "path": str(first)},
            {"segment_index": 1, "start": 59.0, "duration": 2.0, "path": str(second)},
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
    monkeypatch.setattr("transvortex.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.orchestrator.split_audio_with_overlap", fake_split_audio_with_overlap)
    monkeypatch.setattr("transvortex.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.status == "DONE"
    assert task.output_path and Path(task.output_path).exists()
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
        "output",
    ]:
        assert (task_dir / rel).exists()

    events = store.read_events(task.task_id)
    assert any(event["type"] == "done" for event in events)
    assert any(event["type"] == "warning" and "max cps" in event["message"] for event in events)
    assert (task_dir / "translate" / "segments.translated.jsonl").exists()
    assert (task_dir / "translate" / "validation.jsonl").exists()
    assert len(FakeAsrEngine.calls) == 2

    resumed_id = resume_pipeline(root_dir=root, task_id=task.task_id)
    resumed = store.load_task(resumed_id)
    assert resumed.status == "DONE"
    assert len(FakeAsrEngine.calls) == 2
    checkpoint = json.loads((task_dir / "checkpoint.json").read_text(encoding="utf-8"))
    assert "error" not in checkpoint


def test_resume_backfills_missing_translation_validation_without_retranslation(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_with_overlap(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "path": str(first)}]

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

    monkeypatch.setattr("transvortex.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.orchestrator.split_audio_with_overlap", fake_split_audio_with_overlap)
    monkeypatch.setattr("transvortex.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.orchestrator.translate_all_chunks", fake_translate_all_chunks)

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


def test_resume_rebuilds_missing_asr_artifact_even_if_checkpoint_says_done(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_with_overlap(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "path": str(first)}]

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
    monkeypatch.setattr("transvortex.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.orchestrator.split_audio_with_overlap", fake_split_audio_with_overlap)
    monkeypatch.setattr("transvortex.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    asr_file = task_dir / "asr" / "segment_00000.json"
    asr_file.unlink()

    resume_pipeline(root_dir=root, task_id=task_id)

    assert asr_file.exists()
    assert FakeAsrEngine.calls.count("part_00000.wav") == 2


def test_worker_streams_events_and_route_override(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_with_overlap(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "path": str(first)}]

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
    monkeypatch.setattr("transvortex.orchestrator.extract_audio", fake_extract_audio)
    monkeypatch.setattr("transvortex.orchestrator.split_audio_with_overlap", fake_split_audio_with_overlap)
    monkeypatch.setattr("transvortex.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.orchestrator.translate_all_chunks", fake_translate_all_chunks)

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
