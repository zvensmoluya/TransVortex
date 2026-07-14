from __future__ import annotations

import json
import shutil
from pathlib import Path
from textwrap import dedent

from transvortex.core.orchestrator import (
    _asr_runs_concurrently,
    _checkpoint_status_payload,
    _translation_progress_callback,
    _write_translation_experiment_artifacts,
    create_pipeline_task,
    resume_pipeline,
    run_pipeline,
    task_status_json,
)
from transvortex.app.config import load_app_config
from transvortex.core.orchestrator import _asr_item_upload_mb, _take_asr_upload_batch
from transvortex.artifacts.task_store import TaskStore
from transvortex.http import HttpTransportError
from transvortex.protocol.errors import PipelineTaskError


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
  provider: faster_whisper_test
asr_providers:
  - name: faster_whisper_test
    kind: local_inprocess
    protocol: faster_whisper
    model: tiny
    local:
      device: cpu
      compute_type: int8
    chunking:
      mode: auto
      window_seconds: 300
      overlap_seconds: 30
      short_audio_seconds: 300
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


def test_checkpoint_status_exposes_structured_asr_progress(tmp_path: Path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task_id = "tvx_progress"
    store.save_checkpoint(
        task_id,
        {
            "status": "ASR",
            "asr_done_segments": [0, 1, 2],
            "asr_done_count": 3,
            "asr_total_segments": 10,
            "source_segment_count": 42,
        },
    )

    payload = _checkpoint_status_payload(store, task_id)

    assert payload["checkpoint_status"] == "ASR"
    assert payload["progress"] == 0.325
    assert payload["progress_detail"]["asr_done_count"] == 3
    assert payload["progress_detail"]["asr_total_segments"] == 10


def test_local_worker_keeps_one_shared_asr_process_when_concurrency_is_higher(tmp_path: Path) -> None:
    _write_config(tmp_path)
    pipeline_path = tmp_path / "pipeline.yaml"
    text = pipeline_path.read_text(encoding="utf-8")
    text = text.replace("kind: local_inprocess", "kind: local_worker")
    text = text.replace(
        "    local:\n      device: cpu",
        "    execution:\n      concurrency: 4\n    local:\n      device: cpu",
    )
    pipeline_path.write_text(text, encoding="utf-8")

    config = load_app_config(root_dir=tmp_path)

    assert config.asr_providers["faster_whisper_test"].execution.concurrency == 4
    assert _asr_runs_concurrently(config) is False


def test_memory_provider_progress_keeps_memory_checkpoint_stage(tmp_path: Path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task_id = "tvx_memory_progress"
    checkpoint: dict = {}
    callback = _translation_progress_callback(
        store,
        task_id,
        checkpoint,
        stage="MEMORY",
    )

    callback(
        {
            "mode": "memory_bootstrap",
            "chunk_ids": ["bootstrap"],
            "provider": "p1",
            "model": "m1",
            "attempt": 1,
            "max_attempts": 2,
        }
    )

    assert checkpoint["status"] == "MEMORY"
    assert checkpoint["memory_current_mode"] == "memory_bootstrap"
    assert checkpoint["memory_current_chunk_ids"] == ["bootstrap"]
    assert checkpoint["model_request_count"] == 1
    assert checkpoint["model_request_counts"] == {"memory_bootstrap": 1}
    assert "translate_current_mode" not in checkpoint


def test_provider_progress_counts_request_start_once_and_separates_response(tmp_path: Path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task_id = "tvx_request_lifecycle"
    checkpoint: dict = {}
    callback = _translation_progress_callback(store, task_id, checkpoint)

    callback(
        {
            "mode": "translate",
            "request_state": "started",
            "chunk_id": "c00000",
            "provider": "p1",
            "model": "m1",
            "attempt": 1,
            "max_attempts": 2,
        }
    )
    callback(
        {
            "mode": "translate",
            "request_state": "completed",
            "chunk_id": "c00000",
            "provider": "p1",
            "model": "m1",
            "attempt": 1,
            "max_attempts": 2,
            "provider_meta": {"transport": "httpx", "bytes_received": 123},
        }
    )
    callback(
        {
            "mode": "adaptive_split",
            "request_state": "activity",
            "chunk_id": "c00000",
            "chunk_ids": ["c00000a", "c00000b"],
        }
    )

    assert checkpoint["model_request_count"] == 1
    assert checkpoint["model_request_counts"] == {"translate": 1}
    assert checkpoint["model_request_stage_counts"] == {"TRANSLATE": {"translate": 1}}
    assert checkpoint["translate_last_completed_at"]
    assert checkpoint["transport"] == "httpx"
    payload = _checkpoint_status_payload(store, task_id)
    assert payload["progress_detail"]["model_request_count"] == 1
    events = [json.loads(line) for line in store.events_file(task_id).read_text(encoding="utf-8").splitlines()]
    assert [event["type"] for event in events] == ["provider_attempt", "provider_response", "progress"]
    assert events[0]["details"]["request_number"] == 1


def _indent_yaml_block(block: str, prefix: str) -> str:
    text = dedent(block).strip()
    if not text:
        return ""
    return "\n" + "\n".join(prefix + line if line else line for line in text.splitlines())


def _write_remote_asr_config(
    root: Path,
    *,
    provider_name: str = "cloud1",
    prompt: str = "",
    execution: str = "",
    preprocessing: str = "",
    chunking: str = "",
) -> None:
    (root / "pipeline.yaml").write_text(
        (
            f"""
artifacts_dir: artifacts
translation_batch_size: 2
default_concurrency: 1
asr:
  provider: {provider_name}{_indent_yaml_block(prompt, "  ")}
asr_providers:
  - name: {provider_name}
    kind: remote
    protocol: openai_transcriptions
    base_url: https://api.example.com/v1
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    auth:
      type: bearer
      env_key: PROVIDER_KEY
      credential_id: {provider_name}{_indent_yaml_block(execution, "    ")}{_indent_yaml_block(preprocessing, "    ")}{_indent_yaml_block(chunking, "    ")}
providers:
            """
        ).strip(),
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

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
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
        max_upload_mb: float,
        max_window_seconds: int,
        min_window_seconds: int,
        duration_seconds: float,
        **_kwargs,
    ) -> list[dict]:
        assert mode == "auto"
        assert window_seconds == 300
        assert overlap_seconds == 30
        assert short_audio_seconds == 300
        assert max_upload_mb == 24
        assert max_window_seconds == 120
        assert min_window_seconds == 12
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
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
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
        "source",
        "chunks",
        "translate",
        "final",
        "quality",
        "output",
    ]:
        assert (task_dir / rel).exists()

    events = store.read_events(task.task_id)
    assert any(event["type"] == "done" for event in events)
    assert not (root / "artifacts" / ".cache" / task.task_id).exists()
    assert any(event["type"] == "warning" and "max cps" in event["message"] for event in events)
    assert (task_dir / "translate" / "segments.translated.jsonl").exists()
    assert (task_dir / "translate" / "validation.jsonl").exists()
    assert (task_dir / "final" / "segments.aligned.json").exists()
    source_raw_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.raw.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    source_clean_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_raw_rows] == ["Hello", "World", "Again"]
    assert [row["text_src"] for row in source_clean_rows] == ["Hello", "World", "Again"]
    source_cleaning = json.loads((task_dir / "quality" / "source_cleaning.json").read_text(encoding="utf-8"))
    assert source_cleaning["dropped_segments"] == 0
    quality = json.loads((task_dir / "quality" / "subtitle_quality.json").read_text(encoding="utf-8"))
    assert quality["summary"]["segments"] >= 1
    assert len(FakeAsrEngine.calls) == 2

    resumed_id = resume_pipeline(root_dir=root, task_id=task.task_id)
    resumed = store.load_task(resumed_id)
    assert resumed.status == "DONE"
    assert len(FakeAsrEngine.calls) == 2
    checkpoint = json.loads((task_dir / "checkpoint.json").read_text(encoding="utf-8"))
    assert "error" not in checkpoint


def test_translation_experiment_artifacts_write_raw_and_metrics(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    (root / "pipeline.yaml").write_text(
        (root / "pipeline.yaml").read_text(encoding="utf-8")
        + """
translation:
  experiment_logging:
    enabled: true
    save_raw_text: true
    save_metrics: true
    label: unit-pilot
        """,
        encoding="utf-8",
    )
    config = load_app_config(root_dir=root)
    store = TaskStore(root / "artifacts")
    task_id, _ = create_pipeline_task(
        root_dir=root,
        input_file=root / "segments.jsonl",
        source_lang="en",
        target_lang="zh-CN",
        status="INIT",
    )
    paths = {
        "base": store.task_dir(task_id),
        "translate": store.task_dir(task_id) / "translate",
    }
    row = {
        "chunk_id": "c00000",
        "provider": "p1",
        "model": "m1",
        "compat_mode": "openai_chat",
        "raw_text": "[1] 你好",
        "raw_text_chars": 6,
        "usage": {"input_tokens": 10, "output_tokens": 20},
        "provider_meta": {
            "elapsed_ms": 123,
            "bytes_received": 456,
            "streaming": True,
            "batch_recovery_requests": 1,
            "batch_recovered_rows": 4,
        },
        "request": {
            "line_count": 1,
            "context_before_lines": 2,
            "context_after_lines": 3,
            "memory_entries": 0,
            "memory_prompt_chars": 0,
            "protocol_recovered": True,
            "batch_recovery_requests": 1,
            "chunk_meta": {"estimated_input_tokens": 30},
        },
        "validation": {"chunk_id": "c00000", "issues": []},
        "repairs": [],
        "errors": [],
    }

    _write_translation_experiment_artifacts(config, paths, row)

    raw_file = store.task_dir(task_id) / "translate" / "raw" / "c00000.raw.txt"
    metrics_file = store.task_dir(task_id) / "translate" / "metrics.jsonl"
    assert raw_file.read_text(encoding="utf-8") == "[1] 你好"
    metrics = [json.loads(line) for line in metrics_file.read_text(encoding="utf-8").splitlines()]
    assert metrics[0]["experiment_label"] == "unit-pilot"
    assert metrics[0]["raw_text_path"] == "translate\\raw\\c00000.raw.txt" or metrics[0]["raw_text_path"] == "translate/raw/c00000.raw.txt"
    assert metrics[0]["usage"]["output_tokens"] == 20
    assert metrics[0]["provider_meta"]["elapsed_ms"] == 123
    assert metrics[0]["provider_meta"]["batch_recovered_rows"] == 4
    assert metrics[0]["protocol_recovered"] is True
    assert metrics[0]["batch_recovery_requests"] == 1


def test_pipeline_can_export_srt_and_ass_and_freeze_translation_settings(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
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

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=True,
        output_file=root / "exports" / "demo.review.v2.srt",
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
    assert task.output_paths["srt"].endswith("demo.review.v2.srt")
    assert task.output_paths["ass"].endswith("demo.review.v2.ass")
    assert task.output_path == task.output_paths["srt"]
    assert task.settings["output_format"] == "both"
    assert task.settings["translation"]["style_preset"] == "localized"
    assert task.settings["translation"]["style_prompt"] == "Use dramatic subtitles."
    assert task.settings["translation"]["chunk_lines"] == 8
    assert (store.task_dir(task_id) / "quality" / "subtitle_delivery.json").exists()
    events = store.read_events(task_id)
    done = next(event for event in events if event["type"] == "done")
    assert set(done["details"]["output_paths"]) == {"srt", "ass"}
    assert any(event["stage"] == "QUALITY" and event["type"] == "artifact" for event in events)
    assert any(event["stage"] == "EXPORT" and event["message"] == "Subtitle delivery report ready" for event in events)


def test_resume_uses_saved_pipeline_settings_for_asr_provider(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_remote_asr_config(
        root,
        execution="""
execution:
  concurrency: 3
  max_concurrency: 3
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    task_id, _artifacts_dir = create_pipeline_task(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        cli_overrides={
            "source_mode": "asr",
        },
        input_type="video_asr",
    )
    captured: dict[str, object] = {}

    def fake_execute_task(config, store, task_id, **_kwargs):
        provider = config.asr_providers[config.pipeline.asr_provider]
        captured["asr_provider"] = config.pipeline.asr_provider
        captured["source_mode"] = config.pipeline.source_mode
        captured["concurrency"] = provider.execution.concurrency

    monkeypatch.setattr("transvortex.core.orchestrator._execute_task", fake_execute_task)

    resume_pipeline(root_dir=root, task_id=task_id)

    assert captured == {
        "asr_provider": "cloud1",
        "source_mode": "asr",
        "concurrency": 3,
    }


def test_resume_uses_saved_one_off_asr_prompt(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    prompt_dir = root / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "anime.v1.md").write_text("Project prompt", encoding="utf-8")
    pipeline = root / "pipeline.yaml"
    raw = pipeline.read_text(encoding="utf-8")
    pipeline.write_text(
        raw.replace(
            "asr:\n  provider: faster_whisper_test",
            """asr:
  provider: faster_whisper_test
  prompt:
    active_profile: anime
    profiles:
      - id: anime
        name: Anime
        path: prompts/asr/anime.v1.md
        include_previous_text: false
        max_chars: 100""",
        ),
        encoding="utf-8",
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    task_id, _artifacts_dir = create_pipeline_task(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="zh-CN",
        cli_overrides={
            "source_mode": "asr",
            "asr_prompt_text": "Task-only prompt",
            "asr_prompt_include_previous_text": "true",
            "asr_prompt_max_chars": 80,
        },
        input_type="video_asr",
    )
    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.settings["asr_prompt"]["text"] == "Task-only prompt"
    assert task.settings["asr_prompt"]["active_profile"] == "anime"

    (prompt_dir / "anime.v1.md").write_text("Changed project prompt", encoding="utf-8")
    captured: dict[str, object] = {}

    def fake_execute_task(config, store, task_id, **_kwargs):
        captured["prompt_text"] = config.pipeline.asr_prompt.text
        captured["active_profile"] = config.pipeline.asr_prompt.active_profile
        captured["include_previous_text"] = config.pipeline.asr_prompt.include_previous_text
        captured["max_chars"] = config.pipeline.asr_prompt.max_chars

    monkeypatch.setattr("transvortex.core.orchestrator._execute_task", fake_execute_task)

    resume_pipeline(root_dir=root, task_id=task_id)

    assert captured == {
        "prompt_text": "Task-only prompt",
        "active_profile": "anime",
        "include_previous_text": True,
        "max_chars": 80,
    }


def test_cloud_asr_trims_silence_before_provider_and_records_preprocess_artifact(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    prompt_dir = root / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "cloud.v1.md").write_text("Names: Subaru", encoding="utf-8")
    _write_remote_asr_config(
        root,
        prompt="""
prompt:
  enabled: true
  active_profile: cloud
  profiles:
    - id: cloud
      name: Cloud prompt
      path: prompts/asr/cloud.v1.md
      max_chars: 80
  max_chars: 80
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: true
    noise_db: -35
    min_silence_seconds: 0.2
    keep_preroll_seconds: 0.25
    trim_trailing: true
    keep_postroll_seconds: 0.1
    min_upload_seconds: 0.5
        """,
        chunking="""
chunking:
  mode: none
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 10.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 20.0, "duration": 10.0, "trusted_start": 20.0, "trusted_end": 30.0, "path": str(first)}]

    def fake_prepare(audio_path: Path, upload_path: Path, **_kwargs) -> dict:
        upload_path.parent.mkdir(parents=True, exist_ok=True)
        upload_path.write_bytes(b"trimmed")
        return {
            "enabled": True,
            "backend": "ffmpeg_silencedetect",
            "source_path": str(audio_path),
            "upload_path": str(upload_path),
            "duration_seconds": 10.0,
            "silence_ranges": [{"start": 0.0, "end": 3.0, "duration": 3.0}],
            "leading_silence_seconds": 3.0,
            "trailing_silence_seconds": 0.0,
            "trim_start_seconds": 2.75,
            "trim_end_seconds": 10.0,
            "skipped": False,
            "reason": "trimmed",
        }

    seen = {}

    class FakeCloudAsrEngine:
        def __init__(self, **kwargs) -> None:
            seen["provider"] = kwargs["asr_provider"].name
            seen["prompt"] = kwargs["prompt"]

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            seen["audio_path"] = audio_path
            seen["offset"] = segment_start_offset
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": "Hello",
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"segments": []},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.prepare_cloud_asr_audio_upload", fake_prepare)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr(
        "transvortex.core.orchestrator.probe_provider",
        lambda **_kwargs: {"checks": [{"status": "PASS"}]},
    )

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="en",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    assert seen["provider"] == "cloud1"
    assert seen["prompt"] == "Names: Subaru"
    assert seen["audio_path"] == root / "artifacts" / ".cache" / task_id / "asr" / "upload" / "segment_00000.wav"
    assert seen["offset"] == 22.75
    preprocess = json.loads((task_dir / "source" / "asr" / "preprocess" / "segment_00000.json").read_text(encoding="utf-8"))
    assert preprocess["reason"] == "trimmed"
    rows = json.loads((task_dir / "source" / "asr" / "rows" / "segment_00000.json").read_text(encoding="utf-8"))
    assert rows[0]["meta"]["audio_preprocess"]["trim_start_seconds"] == 2.75
    source_lines = (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    assert json.loads(source_lines[0])["start"] == 22.75


def test_cloud_asr_previous_text_is_added_to_next_segment_prompt(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    prompt_dir = root / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "cloud.v1.md").write_text("Names: Subaru", encoding="utf-8")
    _write_remote_asr_config(
        root,
        prompt="""
prompt:
  enabled: true
  active_profile: cloud
  profiles:
    - id: cloud
      name: Cloud prompt
      path: prompts/asr/cloud.v1.md
      include_previous_text: true
      max_chars: 400
  include_previous_text: true
  max_chars: 400
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: fixed
  window_seconds: 10
  overlap_seconds: 0
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 20.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        second = segments_dir / "part_00001.wav"
        first.write_bytes(b"one")
        second.write_bytes(b"two")
        return [
            {"segment_index": 0, "start": 0.0, "duration": 10.0, "trusted_start": 0.0, "trusted_end": 10.0, "path": str(first)},
            {"segment_index": 1, "start": 10.0, "duration": 10.0, "trusted_start": 10.0, "trusted_end": 20.0, "path": str(second)},
        ]

    def fake_prepare(audio_path: Path, upload_path: Path, **_kwargs) -> dict:
        upload_path.parent.mkdir(parents=True, exist_ok=True)
        upload_path.write_bytes(audio_path.read_bytes())
        return {"enabled": False, "reason": "disabled", "upload_path": str(upload_path), "trim_start_seconds": 0.0, "skipped": False}

    prompts: list[str | None] = []

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float, *, prompt: str | None = None):
            prompts.append(prompt)
            text = "Subaru arrives" if audio_path.name in {"segment_00000.wav", "part_00000.wav"} else "Emilia answers"
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": text,
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"text": text},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.prepare_cloud_asr_audio_upload", fake_prepare)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="en",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    assert prompts[0] == "Names: Subaru"
    assert "Names: Subaru" in str(prompts[1])
    assert "Previous transcript:" in str(prompts[1])
    assert "Subaru arrives" in str(prompts[1])


def test_cloud_asr_retries_original_audio_when_trimmed_result_is_nonspeech(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: true
        """,
        chunking="""
chunking:
  mode: none
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 10.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 10.0, "trusted_start": 0.0, "trusted_end": 10.0, "path": str(first)}]

    def fake_prepare(audio_path: Path, upload_path: Path, **_kwargs) -> dict:
        upload_path.parent.mkdir(parents=True, exist_ok=True)
        upload_path.write_bytes(b"trimmed")
        return {
            "enabled": True,
            "backend": "ffmpeg_silencedetect",
            "source_path": str(audio_path),
            "upload_path": str(upload_path),
            "duration_seconds": 10.0,
            "silence_ranges": [{"start": 0.0, "end": 0.5, "duration": 0.5}],
            "leading_silence_seconds": 0.5,
            "trailing_silence_seconds": 0.0,
            "trim_start_seconds": 0.25,
            "trim_end_seconds": 10.0,
            "skipped": False,
            "reason": "trimmed",
        }

    seen_paths = []

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            seen_paths.append(audio_path.name)
            text = "♪♪" if audio_path.name == "segment_00000.wav" else "やったわ"
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": text,
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"text": text},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.prepare_cloud_asr_audio_upload", fake_prepare)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    assert seen_paths == ["segment_00000.wav", "part_00000.wav"]
    preprocess = json.loads((task_dir / "source" / "asr" / "preprocess" / "segment_00000.json").read_text(encoding="utf-8"))
    assert preprocess["fallback_used"] is True
    rows = json.loads((task_dir / "source" / "asr" / "rows" / "segment_00000.json").read_text(encoding="utf-8"))
    assert rows[0]["text"] == "やったわ"
    assert rows[0]["meta"]["audio_preprocess"]["fallback_used"] is True


def test_cloud_asr_filters_hard_garbage_rows_before_source_artifact(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: none
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 10.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 10.0, "trusted_start": 0.0, "trusted_end": 10.0, "path": str(first)}]

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, _audio_path: Path, segment_start_offset: float):
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {"start": segment_start_offset, "end": segment_start_offset + 1, "text": "♪♪", "meta": {"source": "asr"}},
                        {"start": segment_start_offset + 1, "end": segment_start_offset + 2, "text": "やったわ", "meta": {"source": "asr"}},
                        {
                            "start": segment_start_offset + 2,
                            "end": segment_start_offset + 3,
                            "text": "耳かき音、耳かき音、耳かき音、耳かき音",
                            "meta": {"source": "asr"},
                        },
                        {
                            "start": segment_start_offset + 3,
                            "end": segment_start_offset + 11,
                            "text": "第一句。第二句！第三句？",
                            "meta": {"source": "asr"},
                        },
                    ],
                    "raw_response": {"segments": []},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    task_dir = TaskStore(root / "artifacts").task_dir(task_id)
    rows = json.loads((task_dir / "source" / "asr" / "rows" / "segment_00000.json").read_text(encoding="utf-8"))
    assert [row["text"] for row in rows] == ["やったわ", "耳かき音、耳かき音、耳かき音、耳かき音", "第一句。第二句！第三句？"]
    quality = json.loads((task_dir / "source" / "asr" / "quality" / "segment_00000.json").read_text(encoding="utf-8"))
    assert quality["dropped_rows"] == 1
    source_raw_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.raw.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_raw_rows] == ["やったわ", "耳かき音、耳かき音、耳かき音、耳かき音", "第一句。第二句！第三句？"]
    source_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_rows] == ["やったわ", "第一句。第二句！第三句？"]
    assert source_rows[1]["meta"]["asr_risk"]["level"] == "warn"
    assert source_rows[1]["meta"]["asr_risk"]["codes"] == ["long_duration", "multiple_sentence_endings"]
    boundary_quality = json.loads((task_dir / "quality" / "asr_boundary_quality.json").read_text(encoding="utf-8"))
    assert boundary_quality["risk_segments"] == 1
    assert boundary_quality["code_counts"] == {"long_duration": 1, "multiple_sentence_endings": 1}
    source_cleaning = json.loads((task_dir / "quality" / "source_cleaning.json").read_text(encoding="utf-8"))
    assert source_cleaning["dropped_segments"] == 1
    assert source_cleaning["dropped"][0]["reasons"] == ["repeated_sound_effect", "sound_effect"]


def test_cloud_asr_concurrent_segments_merge_in_manifest_order(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        execution="""
execution:
  concurrency: 4
  max_concurrency: 4
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: fixed
  window_seconds: 10
  overlap_seconds: 0
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 20.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        out = []
        for idx, start in enumerate([0.0, 10.0]):
            part = segments_dir / f"part_{idx:05d}.wav"
            part.write_bytes(str(idx).encode("utf-8"))
            out.append(
                {
                    "segment_index": idx,
                    "start": start,
                    "duration": 10.0,
                    "trusted_start": start,
                    "trusted_end": start + 10.0,
                    "path": str(part),
                }
            )
        return out

    class FakeCloudAsrEngine:
        created = 0
        closed = 0

        def __init__(self, **_kwargs) -> None:
            type(self).created += 1

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            idx = int(audio_path.stem.rsplit("_", 1)[-1])
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": f"line {idx}",
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"segments": []},
                },
            )()

        def close(self) -> None:
            type(self).closed += 1

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    task_dir = TaskStore(root / "artifacts").task_dir(task_id)
    source_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_rows] == ["line 0", "line 1"]
    checkpoint = json.loads((task_dir / "checkpoint.json").read_text(encoding="utf-8"))
    assert checkpoint["asr_done_segments"] == [0, 1]
    assert FakeCloudAsrEngine.created >= 3
    assert FakeCloudAsrEngine.closed == FakeCloudAsrEngine.created


