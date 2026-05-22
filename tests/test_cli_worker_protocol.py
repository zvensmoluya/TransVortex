from __future__ import annotations

import io
import json
import subprocess
import sys
import time
from pathlib import Path

from transvortex.cli import main
from transvortex.protocol.errors import PipelineTaskError, error_info
from transvortex.app.models import TaskRecord
from transvortex.artifacts.task_store import TaskStore
from transvortex.utils import write_json


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


def test_memory_export_preset_cli_json_writes_preset(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    store.save_task(
        TaskRecord(
            task_id="task1",
            input_file="demo.srt",
            source_lang="ja",
            target_lang="zh-CN",
            bilingual=False,
            status="DONE",
            created_at="2026-05-15T00:00:00+00:00",
            updated_at="2026-05-15T00:00:00+00:00",
        )
    )
    write_json(
        store.task_dir("task1") / "memory" / "translation_memory.json",
        {"version": 1, "entries": [{"source": "スバル", "target": "昴", "status": "confirmed"}]},
    )

    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "memory",
            "export-preset",
            "--task-id",
            "task1",
            "--preset-id",
            "rezero",
            "--name",
            "Re:Zero",
            "--json",
        ],
    )
    main()
    payload = json.loads(capsys.readouterr().out)

    assert payload["ok"] is True
    assert payload["preset_id"] == "rezero"
    assert payload["report"]["exported"] == 1
    exported = json.loads((tmp_path / "memory" / "presets" / "rezero.json").read_text(encoding="utf-8"))
    assert exported["entries"][0]["source"] == "スバル"
    assert exported["entries"][0]["status"] == "proposed"


