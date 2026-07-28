from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from transvortex.cli import main
from transvortex.cli.entry import _print_json, _print_jsonl_event
from transvortex.app.desktop_requests import (
    RequestValidationError,
    resume_request_from_payload,
    run_request_from_flags,
    run_request_from_payload,
    run_request_to_payload,
)
from transvortex.protocol.errors import PipelineTaskError, error_info
from transvortex.app.models import TaskRecord
from transvortex.artifacts.runtime import TaskRuntime
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


def test_machine_json_output_is_ascii_safe(capsys) -> None:
    payload = {"hint_zh": "中文诊断", "label": "识别资源"}

    _print_json(payload)
    json_output = capsys.readouterr().out
    assert json_output.isascii()
    assert json.loads(json_output) == payload

    event = {"type": "progress", "task_id": "t1", "message": "处理中"}
    _print_jsonl_event(event)
    jsonl_output = capsys.readouterr().out
    assert jsonl_output.isascii()
    assert json.loads(jsonl_output) == event


def test_machine_json_subprocess_is_ascii_without_encoding_environment() -> None:
    env = os.environ.copy()
    env.pop("PYTHONIOENCODING", None)
    env.pop("PYTHONUTF8", None)
    code = "from transvortex.cli.entry import _print_json; _print_json({'hint_zh': '中文诊断'})"

    proc = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        env=env,
        timeout=10,
        check=True,
    )

    assert proc.stdout.isascii()
    assert json.loads(proc.stdout.decode("ascii")) == {"hint_zh": "中文诊断"}


def test_status_events_and_cancel_cli_json(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t1",
        input_file="中文视频.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="ASR",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)
    TaskRuntime(tmp_path / "artifacts").register_worker(task_id="t1", pid=os.getpid(), owner="test")
    store.append_event("t1", "stage", stage="ASR", message="处理中", progress=0.25)

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "status", "--task-id", "t1", "--json"],
    )
    main()
    status_output = capsys.readouterr().out
    assert status_output.isascii()
    payload = json.loads(status_output)
    assert payload["task_id"] == "t1"
    assert payload["status"] == "ASR"
    assert payload["input_file"] == "中文视频.mp4"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "events", "--task-id", "t1"],
    )
    main()
    events_output = capsys.readouterr().out
    assert events_output.isascii()
    events = [json.loads(line) for line in events_output.splitlines()]
    assert any(event["type"] == "stage" for event in events)
    assert any(event["message"] == "处理中" for event in events)

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
    assert payload["model_catalog"]
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
            "--asr-engine",
            "faster_whisper_large_v3",
            "--asr-model",
            "large-v3-turbo",
            "--stream-events",
        ],
    )
    main()
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [event["type"] for event in events] == ["task_created", "done"]
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["asr_provider"] == "faster_whisper_large_v3"
    assert captured["cli_overrides"]["asr_model"] == "large-v3-turbo"


def test_run_request_contract_matches_flags_and_json(tmp_path: Path) -> None:
    input_file = tmp_path / "demo.mp4"
    output_dir = tmp_path / "out"
    output_file = output_dir / "demo.zh-CN.srt"
    overrides = {
        "source_mode": "asr",
        "output_format": "both",
        "memory_bootstrap_enabled": True,
        "memory_inject_enabled": False,
        "memory_patch_enabled": True,
        "memory_presets": [{"id": "anime"}],
    }

    from_flags = run_request_from_flags(
        input_path=str(input_file),
        input_type="video",
        source_lang="ja",
        target_lang="zh-CN",
        bilingual=True,
        output=str(output_file),
        provider="p1",
        model="m1",
        overrides=overrides,
    )
    from_json = run_request_from_payload(
        {
            "request_version": 1,
            "input": str(input_file),
            "input_type": "video",
            "source_lang": "ja",
            "target_lang": "zh-CN",
            "bilingual": True,
            "output_dir": str(output_dir),
            "provider": "p1",
            "model": "m1",
            "overrides": overrides,
        }
    )

    assert from_json == from_flags


