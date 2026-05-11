from __future__ import annotations

import json
from pathlib import Path

from transvortex.cli import main
from transvortex.protocol.errors import PipelineTaskError, error_info
from transvortex.app.models import TaskRecord
from transvortex.artifacts.task_store import TaskStore


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

    monkeypatch.setattr("transvortex.cli.entry.run_pipeline", fake_run_pipeline)
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


def test_agent_info_json_is_static_and_secret_free(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "agent-info", "--json"])

    main()

    raw = capsys.readouterr().out
    payload = json.loads(raw)
    assert payload["protocol_version"]
    assert payload["machine_readable"] is True
    assert payload["commands"]["run"]["supports_detach"] is True
    assert "QUEUED" in payload["statuses"]
    assert "super-secret-value" not in raw


def test_run_detach_json_creates_queued_task_and_spawns_worker(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    spawned = {}

    class FakePopen:
        pid = 4321

        def __init__(self, cmd, **kwargs):
            spawned["cmd"] = cmd
            spawned["kwargs"] = kwargs

    monkeypatch.setattr("transvortex.cli.entry.subprocess.Popen", FakePopen)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--input",
            str(tmp_path / "demo.mp4"),
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--providers-file",
            str(tmp_path / "providers.yaml"),
            "--provider",
            "p1",
            "--model",
            "m1",
            "--detach",
            "--json",
        ],
    )

    main()

    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "QUEUED"
    assert payload["worker"]["pid"] == 4321
    assert "_worker" in spawned["cmd"]
    assert "--providers-file" in spawned["cmd"]
    assert "--provider" in spawned["cmd"]
    store = TaskStore(tmp_path / "artifacts")
    task = store.load_task(payload["task_id"])
    assert task.status == "QUEUED"


def test_detach_and_stream_events_are_mutually_exclusive(tmp_path: Path, monkeypatch) -> None:
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
            "--detach",
            "--stream-events",
        ],
    )
    try:
        main()
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError("expected parser error")


def test_events_follow_exits_after_terminal_event(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t_follow",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="DONE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)
    store.append_event("t_follow", "stage", stage="ASR", message="working")
    store.append_event("t_follow", "done", stage="DONE", message="done")

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "events", "--task-id", "t_follow", "--follow"],
    )
    main()

    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [event["type"] for event in events] == ["stage", "done"]


def test_run_json_failure_outputs_single_structured_error(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    err = error_info(
        code="missing_env",
        error_type="config_error",
        stage="PRECHECK",
        message="Missing environment variable: PROVIDER_KEY",
    )

    def fake_run_pipeline(**_kwargs):
        raise PipelineTaskError("t_error", err)

    monkeypatch.setattr("transvortex.cli.entry.run_pipeline", fake_run_pipeline)
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
        ],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected failure exit")

    payload = json.loads(capsys.readouterr().out)
    assert payload["task_id"] == "t_error"
    assert payload["error_info"]["code"] == "missing_env"


def test_asr_translate_and_export_cli_commands(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    calls = []

    def fake_run_pipeline(**kwargs):
        calls.append(kwargs)
        config_root = kwargs["root_dir"]
        store = TaskStore(config_root / "artifacts")
        task = TaskRecord(
            task_id=f"task_{len(calls)}",
            input_file=str(kwargs["input_file"]),
            source_lang=kwargs["source_lang"],
            target_lang=kwargs["target_lang"],
            bilingual=kwargs.get("bilingual", False),
            status="DONE",
            created_at="2026-02-13T00:00:00+00:00",
            updated_at="2026-02-13T00:00:00+00:00",
        )
        store.save_task(task)
        return task.task_id

    monkeypatch.setattr("transvortex.cli.entry.run_pipeline", fake_run_pipeline)
    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "asr", "--input", "demo.mp4", "--src", "en", "--json"],
    )
    main()
    asr_payload = json.loads(capsys.readouterr().out)
    assert asr_payload["capability"] == "asr"
    assert calls[-1]["input_type"] == "video_asr"

    segments_file = tmp_path / "segments.jsonl"
    segments_file.write_text('{"id": 1, "start": 0, "end": 1, "text_src": "hello"}\n', encoding="utf-8")
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "translate",
            "--segments",
            str(segments_file),
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--json",
        ],
    )
    main()
    translate_payload = json.loads(capsys.readouterr().out)
    assert translate_payload["capability"] == "translate"
    assert calls[-1]["input_type"] == "segments_translate"

    final_file = tmp_path / "final.json"
    final_file.write_text(
        '[{"id":1,"start":0,"end":1,"text_src":"hello","text_tgt":"你好"}]',
        encoding="utf-8",
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "export",
            "--segments",
            str(final_file),
            "--format",
            "both",
            "--output",
            str(tmp_path / "out"),
            "--json",
        ],
    )
    main()
    export_payload = json.loads(capsys.readouterr().out)
    assert export_payload["capability"] == "export"
    assert set(export_payload["output_paths"]) == {"srt", "ass"}
    assert (tmp_path / "out.srt").exists()
    assert (tmp_path / "out.ass").exists()