def test_cloud_asr_retryable_failure_splits_segment_from_original_timeline(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        execution="""
execution:
  concurrency: 1
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: fixed
  window_seconds: 60
  max_window_seconds: 60
  min_window_seconds: 12
  overlap_seconds: 0
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 60.0}

    split_calls = []

    def fake_split_audio_for_asr(audio_path: Path, segments_dir: Path, **kwargs) -> list[dict]:
        split_calls.append({"audio_path": audio_path, "segments_dir": segments_dir, "kwargs": kwargs})
        segments_dir.mkdir(parents=True, exist_ok=True)
        if "segments_retry" in str(segments_dir):
            out = []
            for idx, start in enumerate([0.0, 30.0]):
                part = segments_dir / f"part_{idx:05d}.wav"
                part.write_bytes(str(idx).encode("utf-8"))
                out.append(
                    {
                        "segment_index": idx,
                        "start": start,
                        "duration": 30.0,
                        "trusted_start": start,
                        "trusted_end": start + 30.0,
                        "path": str(part),
                    }
                )
            return out
        part = segments_dir / "part_00000.wav"
        part.write_bytes(b"parent")
        return [
            {
                "segment_index": 0,
                "start": 0.0,
                "duration": 60.0,
                "trusted_start": 0.0,
                "trusted_end": 60.0,
                "path": str(part),
                "source_audio_path": str(root / "artifacts" / "placeholder_full_audio.m4a"),
            }
        ]

    calls = {"count": 0}

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            calls["count"] += 1
            if audio_path.name == "part_00000.wav" and "segments_retry" not in str(audio_path):
                raise RuntimeError("provider_timeout: first upload timed out")
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": f"child {audio_path.stem}",
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"segments": []},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    task_dir = TaskStore(root / "artifacts").task_dir(task_id)
    source_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_rows] == ["child part_00000", "child part_00001"]
    retry_call = next(call for call in split_calls if "segments_retry" in str(call["segments_dir"]))
    assert retry_call["kwargs"]["source_start_seconds"] == 0.0
    assert retry_call["audio_path"] == root / "artifacts" / "placeholder_full_audio.m4a"
    preprocess = json.loads((task_dir / "source" / "asr" / "preprocess" / "segment_00000.json").read_text(encoding="utf-8"))
    assert preprocess["reason"] == "split_retry"
    assert "/.cache/" in preprocess["child_artifact_dir"].replace("\\", "/")
    assert "/asr/retry/segment_00000" in preprocess["child_artifact_dir"].replace("\\", "/")
    assert not (task_dir / "source" / "asr" / "rows" / "segment_00001.json").exists()
    assert not (root / "artifacts" / ".cache" / task_id).exists()


def test_cloud_asr_http_transport_error_splits_segment(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        execution="""
execution:
  concurrency: 1
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: fixed
  window_seconds: 60
  max_window_seconds: 60
  min_window_seconds: 12
  overlap_seconds: 0
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 60.0}

    split_calls = []

    def fake_split_audio_for_asr(audio_path: Path, segments_dir: Path, **kwargs) -> list[dict]:
        split_calls.append({"audio_path": audio_path, "segments_dir": segments_dir, "kwargs": kwargs})
        segments_dir.mkdir(parents=True, exist_ok=True)
        if "segments_retry" in str(segments_dir):
            out = []
            for idx, start in enumerate([0.0, 30.0]):
                part = segments_dir / f"part_{idx:05d}.wav"
                part.write_bytes(str(idx).encode("utf-8"))
                out.append(
                    {
                        "segment_index": idx,
                        "start": start,
                        "duration": 30.0,
                        "trusted_start": start,
                        "trusted_end": start + 30.0,
                        "path": str(part),
                    }
                )
            return out
        part = segments_dir / "part_00000.wav"
        part.write_bytes(b"parent")
        return [
            {
                "segment_index": 0,
                "start": 0.0,
                "duration": 60.0,
                "trusted_start": 0.0,
                "trusted_end": 60.0,
                "path": str(part),
            }
        ]

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            if audio_path.name == "part_00000.wav" and "segments_retry" not in str(audio_path):
                raise HttpTransportError(
                    "bad_gateway",
                    "cloud ASR upstream returned HTTP 502: Bad Gateway",
                    status_code=502,
                )
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": f"child {audio_path.stem}",
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"segments": []},
                    "transport_meta": {},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    task_dir = TaskStore(root / "artifacts").task_dir(task_id)
    source_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_rows] == ["child part_00000", "child part_00001"]
    assert any("segments_retry" in str(call["segments_dir"]) for call in split_calls)