def test_request_json_preserves_routing_outside_overrides(tmp_path: Path) -> None:
    routing = {
        "primary": {"provider": "p2", "model": "m2"},
        "fallback": [{"provider": "p1", "model": "m1"}],
    }
    request = run_request_from_payload(
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "ja",
            "target_lang": "zh-CN",
            "routing": routing,
            "overrides": {"output_format": "srt"},
        }
    )
    resume = resume_request_from_payload(
        {
            "request_version": 1,
            "task_id": "tvx_1",
            "routing": routing,
        }
    )

    normalized_routing = {
        "primary": {"provider": "p2", "model": "m2", "reasoning_effort": "auto"},
        "fallback": [{"provider": "p1", "model": "m1", "reasoning_effort": "auto"}],
    }
    assert request.routing == normalized_routing
    assert resume.routing == normalized_routing
    assert "routing" not in request.overrides
    assert run_request_to_payload(request)["routing"] == normalized_routing


def test_request_json_preserves_reasoning_effort_and_rejects_unknown_value(tmp_path: Path) -> None:
    request = run_request_from_payload(
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "ja",
            "target_lang": "zh-CN",
            "routing": {
                "primary": {
                    "provider": "p2",
                    "model": "m2",
                    "reasoning_effort": "service_default",
                },
                "fallback": [],
            },
        }
    )
    assert request.routing["primary"]["reasoning_effort"] == "service_default"

    with pytest.raises(RequestValidationError, match="reasoning_effort"):
        run_request_from_payload(
            {
                "request_version": 1,
                "input": str(tmp_path / "demo.mp4"),
                "source_lang": "ja",
                "target_lang": "zh-CN",
                "routing": {
                    "primary": {
                        "provider": "p2",
                        "model": "m2",
                        "reasoning_effort": "turbo",
                    },
                    "fallback": [],
                },
            }
        )


def test_request_json_rejects_incomplete_routing(tmp_path: Path) -> None:
    with pytest.raises(RequestValidationError, match="routing.primary.provider"):
        run_request_from_payload(
            {
                "request_version": 1,
                "input": str(tmp_path / "demo.mp4"),
                "source_lang": "ja",
                "target_lang": "zh-CN",
                "routing": {},
            }
        )
    with pytest.raises(RequestValidationError, match=r"routing\.fallback\[0\]"):
        resume_request_from_payload(
            {
                "request_version": 1,
                "task_id": "tvx_1",
                "routing": {
                    "primary": {"provider": "p1", "model": "m1"},
                    "fallback": [{"provider": "p2"}],
                },
            }
        )


def test_run_request_json_stream_events_uses_pipeline_contract(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "run-request.json"
    write_json(
        request_file,
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "input_type": "video",
            "source_lang": "ja",
            "target_lang": "zh-CN",
            "bilingual": True,
            "provider": "p1",
            "model": "m1",
            "overrides": {
                "source_mode": "asr",
                "output_format": "both",
                "memory_bootstrap_enabled": True,
                "memory_inject_enabled": False,
                "memory_patch_enabled": True,
            },
        },
    )
    captured = {}

    def fake_run_pipeline(**kwargs):
        captured.update(kwargs)
        kwargs["event_sink"]({"type": "task_created", "task_id": "json-task", "message": "created"})
        kwargs["event_sink"]({"type": "done", "task_id": "json-task", "message": "done"})
        return "json-task"

    monkeypatch.setattr("transvortex.cli.entry.run_pipeline", fake_run_pipeline)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--request-json",
            str(request_file),
            "--stream-events",
        ],
    )

    main()

    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert events[0]["type"] == "task_created"
    assert captured["input_file"] == tmp_path / "demo.mp4"
    assert captured["input_type"] == "video_asr_translate"
    assert captured["source_lang"] == "ja"
    assert captured["target_lang"] == "zh-CN"
    assert captured["bilingual"] is True
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["source_mode"] == "asr"
    assert captured["cli_overrides"]["memory_inject_enabled"] is False
    assert captured["cli_overrides"]["memory_patch_enabled"] is True


