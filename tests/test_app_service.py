from __future__ import annotations

import json
import io
import subprocess
import sys
import time
from pathlib import Path

from transvortex.app.desktop_api import DesktopApi, task_payload
from transvortex.app.config import load_app_config
from transvortex.app.asr_runtime import load_asr_catalog
from transvortex.app.models import TaskRecord
from transvortex.app_service import LocalServicePump, handle_line, serve
from transvortex.artifacts.runtime import TaskRuntime
from transvortex.artifacts.task_store import TaskStore
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


def _use_unpublished_asr_catalog(tmp_path: Path, monkeypatch) -> None:
    catalog = load_asr_catalog()
    catalog["runtime"]["artifact"]["published"] = False
    catalog_path = tmp_path / "asr_components_unpublished.json"
    catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))


def _request(method: str, params: dict | None = None, request_id: int = 1) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})


def _task_record(
    *,
    input_file: str,
    input_type: str | None = None,
) -> TaskRecord:
    settings = {}
    if input_type is not None:
        settings["input_type"] = input_type
    return TaskRecord(
        task_id="task1",
        input_file=input_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="FAILED",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:01+00:00",
        settings=settings,
    )


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
    assert "derived_translation" in info["result"]["capabilities"]
    assert health["result"]["status"] == "healthy"
    assert health["result"]["pump"]["running"] is True
    assert set(health["result"]["runtime"]) == {"active"}
    assert shutdown["result"] == {"ok": True, "shutdown": "requested"}
    assert service.shutdown_requested is True
    assert stopped == [True]


def test_task_payload_exposes_explicit_input_type_without_display_classification() -> None:
    explicit = task_payload(
        _task_record(
            input_file=r"D:\artifacts\segments.jsonl",
            input_type="segments_translate",
        )
    )
    legacy_jsonl = task_payload(_task_record(input_file=r"D:\artifacts\legacy.jsonl"))

    assert explicit["input_type"] == "segments_translate"
    assert "desktop_view" not in explicit
    assert "origin" not in explicit
    assert legacy_jsonl["input_type"] == ""


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
    assert response["result"]["config"]["network"] == {
        "mode": "system",
        "proxy_port": 0,
    }


def test_app_service_saves_global_network_settings(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    snapshot = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)
    expected_version = snapshot["result"]["config"]["pipeline_file_version"]

    saved = handle_line(
        service,
        _request(
            "network.settings.save",
            {
                "mode": "local_proxy",
                "proxy_port": 7890,
                "expected_version": expected_version,
            },
        ),
        root_dir=tmp_path,
    )
    refreshed = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)
    config = load_app_config(root_dir=tmp_path)

    assert saved["result"]["network"] == {
        "mode": "local_proxy",
        "proxy_port": 7890,
    }
    assert saved["result"]["pipeline_file_version"]
    assert refreshed["result"]["config"]["network"] == saved["result"]["network"]
    assert config.network.mode == "local_proxy"
    assert config.network.proxy_port == 7890