def test_cloud_asr_adaptive_concurrency_requeues_retryable_failure(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    _write_remote_asr_config(
        root,
        execution="""
execution:
  concurrency: 2
  max_concurrency: 2
  min_concurrency: 1
  adaptive_concurrency: true
        """,
        preprocessing="""
preprocessing:
  trim_silence:
    enabled: false
        """,
        chunking="""
chunking:
  mode: fixed
  window_seconds: 10
  overlap_seconds: 0
        """,
    )
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 20.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        out = []
        for idx, start in enumerate([0.0, 10.0]):
            part = segments_dir / f"part_{idx:05d}.wav"
            part.write_bytes(str(idx).encode("utf-8"))
            out.append(
                {
                    "segment_index": idx,
                    "start": start,
                    "duration": 10.0,
                    "trusted_start": start,
                    "trusted_end": start + 10.0,
                    "path": str(part),
                }
            )
        return out

    attempts: dict[str, int] = {}

    class FakeCloudAsrEngine:
        def __init__(self, **_kwargs) -> None:
            pass

        def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float):
            attempts[audio_path.name] = attempts.get(audio_path.name, 0) + 1
            if audio_path.name == "part_00000.wav" and attempts[audio_path.name] == 1:
                raise RuntimeError("provider_timeout: temporary timeout")
            idx = int(audio_path.stem.rsplit("_", 1)[-1])
            return type(
                "Result",
                (),
                {
                    "rows": [
                        {
                            "start": segment_start_offset,
                            "end": segment_start_offset + 1.0,
                            "text": f"line {idx}",
                            "meta": {"source": "asr"},
                        }
                    ],
                    "raw_response": {"segments": []},
                },
            )()

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeCloudAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": [{"status": "PASS"}]})

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="ja",
        input_type="video_asr",
        cli_overrides={"source_mode": "asr"},
    )

    task_dir = TaskStore(root / "artifacts").task_dir(task_id)
    source_rows = [
        json.loads(line)
        for line in (task_dir / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [row["text_src"] for row in source_rows] == ["line 0", "line 1"]
    assert attempts["part_00000.wav"] == 2


def test_asr_upload_batch_respects_worker_and_upload_limits(tmp_path: Path) -> None:
    first = tmp_path / "first.wav"
    second = tmp_path / "second.wav"
    third = tmp_path / "third.wav"
    first.write_bytes(b"0" * 1024 * 1024)
    second.write_bytes(b"0" * 1024 * 1024)
    third.write_bytes(b"0" * 1024 * 1024)
    items = [
        {"segment_index": 0, "path": str(first), "duration": 10.0},
        {"segment_index": 1, "path": str(second), "duration": 10.0},
        {"segment_index": 2, "path": str(third), "duration": 10.0},
    ]

    batch, remaining = _take_asr_upload_batch(items, max_items=3, max_upload_mb=2.5)

    assert [item["segment_index"] for item in batch] == [0, 1]
    assert [item["segment_index"] for item in remaining] == [2]

    batch, remaining = _take_asr_upload_batch(items, max_items=1, max_upload_mb=10)

    assert [item["segment_index"] for item in batch] == [0]
    assert [item["segment_index"] for item in remaining] == [1, 2]


def test_asr_upload_size_estimate_uses_duration_when_file_is_missing() -> None:
    item = {"segment_index": 0, "duration": 60.0, "path": ""}

    assert round(_asr_item_upload_mb(item), 2) == 1.83


def test_default_memory_uses_large_capacity_chunk(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "segments.jsonl"
    input_file.write_text(
        "\n".join(
            json.dumps({"id": idx, "start": idx, "end": idx + 0.5, "text_src": f"Line {idx}"})
            for idx in range(1, 31)
        )
        + "\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": []})
    observed_chunk_sizes: list[int] = []

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None, memory_dir=None, progress_callback=None):
        observed_chunk_sizes.extend(len(chunk.segment_ids) for chunk in chunks)
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
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        input_type="segments_translate",
        cli_overrides={"translation_chunk_lines": 2},
    )

    store = TaskStore(root / "artifacts")
    assert store.load_task(task_id).status == "DONE"
    assert observed_chunk_sizes == [30]
    events = store.read_events(task_id)
    assert any(event["message"] == "Memory bootstrap ready" for event in events)