def test_resume_request_json_stream_events_uses_pipeline_contract(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "resume-request.json"
    write_json(
        request_file,
        {
            "request_version": 1,
            "task_id": "task-json",
            "output": str(tmp_path / "out.srt"),
            "provider": "p1",
            "model": "m1",
            "overrides": {"memory_patch_enabled": True},
        },
    )
    captured = {}

    def fake_resume_pipeline(**kwargs):
        captured.update(kwargs)
        kwargs["event_sink"]({"type": "resume_requested", "task_id": kwargs["task_id"], "message": "resume"})
        return kwargs["task_id"]

    monkeypatch.setattr("transvortex.cli.entry.resume_pipeline", fake_resume_pipeline)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "resume",
            "--request-json",
            str(request_file),
            "--stream-events",
        ],
    )

    main()

    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert events[0]["type"] == "resume_requested"
    assert captured["task_id"] == "task-json"
    assert captured["output_file"] == tmp_path / "out.srt"
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["memory_patch_enabled"] is True


def test_run_request_json_validation_errors_are_structured(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "bad-request.json"
    write_json(
        request_file,
        {
            "request_version": 2,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "ja",
            "target_lang": "zh-CN",
        },
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--request-json",
            str(request_file),
            "--json",
        ],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected validation failure")

    raw = capsys.readouterr()
    payload = json.loads(raw.out)
    assert raw.err == ""
    assert payload["ok"] is False
    assert payload["error_info"]["code"] == "invalid_request"
    assert "request_version" in payload["error_info"]["message"]


def test_run_request_json_rejects_mixed_business_flags_as_structured_error(
    tmp_path: Path,
    monkeypatch,
    capsys,
) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "run-request.json"
    write_json(
        request_file,
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "ja",
            "target_lang": "zh-CN",
        },
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "run",
            "--request-json",
            str(request_file),
            "--input",
            "other.mp4",
            "--json",
        ],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected validation failure")

    payload = json.loads(capsys.readouterr().out)
    assert payload["error_info"]["code"] == "invalid_request"
    assert "--input" in payload["error_info"]["message"]


def test_resume_request_json_rejects_missing_task_id_as_jsonl_error(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "resume-request.json"
    write_json(request_file, {"request_version": 1})
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "resume",
            "--request-json",
            str(request_file),
            "--stream-events",
        ],
    )

    try:
        main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError("expected validation failure")

    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert len(events) == 1
    assert events[0]["type"] == "error"
    assert events[0]["task_id"] == ""
    assert events[0]["message"] == "task_id is required"
    assert events[0]["details"]["error_info"]["code"] == "invalid_request"


def test_runtime_submit_and_acquire_cli_json(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    request_file = tmp_path / "run-request.json"
    write_json(
        request_file,
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "en",
            "target_lang": "zh-CN",
            "provider": "p1",
            "model": "m1",
        },
    )

    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "runtime",
            "submit-run",
            "--request-json",
            str(request_file),
            "--json",
        ],
    )
    main()
    submitted = json.loads(capsys.readouterr().out)
    assert submitted["status"] == "QUEUED"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "runtime", "acquire-next", "--json"],
    )
    main()
    acquired = json.loads(capsys.readouterr().out)
    assert acquired["acquired"] is True
    assert acquired["launch"]["task_id"] == submitted["task_id"]
    assert acquired["launch"]["args"] == ["_worker", "--task-id", submitted["task_id"]]


def test_status_json_includes_runtime_payload(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    store.save_task(
        TaskRecord(
            task_id="runtime-status",
            input_file="demo.mp4",
            source_lang="en",
            target_lang="zh-CN",
            bilingual=False,
            status="INTERRUPTED",
            created_at="2026-02-13T00:00:00+00:00",
            updated_at="2026-02-13T00:00:00+00:00",
        )
    )

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "status", "--task-id", "runtime-status", "--json"],
    )
    main()
    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "INTERRUPTED"
    assert payload["runtime"]["state"] == "interrupted"
    assert payload["runtime"]["can_resume"] is True


