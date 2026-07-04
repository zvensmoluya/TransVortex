from __future__ import annotations

import json
import io
import subprocess
import sys
import time
from pathlib import Path

from transvortex.app.desktop_api import DesktopApi
from transvortex.app_service import LocalServicePump, handle_line, serve
from transvortex.artifacts.runtime import TaskRuntime
from transvortex.cli import main as cli_main
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


def _request(method: str, params: dict | None = None, request_id: int = 1) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})


def test_app_service_ping_and_unknown_method(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    ping = handle_line(service, _request("desktop.ping"), root_dir=tmp_path)
    missing = handle_line(service, _request("missing.method"), root_dir=tmp_path)

    assert ping["result"]["ok"] is True
    assert missing["error"]["code"] == "method_not_found"


def test_app_service_info_health_and_shutdown(tmp_path: Path) -> None:
    _write_config(tmp_path)
    stopped = []
    service = DesktopApi(
        root_dir=tmp_path,
        pump_status=lambda: {"enabled": True, "running": True, "last_error": ""},
        shutdown_callback=lambda: stopped.append(True),
    )

    info = handle_line(service, _request("service.info"), root_dir=tmp_path)
    health = handle_line(service, _request("service.health"), root_dir=tmp_path)
    shutdown = handle_line(service, _request("service.shutdown"), root_dir=tmp_path)

    assert info["result"]["service"] == "transvortex.app_service"
    assert info["result"]["protocol_version"] == 1
    assert "runtime_pump" in info["result"]["capabilities"]
    assert health["result"]["status"] == "healthy"
    assert health["result"]["pump"]["running"] is True
    assert set(health["result"]["runtime"]) == {"active"}
    assert shutdown["result"] == {"ok": True, "shutdown": "requested"}
    assert service.shutdown_requested is True
    assert stopped == [True]


def test_app_service_serve_tolerates_utf8_bom_on_first_line(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    stdin = io.StringIO(
        "\ufeff"
        + _request("service.info", request_id=1)
        + "\n"
        + _request("service.shutdown", request_id=2)
        + "\n"
    )
    stdout = io.StringIO()
    monkeypatch.setattr(sys, "stdin", stdin)
    monkeypatch.setattr(sys, "stdout", stdout)

    serve(service, root_dir=tmp_path)

    responses = [json.loads(line) for line in stdout.getvalue().splitlines()]
    assert responses[0]["result"]["service"] == "transvortex.app_service"
    assert responses[1]["result"]["ok"] is True
    assert "error" not in responses[0]


def test_app_service_health_reads_active_without_snapshot(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    config = DesktopApi(root_dir=tmp_path).config_get({})
    active_path = Path(config["artifacts_dir"]) / ".runtime" / "active.json"
    write_json(active_path, {"task_id": "task1", "state": "running"})
    called = []

    def forbidden_snapshot(self):  # noqa: ANN001
        called.append("snapshot")
        raise AssertionError("health must not call snapshot")

    def forbidden_reconcile(self):  # noqa: ANN001
        called.append("reconcile")
        raise AssertionError("health must not call reconcile")

    monkeypatch.setattr(TaskRuntime, "snapshot", forbidden_snapshot)
    monkeypatch.setattr(TaskRuntime, "reconcile", forbidden_reconcile)

    response = handle_line(DesktopApi(root_dir=tmp_path), _request("service.health"), root_dir=tmp_path)

    assert response["result"]["runtime"]["active"]["task_id"] == "task1"
    assert called == []


def test_app_service_health_tolerates_missing_and_corrupt_active(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)

    missing = handle_line(service, _request("service.health"), root_dir=tmp_path)
    active_path = Path(missing["result"]["runtime"].get("active") or tmp_path / "artifacts" / ".runtime" / "active.json")
    active_path.parent.mkdir(parents=True, exist_ok=True)
    active_path.write_text("{bad", encoding="utf-8")
    corrupt = handle_line(service, _request("service.health"), root_dir=tmp_path)

    assert missing["result"]["runtime"]["active"] is None
    assert corrupt["result"]["runtime"]["active"] is None


def test_app_service_health_degraded_when_pump_reports_error(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(
        root_dir=tmp_path,
        pump_status=lambda: {"enabled": True, "running": True, "last_error": "pump_tick_failed"},
    )

    response = handle_line(service, _request("service.health"), root_dir=tmp_path)

    assert response["result"]["status"] == "degraded"
    assert response["result"]["pump"]["last_error"] == "pump_tick_failed"


def test_app_service_invalid_json_returns_parse_error(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, "{bad", root_dir=tmp_path)

    assert response["id"] is None
    assert response["error"]["code"] == "parse_error"


def test_app_service_config_get_matches_cli_and_redacts_secret(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("config.get"), root_dir=tmp_path)
    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "config", "show", "--json"])
    cli_main()
    cli_payload = json.loads(capsys.readouterr().out)
    raw_response = json.dumps(response, ensure_ascii=False)

    payload = response["result"]
    assert "super-secret-value" not in raw_response
    assert payload["providers"][0]["name"] == cli_payload["providers"][0]["name"]
    assert payload["providers"][0]["has_key"] is True
    assert payload["routing"]["primary"] == cli_payload["routing"]["primary"]
    assert payload["custom_adapter_template"]["id"] == "custom_json"


def test_app_service_desktop_snapshot_contains_control_plane_payloads(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)

    assert "config" in response["result"]
    assert "tasks" in response["result"]
    assert "runtime" in response["result"]
    assert "environment" in response["result"]
    assert response["result"]["config"]["pipeline_file_version"]


def test_app_service_desktop_snapshot_preserves_translation_when_asr_config_invalid(
    tmp_path: Path,
    monkeypatch,
) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "configured")
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  provider: missing_local
asr_providers:
  - name: local
    kind: local_inprocess
    protocol: faster_whisper
    model: large-v3
        """.strip(),
        encoding="utf-8",
    )
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)

    result = response["result"]
    config = result["config"]
    assert "ASR provider not found: missing_local" in result["config_error"]
    assert config["routing"]["primary"] == {"provider": "p1", "model": "m1"}
    assert config["providers"][0]["name"] == "p1"
    assert config["providers"][0]["has_key"] is True
    assert config["pipeline"]["asr_provider"] == "missing_local"
    assert "local" in config["asr_providers"]


def test_app_service_runtime_submit_and_acquire(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }

    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    acquired = handle_line(service, _request("runtime.acquireNext"), root_dir=tmp_path)

    task_id = submitted["result"]["task_id"]
    assert submitted["result"]["status"] == "QUEUED"
    assert acquired["result"]["acquired"] is True
    assert acquired["result"]["launch"]["task_id"] == task_id
    assert (tmp_path / "artifacts" / task_id / "runtime_request.json").exists()


def test_app_service_tasks_events_uses_cursor_payload(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }
    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    task_id = submitted["result"]["task_id"]
    handle_line(service, _request("runtime.cancel", {"task_id": task_id}), root_dir=tmp_path)

    first = handle_line(service, _request("tasks.events", {"task_id": task_id, "cursor": 0, "limit": 1}), root_dir=tmp_path)
    second = handle_line(
        service,
        _request("tasks.events", {"task_id": task_id, "cursor": first["result"]["next_cursor"], "limit": 1}),
        root_dir=tmp_path,
    )

    assert first["result"]["task_id"] == task_id
    assert first["result"]["cursor"] == 0
    assert len(first["result"]["events"]) == 1
    assert first["result"]["next_cursor"] == 1
    assert second["result"]["cursor"] == 1


def test_app_service_runtime_cancel_force_after_grace_is_non_blocking(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }
    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    task_id = submitted["result"]["task_id"]

    start = time.monotonic()
    cancelled = handle_line(
        service,
        _request("runtime.cancel", {"task_id": task_id, "force_after_grace": 10}),
        root_dir=tmp_path,
    )
    elapsed = time.monotonic() - start

    assert elapsed < 1.0
    assert cancelled["result"]["status"] == "CANCEL_REQUESTED"


def test_app_service_auth_list_does_not_return_secret(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    service = DesktopApi(root_dir=tmp_path)

    saved = handle_line(
        service,
        _request("auth.set", {"credential_id": "p1", "api_key": "secret-token"}),
        root_dir=tmp_path,
    )
    listed = handle_line(service, _request("auth.list"), root_dir=tmp_path)
    raw = json.dumps(listed, ensure_ascii=False)

    assert saved["result"]["credential_id"] == "p1"
    assert "secret-token" not in raw
    assert listed["result"]["credentials"] == [{"credential_id": "p1", "has_key": True}]


def test_app_service_asr_provider_save_updates_pipeline_and_redacts_key(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(
        service,
        _request(
            "asr.provider.save",
            {
                "provider_draft": {
                    "name": "openai_asr",
                    "kind": "remote",
                    "protocol": "openai_transcriptions",
                    "base_url": "https://api.openai.com",
                    "endpoint": "/v1/audio/transcriptions",
                    "model": "whisper-1",
                    "auth": {
                        "type": "bearer",
                        "env_key": "OPENAI_API_KEY",
                        "credential_id": "openai_asr",
                    },
                },
                "api_key": "secret-asr-token",
            },
        ),
        root_dir=tmp_path,
    )
    snapshot = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)
    raw_response = json.dumps(response, ensure_ascii=False)
    config = snapshot["result"]["config"]

    assert response["result"]["provider"] == "openai_asr"
    assert "secret-asr-token" not in raw_response
    assert config["pipeline"]["asr_provider"] == "openai_asr"
    assert config["asr_providers"]["openai_asr"]["kind"] == "remote"
    assert config["asr_providers"]["openai_asr"]["has_key"] is True


def test_app_service_subprocess_smoke(tmp_path: Path) -> None:
    _write_config(tmp_path)
    request = _request("desktop.ping") + "\n"

    proc = subprocess.run(
        [sys.executable, "-m", "transvortex.app_service", "--root", str(tmp_path)],
        input=request,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )

    payload = json.loads(proc.stdout.strip())
    assert payload["result"]["service"] == "transvortex.app_service"
    assert proc.stderr == ""


def test_app_service_subprocess_shutdown_smoke(tmp_path: Path) -> None:
    _write_config(tmp_path)
    request = _request("service.shutdown") + "\n"

    proc = subprocess.run(
        [sys.executable, "-m", "transvortex.app_service", "--root", str(tmp_path)],
        input=request,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )

    payload = json.loads(proc.stdout.strip())
    assert payload["result"]["shutdown"] == "requested"


def test_app_service_subprocess_no_pump_health(tmp_path: Path) -> None:
    _write_config(tmp_path)
    request = _request("service.health") + "\n" + _request("service.shutdown", request_id=2) + "\n"

    proc = subprocess.run(
        [sys.executable, "-m", "transvortex.app_service", "--root", str(tmp_path), "--no-pump"],
        input=request,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )

    lines = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert lines[0]["result"]["pump"]["running"] is False
    assert lines[1]["result"]["shutdown"] == "requested"


def test_local_service_pump_launches_queued_worker(tmp_path: Path) -> None:
    _write_config(tmp_path)
    launched = []
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }
    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    task_id = submitted["result"]["task_id"]

    def fake_launcher(**kwargs):
        launched.append(kwargs)
        return {"pid": 12345, "stdout_log": "stdout.log", "stderr_log": "stderr.log"}

    pump = LocalServicePump(root_dir=tmp_path, worker_launcher=fake_launcher)
    pump.tick()

    assert launched[0]["worker_args"] == ["_worker", "--task-id", task_id]
    events = handle_line(service, _request("tasks.events", {"task_id": task_id}), root_dir=tmp_path)["result"]["events"]
    assert events[-1]["type"] == "worker_launch_requested"


def test_local_service_pump_does_not_reconcile_twice(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    calls = []
    original_reconcile = TaskRuntime.reconcile

    def counted_reconcile(self):  # noqa: ANN001
        calls.append("reconcile")
        return original_reconcile(self)

    monkeypatch.setattr(TaskRuntime, "reconcile", counted_reconcile)

    pump = LocalServicePump(root_dir=tmp_path, worker_launcher=lambda **_kwargs: {"pid": 123})
    pump.tick()

    assert calls == ["reconcile"]


def test_local_service_pump_release_active_when_launch_fails(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }
    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    task_id = submitted["result"]["task_id"]

    def failing_launcher(**_kwargs):
        raise RuntimeError("launch exploded")

    pump = LocalServicePump(root_dir=tmp_path, worker_launcher=failing_launcher)
    try:
        pump.tick()
    except RuntimeError:
        pass

    task = handle_line(service, _request("tasks.list"), root_dir=tmp_path)["result"][0]
    events = handle_line(service, _request("tasks.events", {"task_id": task_id}), root_dir=tmp_path)["result"]["events"]
    assert task["status"] == "INTERRUPTED"
    assert events[-1]["type"] == "worker_launch_failed"