def test_segments_translate_rebuilds_compacted_model_view_from_saved_asr_source(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "segments.jsonl"
    input_file.write_text(
        json.dumps(
            {
                "id": 7,
                "start": 0,
                "end": 20,
                "text_src": "コシ" * 48,
                "meta": {"source": "asr", "source_cleaning_warnings": ["periodic_repetition"]},
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": []})
    observed_lines: list[str] = []

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, **_kwargs):
        observed_lines.extend(line for chunk in chunks for line in chunk.lines)
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
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="ja",
        target_lang="zh-CN",
        input_type="segments_translate",
        cli_overrides={"memory_enabled": False},
    )

    store = TaskStore(root / "artifacts")
    saved = json.loads((store.task_dir(task_id) / "source" / "segments.normalized.jsonl").read_text(encoding="utf-8"))
    assert saved["id"] == 7
    assert saved["text_src"] == "コシ" * 48
    assert saved["meta"]["source_text_for_model"] == "コシコシコシコシ…"
    assert observed_lines == ["[7] コシコシコシコシ…"]


def test_resume_backfills_missing_translation_validation_without_retranslation(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
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

    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
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

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
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
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN")
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    asr_file = task_dir / "source" / "asr" / "rows" / "segment_00000.json"
    asr_file.unlink()

    resume_pipeline(root_dir=root, task_id=task_id)

    assert asr_file.exists()
    assert FakeAsrEngine.calls.count("part_00000.wav") == 2


def test_asr_task_keeps_done_status_if_done_event_sink_fails(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
        output_audio.parent.mkdir(parents=True, exist_ok=True)
        output_audio.write_bytes(b"audio")
        return {"audio_codec": "aac", "copy_mode": True, "duration_seconds": 1.0}

    def fake_split_audio_for_asr(_audio_path: Path, segments_dir: Path, **_kwargs) -> list[dict]:
        segments_dir.mkdir(parents=True, exist_ok=True)
        first = segments_dir / "part_00000.wav"
        first.write_bytes(b"one")
        return [{"segment_index": 0, "start": 0.0, "duration": 1.0, "trusted_start": 0.0, "trusted_end": 1.0, "path": str(first)}]

    FakeAsrEngine.calls = []
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
    monkeypatch.setattr("transvortex.core.orchestrator.split_audio_for_asr", fake_split_audio_for_asr)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", FakeAsrEngine)
    original_append_event = TaskStore.append_event

    def flaky_append_event(self, task_id: str, event_type: str, *args, **kwargs):
        if event_type == "done":
            raise RuntimeError("stdout closed")
        return original_append_event(self, task_id, event_type, *args, **kwargs)

    monkeypatch.setattr(TaskStore, "append_event", flaky_append_event)

    task_id = run_pipeline(
        root_dir=root,
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        input_type="video_asr",
    )

    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.status == "DONE"
    assert task.output_paths["segments"].endswith("segments.normalized.jsonl")


def test_resume_migrates_legacy_asr_segments_to_source_artifact(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "segments.jsonl"
    input_file.write_text('{"id": 1, "start": 0, "end": 1, "text_src": "Hello"}\n', encoding="utf-8")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr("transvortex.core.orchestrator.probe_provider", lambda **_kwargs: {"checks": []})

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None, **_kwargs):
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
            if chunk.chunk_id not in (already_done or set())
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)
    task_id = run_pipeline(root_dir=root, input_file=input_file, source_lang="en", target_lang="zh-CN", input_type="segments_translate")
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    source_file = task_dir / "source" / "segments.normalized.jsonl"
    legacy_file = task_dir / "asr" / "segments.raw.jsonl"
    legacy_file.parent.mkdir(parents=True, exist_ok=True)
    legacy_file.write_text(source_file.read_text(encoding="utf-8"), encoding="utf-8")
    source_file.unlink()
    checkpoint_file = task_dir / "checkpoint.json"
    checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
    checkpoint["status"] = "INGEST"
    checkpoint_file.write_text(json.dumps(checkpoint), encoding="utf-8")

    resume_pipeline(root_dir=root, task_id=task_id)

    assert source_file.exists()
    rows = [json.loads(line) for line in source_file.read_text(encoding="utf-8").splitlines()]
    assert rows[0]["text_src"] == "Hello"


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
    assert (task_dir / "source" / "embedded_subtitle.srt").exists()
    assert (task_dir / "source" / "subtitle_streams.json").exists()
    source_file = task_dir / "source" / "segments.normalized.jsonl"
    assert source_file.exists()
    rows = [json.loads(line) for line in source_file.read_text(encoding="utf-8").splitlines()]
    assert rows[0]["meta"]["source"] == "embedded_subtitle"
    events = store.read_events(task_id)
    warning = next(event for event in events if "Auto-selected embedded subtitle stream" in event.get("message", ""))
    assert warning["level"] == "warning"
    assert warning["details"]["stream"]["index"] == 2


def test_video_asr_embedded_subtitle_honors_cancel_before_done(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mkv"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

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
        store = TaskStore(root / "artifacts")
        [task] = store.list_tasks()
        store.request_cancel(task.task_id)

    monkeypatch.setattr("transvortex.core.orchestrator.list_subtitle_streams", fake_list_subtitle_streams)
    monkeypatch.setattr("transvortex.core.orchestrator.extract_subtitle_stream", fake_extract_subtitle_stream)

    try:
        run_pipeline(
            root_dir=root,
            input_file=input_file,
            source_lang="en",
            target_lang="zh-CN",
            input_type="video_asr",
            cli_overrides={"source_mode": "embedded_subtitle"},
        )
    except PipelineTaskError:
        pass
    else:
        raise AssertionError("video_asr should not finish after cancellation")

    [task] = TaskStore(root / "artifacts").list_tasks()
    assert task.status == "CANCELLED"


def test_worker_streams_events_and_route_override(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    input_file = root / "demo.mp4"
    input_file.write_bytes(b"video")
    monkeypatch.setenv("PROVIDER_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.core.orchestrator.importlib.util.find_spec", lambda name: object())

    def fake_extract_audio(_video_path: Path, output_audio: Path, **_kwargs) -> dict:
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
    monkeypatch.setattr("transvortex.core.orchestrator.extract_audio_for_asr", fake_extract_audio)
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