def test_worker_uses_saved_runtime_request(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    store.save_task(
        TaskRecord(
            task_id="worker-runtime",
            input_file=str(tmp_path / "demo.mp4"),
            source_lang="en",
            target_lang="zh-CN",
            bilingual=False,
            status="QUEUED",
            created_at="2026-02-13T00:00:00+00:00",
            updated_at="2026-02-13T00:00:00+00:00",
        )
    )
    from transvortex.artifacts.runtime import TaskRuntime

    TaskRuntime(tmp_path / "artifacts").save_runtime_request(
        "worker-runtime",
        "run",
        {
            "request_version": 1,
            "input": str(tmp_path / "demo.mp4"),
            "source_lang": "en",
            "target_lang": "zh-CN",
            "output": str(tmp_path / "out.srt"),
            "provider": "p1",
            "model": "m1",
            "overrides": {"source_mode": "asr"},
        },
    )
    captured = {}

    def fake_execute_pipeline_task(**kwargs):
        captured.update(kwargs)
        kwargs["event_sink"]({"type": "done", "task_id": kwargs["task_id"], "stage": "DONE", "message": "done"})
        return kwargs["task_id"]

    monkeypatch.setattr("transvortex.cli.entry.execute_pipeline_task", fake_execute_pipeline_task)
    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "_worker", "--task-id", "worker-runtime"],
    )

    main()

    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert events[-1]["type"] == "done"
    assert captured["output_file"] == tmp_path / "out.srt"
    assert captured["provider_name"] == "p1"
    assert captured["model"] == "m1"
    assert captured["cli_overrides"]["source_mode"] == "asr"


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
    assert payload["commands"]["run"]["supports_request_json"] is True
    assert payload["commands"]["resume"]["supports_request_json"] is True
    assert payload["commands"]["memory bootstrap"]["supports_dry_run"] is True
    assert payload["commands"]["memory export-preset"]["supports_dry_run"] is True
    assert "QUEUED" in payload["statuses"]
    assert "MEMORY" in payload["statuses"]
    assert "INTERRUPTED" in payload["statuses"]
    assert "source/segments.raw.jsonl" in payload["artifact_contract"]
    assert "source/segments.normalized.jsonl" in payload["artifact_contract"]
    assert "quality/source_cleaning.json" in payload["artifact_contract"]
    assert "quality/asr_boundary_quality.json" in payload["artifact_contract"]
    assert "quality/asr_word_overlap.json" in payload["artifact_contract"]
    assert "quality/subtitle_delivery.json" in payload["artifact_contract"]
    assert "output/*.vtt" in payload["artifact_contract"]
    assert "output/*.lrc" in payload["artifact_contract"]
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
            "--subtitle-bilingual-order",
            "source_target",
            "--subtitle-prefer-single-line",
            "false",
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
    assert "--subtitle-bilingual-order" in spawned["cmd"]
    assert "source_target" in spawned["cmd"]
    assert "--subtitle-prefer-single-line" in spawned["cmd"]
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
    (tmp_path / "pipeline.yaml").write_text(
        "\n".join(
            [
                "artifacts_dir: artifacts",
                "subtitle_ass_style:",
                "  font_name: Arial",
                "  font_size: 37",
            ]
        ),
        encoding="utf-8",
    )
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
    assert "Style: Target,Arial,37" in (tmp_path / "out.ass").read_text(encoding="utf-8-sig")
    assert export_payload["delivery"]["ass"]["fonts"]["target"].startswith("Arial")
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
            "lrc",
            "--output",
            str(tmp_path / "lyrics"),
            "--json",
        ],
    )
    main()
    lrc_payload = json.loads(capsys.readouterr().out)
    assert lrc_payload["output_format"] == "lrc"
    assert set(lrc_payload["output_paths"]) == {"lrc"}
    assert (tmp_path / "lyrics.lrc").exists()
    assert lrc_payload["delivery"] == {}


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