def test_memory_bootstrap_cli_json_writes_preset_from_srt(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    srt_file = tmp_path / "demo.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:02,000
Subaru arrives
        """.strip(),
        encoding="utf-8",
    )

    class FakeClient:
        def translate_request(self, _req):
            return type(
                "Response",
                (),
                {
                    "raw_text": (
                        '{"chunk_ids":["bootstrap"],"actions":[{"action":"upsert",'
                        '"source":"Subaru","target":"斯巴鲁","category":"name",'
                        '"status":"confirmed","confidence":0.9,"evidence_ids":[1]}]}'
                    )
                },
            )()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "memory",
            "bootstrap",
            "--segments",
            str(srt_file),
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--preset-id",
            "show",
            "--json",
        ],
    )
    main()
    payload = json.loads(capsys.readouterr().out)

    assert payload["ok"] is True
    assert payload["preset_id"] == "show"
    assert payload["report"]["exported"] == 1
    exported = json.loads((tmp_path / "memory" / "presets" / "show.json").read_text(encoding="utf-8"))
    assert exported["entries"][0]["source"] == "Subaru"
    assert exported["entries"][0]["status"] == "proposed"


def test_memory_bootstrap_cli_dry_run_accepts_jsonl_without_writing(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    segments_file = tmp_path / "segments.jsonl"
    segments_file.write_text('{"id":1,"start":0,"end":1,"text_src":"hello"}\n', encoding="utf-8")

    class FakeClient:
        def translate_request(self, _req):
            return type("Response", (), {"raw_text": '{"chunk_ids":["bootstrap"],"actions":[]}'})()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "memory",
            "bootstrap",
            "--segments",
            str(segments_file),
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--preset-id",
            "empty",
            "--dry-run",
            "--json",
        ],
    )
    main()
    payload = json.loads(capsys.readouterr().out)

    assert payload["dry_run"] is True
    assert payload["preset"]["entries"] == []
    assert not (tmp_path / "memory" / "presets" / "empty.json").exists()


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
    assert payload["active_routing_profile"] == "default"
    assert payload["routing_profiles"][0]["primary"]["provider"] == "p1"
    assert payload["providers_file"]
    assert payload["providers_file_version"]
    assert payload["routing_profile_next_seq"] == 1
    assert payload["protocol_templates"]
    assert payload["provider_presets"]
    assert payload["custom_adapter_template"]["id"] == "custom_json"


def test_prompt_asr_cli_save_and_list(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "prompt",
            "asr",
            "save",
            "--json-payload",
            json.dumps({"id": "anime", "name": "Anime", "text": "Names: Subaru", "active": True}),
            "--json",
        ],
    )
    main()
    saved = json.loads(capsys.readouterr().out)
    assert saved["active_profile"] == "anime"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "prompt", "asr", "list", "--json"],
    )
    main()
    listed = json.loads(capsys.readouterr().out)
    assert listed["profiles"][0]["text"] == "Names: Subaru"


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
            "cloud",
            "--asr-device",
            "cpu",
            "--asr-model-size",
            "tiny",
            "--asr-compute-type",
            "int8",
            "--asr-model",
            "whisper-1",
            "--asr-max-upload-mb",
            "16",
            "--stream-events",
        ],
    )
    main()
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [event["type"] for event in events] == ["task_created", "done"]
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["asr_mode"] == "cloud"
    assert captured["cli_overrides"]["asr_cloud_model"] == "whisper-1"
    assert captured["cli_overrides"]["asr_max_upload_mb"] == 16.0


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
    assert payload["commands"]["memory bootstrap"]["supports_dry_run"] is True
    assert payload["commands"]["memory export-preset"]["supports_dry_run"] is True
    assert "QUEUED" in payload["statuses"]
    assert "source/segments.normalized.jsonl" in payload["artifact_contract"]
    assert "quality/subtitle_delivery.json" in payload["artifact_contract"]
    assert "output/*.vtt" in payload["artifact_contract"]
    assert "memory/rejected_memory_candidates.jsonl" in payload["artifact_contract"]
    assert "asr/segments.raw.jsonl" not in payload["artifact_contract"]
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
    assert payload["ok"] is True
    assert payload["status"] == "QUEUED"
    assert payload["detached"] is True
    assert payload["terminal"] is False
    assert payload["command"] == "run"
    assert Path(payload["task_dir"]).parts[-2:] == ("artifacts", payload["task_id"])
    assert payload["worker"]["pid"] == 4321
    assert Path(payload["worker"]["stdout_log"]).name == "stdout.log"
    assert Path(payload["worker"]["stderr_log"]).name == "stderr.log"
    assert f"status --task-id {payload['task_id']} --json" in payload["next_commands"]["status"]
    assert "_worker" in spawned["cmd"]
    assert "--providers-file" in spawned["cmd"]
    assert "--provider" in spawned["cmd"]
    assert spawned["kwargs"]["env"]["PYTHONIOENCODING"] == "utf-8"
    assert spawned["kwargs"]["env"]["PYTHONUTF8"] == "1"
    store = TaskStore(tmp_path / "artifacts")
    task = store.load_task(payload["task_id"])
    assert task.status == "QUEUED"


def test_run_detach_json_prints_receipt_with_real_worker_process(tmp_path: Path) -> None:
    _write_config(tmp_path)
    input_file = tmp_path / "missing.mp4"

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "transvortex.cli",
            "--root",
            str(tmp_path),
            "run",
            "--input",
            str(input_file),
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
        cwd=Path.cwd(),
        text=True,
        capture_output=True,
        check=True,
    )

    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert payload["detached"] is True
    assert payload["command"] == "run"
    assert payload["worker"]["pid"] > 0
    assert not result.stderr.strip()
    worker_stdout = Path(payload["worker"]["stdout_log"])
    for _ in range(100):
        if worker_stdout.exists() and "Input file not found" in worker_stdout.read_text(encoding="utf-8"):
            break
        time.sleep(0.05)
    else:
        raise AssertionError("worker did not write expected preflight failure event")


def test_status_json_missing_task_returns_structured_error(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "status", "--task-id", "missing", "--json"],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected failure exit")

    raw = capsys.readouterr()
    payload = json.loads(raw.out)
    assert raw.err == ""
    assert payload["ok"] is False
    assert payload["task_id"] == "missing"
    assert payload["error_info"]["code"] == "task_not_found"


def test_run_detach_json_worker_spawn_failure_keeps_task_id(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)

    def fail_spawn(*_args, **_kwargs):
        raise OSError("spawn denied")

    monkeypatch.setattr("transvortex.cli.entry.subprocess.Popen", fail_spawn)
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
            "--detach",
            "--json",
        ],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected failure exit")

    raw = capsys.readouterr()
    payload = json.loads(raw.out)
    assert raw.err == ""
    assert payload["ok"] is False
    assert payload["task_id"]
    assert payload["error_info"]["code"] == "runtime_error"
    store = TaskStore(tmp_path / "artifacts")
    task = store.load_task(payload["task_id"])
    assert task.status == "FAILED"


def test_detach_json_forwards_provider_and_memory_patch_overrides(tmp_path: Path, monkeypatch, capsys) -> None:
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
            "translate",
            "--segments",
            str(tmp_path / "segments.jsonl"),
            "--src",
            "en",
            "--tgt",
            "zh-CN",
            "--provider-timeout-seconds",
            "90",
            "--provider-retry",
            "5",
            "--provider-http2",
            "false",
            "--provider-streaming-enabled",
            "true",
            "--provider-connect-timeout-seconds",
            "11",
            "--provider-read-timeout-seconds",
            "77",
            "--translation-batching-mode",
            "adaptive",
            "--translation-min-chunk-lines",
            "12",
            "--memory-enabled",
            "true",
            "--memory-bootstrap-enabled",
            "false",
            "--memory-inject-enabled",
            "true",
            "--memory-intensity",
            "low",
            "--memory-patch-window-chunks",
            "4",
            "--detach",
            "--json",
        ],
    )
    (tmp_path / "segments.jsonl").write_text('{"id":1,"start":0,"end":1,"text_src":"hello"}\n', encoding="utf-8")

    main()

    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True
    assert "--provider-timeout-seconds" in spawned["cmd"]
    assert "90" in spawned["cmd"]
    assert "--provider-retry" in spawned["cmd"]
    assert "5" in spawned["cmd"]
    assert "--provider-http2" in spawned["cmd"]
    assert "--provider-streaming-enabled" in spawned["cmd"]
    assert "--provider-connect-timeout-seconds" in spawned["cmd"]
    assert "--provider-read-timeout-seconds" in spawned["cmd"]
    assert "--translation-batching-mode" in spawned["cmd"]
    assert "--translation-min-chunk-lines" in spawned["cmd"]
    assert "--memory-enabled" in spawned["cmd"]
    assert "--memory-bootstrap-enabled" in spawned["cmd"]
    assert "--memory-inject-enabled" in spawned["cmd"]
    assert "--memory-intensity" in spawned["cmd"]
    assert "low" in spawned["cmd"]
    assert "--memory-patch-window-chunks" in spawned["cmd"]
    assert "4" in spawned["cmd"]


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


def test_asr_json_status_print_failure_keeps_structured_task_error(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="asr_done",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="en",
        bilingual=False,
        status="DONE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)

    def fail_task_load(*_args, **_kwargs):
        raise OSError("stdout unavailable")

    monkeypatch.setattr("transvortex.cli.entry.run_pipeline", lambda **_kwargs: task.task_id)
    monkeypatch.setattr("transvortex.cli.entry._task_and_artifacts", fail_task_load)
    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "asr", "--input", "demo.mp4", "--src", "en", "--json"],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected failure exit")

    raw = capsys.readouterr()
    payload = json.loads(raw.out)
    assert raw.err == ""
    assert payload["ok"] is False
    assert payload["task_id"] == "asr_done"
    assert payload["error_info"]["code"] == "runtime_error"


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
    assert export_payload["delivery"]["ass"]["renderer"] == "presentation"

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
            "vtt",
            "--output",
            str(tmp_path / "web"),
            "--json",
        ],
    )
    main()
    vtt_payload = json.loads(capsys.readouterr().out)
    assert vtt_payload["output_format"] == "vtt"
    assert set(vtt_payload["output_paths"]) == {"vtt"}
    assert (tmp_path / "web.vtt").exists()
    assert vtt_payload["delivery"]["vtt"]["renderer"] == "web_html5"


def test_auth_cli_json_does_not_print_secret(tmp_path: Path, monkeypatch, capsys) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    _write_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "auth",
            "set",
            "p1",
            "--stdin",
            "--json",
        ],
    )
    monkeypatch.setattr("sys.stdin", io.StringIO("super-secret\n"))
    main()
    raw = capsys.readouterr().out
    assert "super-secret" not in raw
    payload = json.loads(raw)
    assert payload["credential_id"] == "p1"

    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "auth", "list", "--json"])
    main()
    listed = json.loads(capsys.readouterr().out)
    assert listed["credentials"] == [{"credential_id": "p1", "has_key": True}]

    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "auth", "status", "--json"])
    main()
    status = json.loads(capsys.readouterr().out)
    assert status["providers"][0]["has_key"] is True
    assert status["providers"][0]["source"] == "auth_json"

    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "auth", "delete", "p1", "--json"])
    main()
    deleted = json.loads(capsys.readouterr().out)
    assert deleted["deleted"] is True


def test_auth_cli_set_rejects_multiple_secret_inputs(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    _write_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "auth",
            "set",
            "p1",
            "--api-key",
            "super-secret",
            "--stdin",
            "--json",
        ],
    )
    try:
        main()
    except ValueError as exc:
        assert "Use only one" in str(exc)
    else:
        raise AssertionError("expected multiple secret inputs to be rejected")