def test_app_service_default_local_whisper_is_not_ready_without_component(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    _use_unpublished_asr_catalog(tmp_path, monkeypatch)
    service = DesktopApi(root_dir=tmp_path)

    config = handle_line(service, _request("config.get"), root_dir=tmp_path)["result"]
    selected = config["pipeline"]["asr_provider"]
    provider = config["asr_providers"][selected]

    assert provider["kind"] == "local_worker"
    assert provider["has_key"] is True
    assert provider["readiness"]["can_run"] is False
    assert provider["readiness"]["state"] == "needs_action"
    assert provider["readiness"]["code"] == "runtime_unpublished"

    status = handle_line(service, _request("asr.status"), root_dir=tmp_path)["result"]
    assert status["provider"] == selected
    assert status["kind"] == "local_worker"
    assert status["readiness"]["can_run"] is False


def test_app_service_rejects_unpublished_managed_runtime_install(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    _use_unpublished_asr_catalog(tmp_path, monkeypatch)
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(
        service,
        _request("asr.component.install", {"kind": "runtime"}),
        root_dir=tmp_path,
    )

    assert response["error"]["code"] == "component_unpublished"


def test_app_service_starts_one_managed_asr_setup_operation(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    received: list[str] = []

    def start_setup(model_id: str) -> dict:
        received.append(model_id)
        return {
            "id": "asr_setup_small",
            "kind": "setup",
            "item_id": model_id,
            "state": "queued",
            "phase": "runtime",
            "phase_index": 0,
            "phase_count": 3,
        }

    monkeypatch.setattr(service._asr_operation_manager, "start_setup", start_setup)

    response = handle_line(
        service,
        _request("asr.setup.start", {"model_id": "small"}),
        root_dir=tmp_path,
    )

    assert received == ["small"]
    assert response["result"]["kind"] == "setup"
    assert response["result"]["phase"] == "runtime"


def test_app_service_media_inspection_gates_only_audio_asr_without_ffprobe(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)

    subtitle = handle_line(
        service,
        _request("media.inspect", {"input": str(tmp_path / "source.srt")}),
        root_dir=tmp_path,
    )["result"]
    audio = handle_line(
        service,
        _request("media.inspect", {"input": str(tmp_path / "source.wav")}),
        root_dir=tmp_path,
    )["result"]

    assert subtitle["source_mode"] == "subtitle_file"
    assert subtitle["needs_asr"] is False
    assert audio["source_mode"] == "asr"
    assert audio["needs_asr"] is True


def test_app_service_exposes_registered_asr_environments(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    monkeypatch.setattr(
        "transvortex.app.desktop_api.discover_python_environments",
        lambda: [{"id": "external:test", "python_executable": r"C:\Python\python.exe", "source": "path"}],
    )

    response = handle_line(service, _request("asr.environment.discover"), root_dir=tmp_path)

    assert response["result"]["environments"][0]["id"] == "external:test"


def test_app_service_validates_existing_model_with_managed_runtime(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    captured = {}

    def fake_probe(**kwargs):  # noqa: ANN003
        captured.update(kwargs)
        return {
            "ok": True,
            "model": {
                "model_id": "large-v3",
                "model_path": str(kwargs["model_path"]),
            },
        }

    monkeypatch.setattr("transvortex.app.desktop_api.probe_managed_model", fake_probe)

    response = handle_line(
        service,
        _request(
            "asr.model.probe",
            {
                "model_path": str(tmp_path / "large-v3"),
                "device": "cpu",
                "compute_type": "int8",
            },
        ),
        root_dir=tmp_path,
    )

    assert response["result"]["ok"] is True
    assert captured["root_dir"] == tmp_path
    assert captured["model_path"] == tmp_path / "large-v3"
    assert captured["device"] == "cpu"
    assert captured["compute_type"] == "int8"


def test_app_service_runs_asr_provider_test_for_saved_provider(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: funasr
asr_providers:
  - name: funasr
    kind: local_server
    protocol: funasr_openai
    model: sensevoice
    base_url: http://127.0.0.1:8899
    auth: {type: none}
        """.strip(),
        encoding="utf-8",
    )
    captured = {}

    def fake_test(provider, *, root_dir, source_lang):  # noqa: ANN001
        captured.update(provider=provider, root_dir=root_dir, source_lang=source_lang)
        return {"ok": True, "code": "ready"}

    monkeypatch.setattr("transvortex.app.desktop_api.run_asr_connection_test", fake_test)
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(
        service,
        _request("asr.provider.test", {"provider": "funasr", "source_lang": "ja"}),
        root_dir=tmp_path,
    )

    assert response["result"]["ok"] is True
    assert captured["provider"].protocol == "funasr_openai"
    assert captured["source_lang"] == "ja"


def test_app_service_forwards_reasoning_effort_to_provider_test(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    captured = {}

    def fake_test(**kwargs):  # noqa: ANN003
        captured.update(kwargs)
        return {"status": "PASS", "checks": []}

    monkeypatch.setattr("transvortex.app.desktop_api.run_provider_connection_test", fake_test)
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(
        service,
        _request(
            "provider.test",
            {
                "provider_draft": {
                    "name": "p1",
                    "base_url": "https://example.com/v1",
                    "models": ["m1"],
                },
                "model": "m1",
                "reasoning_effort": "high",
            },
        ),
        root_dir=tmp_path,
    )

    assert response["result"]["status"] == "PASS"
    assert captured["model"] == "m1"
    assert captured["reasoning_effort"] == "high"


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


def test_app_service_subprocess_uses_explicit_artifacts_directory(tmp_path: Path) -> None:
    _write_config(tmp_path)
    desktop_tasks = tmp_path / "desktop-workspace" / "Tasks"
    desktop_cache = tmp_path / "desktop-workspace" / "Cache"
    request = (
        _request("config.get")
        + "\n"
        + _request("service.shutdown", request_id=2)
        + "\n"
    )

    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "transvortex.app_service",
            "--root",
            str(tmp_path),
            "--artifacts-dir",
            str(desktop_tasks),
            "--cache-dir",
            str(desktop_cache),
            "--no-pump",
        ],
        input=request,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )

    lines = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert Path(lines[0]["result"]["artifacts_dir"]) == desktop_tasks
    assert desktop_tasks.is_dir()
    assert desktop_cache.is_dir()
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


def test_local_service_pump_explicit_queue_only_waits_for_allowed_task(tmp_path: Path) -> None:
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

    pump = LocalServicePump(root_dir=tmp_path, worker_launcher=fake_launcher, explicit_queue_only=True)
    pump.tick()
    pump.allow_task(task_id)
    pump.tick()

    assert len(launched) == 1
    assert launched[0]["worker_args"] == ["_worker", "--task-id", task_id]


def test_app_service_submit_notifies_pump_allow_callback(tmp_path: Path) -> None:
    _write_config(tmp_path)
    allowed: list[str] = []
    service = DesktopApi(root_dir=tmp_path, task_ready_callback=allowed.append)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }

    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)

    assert allowed == [submitted["result"]["task_id"]]


def test_app_service_retranslate_copies_saved_source_and_records_provenance(tmp_path: Path) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    parent = TaskRecord(
        task_id="tvx_parent",
        input_file=str(tmp_path / "movie.mp4"),
        source_lang="ja",
        target_lang="zh-CN",
        bilingual=True,
        status="DONE",
        created_at="2026-07-11T00:00:00+00:00",
        updated_at="2026-07-11T00:10:00+00:00",
        settings={"input_type": "video_asr_translate"},
    )
    store.save_task(parent)
    source = store.task_dir(parent.task_id) / "source" / "segments.normalized.jsonl"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text('{"id":1,"start":0,"end":1,"text_src":"こんにちは"}\n', encoding="utf-8")
    allowed: list[str] = []
    service = DesktopApi(root_dir=tmp_path, task_ready_callback=allowed.append)

    response = handle_line(
        service,
        _request(
            "runtime.retranslate",
            {
                "task_id": parent.task_id,
                "provider": "p1",
                "model": "m1",
                "overrides": {"memory_bootstrap_enabled": False},
            },
        ),
        root_dir=tmp_path,
    )

    child_id = response["result"]["task_id"]
    child = store.load_task(child_id)
    copied_source = Path(child.input_file)
    assert response["result"]["status"] == "QUEUED"
    assert child_id != parent.task_id
    assert copied_source.parent == store.task_dir(child_id) / "inputs"
    assert copied_source.read_text(encoding="utf-8") == source.read_text(encoding="utf-8")
    assert child.settings["input_type"] == "segments_translate"
    assert child.settings["provenance"]["derived_from_task_id"] == parent.task_id
    assert len(child.settings["provenance"]["source_sha256"]) == 64
    runtime_request = json.loads((store.task_dir(child_id) / "runtime_request.json").read_text(encoding="utf-8"))
    assert runtime_request["request"]["input"] == str(copied_source)
    assert runtime_request["request"]["overrides"]["memory_bootstrap_enabled"] is False
    assert allowed == [child_id]
    source.unlink()
    assert copied_source.exists()


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
