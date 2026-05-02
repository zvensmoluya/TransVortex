from __future__ import annotations

import json
from pathlib import Path

from transvortex.cli import main
from transvortex.models import TaskRecord
from transvortex.task_store import TaskStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
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


def test_status_events_and_cancel_cli_json(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t1",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="ASR",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)
    store.append_event("t1", "stage", stage="ASR", message="working", progress=0.25)

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "status", "--task-id", "t1", "--json"],
    )
    main()
    payload = json.loads(capsys.readouterr().out)
    assert payload["task_id"] == "t1"
    assert payload["status"] == "ASR"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "events", "--task-id", "t1"],
    )
    main()
    first_event = json.loads(capsys.readouterr().out.splitlines()[0])
    assert first_event["type"] == "stage"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "cancel", "--task-id", "t1", "--json"],
    )
    main()
    cancelled = json.loads(capsys.readouterr().out)
    assert cancelled["status"] == "CANCEL_REQUESTED"
    assert store.is_cancel_requested("t1")


def test_tasks_cli_json_lists_recent_tasks(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    older = TaskRecord(
        task_id="old",
        input_file="old.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="DONE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    newer = TaskRecord(
        task_id="new",
        input_file="new.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=True,
        status="FAILED",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-14T00:00:00+00:00",
        error="boom",
    )
    store.save_task(older)
    store.save_task(newer)

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "tasks", "--json"],
    )
    main()
    payload = json.loads(capsys.readouterr().out)
    assert [task["task_id"] for task in payload] == ["new", "old"]
    assert Path(payload[0]["task_dir"]).parts[-2:] == ("artifacts", "new")
    assert payload[0]["error"] == "boom"


def test_config_show_json_masks_secret_values(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "config", "show", "--json"],
    )
    main()
    raw = capsys.readouterr().out
    payload = json.loads(raw)
    assert "super-secret-value" not in raw
    assert payload["providers"][0]["env_key"] == "PROVIDER_KEY"
    assert payload["providers"][0]["has_key"] is True
    assert payload["routing"]["primary"]["provider"] == "p1"


def test_run_stream_events_cli_jsonl_and_overrides(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    captured = {}

    def fake_run_pipeline(**kwargs):
        captured.update(kwargs)
        kwargs["event_sink"]({"type": "task_created", "task_id": "t2", "message": "created"})
        kwargs["event_sink"]({"type": "done", "task_id": "t2", "message": "done"})
        return "t2"

    monkeypatch.setattr("transvortex.cli.run_pipeline", fake_run_pipeline)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--input",
            "demo.mp4",
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--provider",
            "p1",
            "--model",
            "m1",
            "--asr-mode",
            "openai",
            "--asr-device",
            "cpu",
            "--asr-model-size",
            "tiny",
            "--asr-compute-type",
            "int8",
            "--asr-provider",
            "p1",
            "--asr-model",
            "whisper-1",
            "--stream-events",
        ],
    )
    main()
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [event["type"] for event in events] == ["task_created", "done"]
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["asr_mode"] == "openai"
    assert captured["cli_overrides"]["asr_provider_model"] == "whisper-1"


def test_stream_events_and_json_are_mutually_exclusive(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--input",
            "demo.mp4",
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--json",
            "--stream-events",
        ],
    )
    try:
        main()
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError("expected parser error")
