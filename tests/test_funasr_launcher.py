from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import pytest

from transvortex.app.funasr_launcher import FunAsrLauncher, FunAsrLauncherError
from transvortex.app.desktop_api import DesktopApi
from transvortex.cli import main as cli_main


def _config(tmp_path: Path) -> dict[str, object]:
    return {
        "executable": sys.executable,
        "arguments": ["-m", "funasr_server"],
        "working_directory": str(tmp_path),
        "health_url": "http://127.0.0.1:8899/health",
        "stop_on_service_exit": True,
    }


def test_funasr_launcher_persists_a_validated_argv_recipe(tmp_path: Path) -> None:
    launcher = FunAsrLauncher(root_dir=tmp_path)

    saved = launcher.save_config(_config(tmp_path))

    assert saved["configured"] is True
    assert saved["config"]["executable"] == str(Path(sys.executable).resolve())
    assert saved["config"]["arguments"] == ["-m", "funasr_server"]
    assert (tmp_path / "funasr_launcher.json").is_file()


def test_funasr_launcher_rejects_shell_commands_and_non_loopback_health_url(tmp_path: Path) -> None:
    launcher = FunAsrLauncher(root_dir=tmp_path)
    invalid = _config(tmp_path)
    invalid["executable"] = "python -m funasr_server"
    with pytest.raises(FunAsrLauncherError, match="absolute file path"):
        launcher.save_config(invalid)

    invalid = _config(tmp_path)
    invalid["health_url"] = "https://example.com/health"
    with pytest.raises(FunAsrLauncherError, match="local http loopback"):
        launcher.save_config(invalid)


def test_funasr_launcher_starts_argv_without_blocking_and_becomes_ready(
    tmp_path: Path,
    monkeypatch,
) -> None:
    launcher = FunAsrLauncher(root_dir=tmp_path)
    launcher.save_config(_config(tmp_path))
    calls: dict[str, object] = {}

    class Process:
        pid = 1234

        def poll(self):  # noqa: ANN201
            return None

    def fake_popen(argv, **kwargs):  # noqa: ANN001, ANN201
        calls["argv"] = argv
        calls["kwargs"] = kwargs
        return Process()

    monkeypatch.setattr("transvortex.app.funasr_launcher.subprocess.Popen", fake_popen)
    health_calls = 0

    def fake_health(_url: str, *, timeout: float) -> bool:
        nonlocal health_calls
        health_calls += 1
        return health_calls > 1

    monkeypatch.setattr(FunAsrLauncher, "_health_ready", staticmethod(fake_health))

    result = launcher.start(timeout_seconds=1)
    deadline = time.monotonic() + 1
    while result["state"] != "ready" and time.monotonic() < deadline:
        time.sleep(0.01)
        result = launcher.status(probe_health=False)

    assert result["state"] == "ready"
    assert result["healthy"] is True
    assert result["owned"] is True
    assert result["pid"] == 1234
    assert calls["argv"] == [str(Path(sys.executable).resolve()), "-m", "funasr_server"]
    assert Path(str(result["stdout_log"])).is_file()
    assert Path(str(result["stderr_log"])).is_file()


def test_funasr_launcher_recognizes_an_external_service_without_spawning(
    tmp_path: Path,
    monkeypatch,
) -> None:
    launcher = FunAsrLauncher(root_dir=tmp_path)
    launcher.save_config(_config(tmp_path))
    monkeypatch.setattr(
        FunAsrLauncher,
        "_health_ready",
        staticmethod(lambda _url, *, timeout: True),
    )
    monkeypatch.setattr(
        "transvortex.app.funasr_launcher.subprocess.Popen",
        lambda *_args, **_kwargs: pytest.fail("external service must not spawn another process"),
    )

    status = launcher.start()

    assert status["state"] == "external"
    assert status["healthy"] is True
    assert status["owned"] is False
    assert status["can_stop"] is False


def test_funasr_launcher_stops_owned_process_after_health_timeout(
    tmp_path: Path,
    monkeypatch,
) -> None:
    launcher = FunAsrLauncher(root_dir=tmp_path)
    launcher.save_config(_config(tmp_path))

    class Process:
        pid = 1234

        def poll(self):  # noqa: ANN201
            return None

    process = Process()
    terminated: list[object] = []
    monkeypatch.setattr(
        "transvortex.app.funasr_launcher.subprocess.Popen",
        lambda *_args, **_kwargs: process,
    )
    monkeypatch.setattr(
        FunAsrLauncher,
        "_health_ready",
        staticmethod(lambda _url, *, timeout: False),
    )
    monkeypatch.setattr(
        FunAsrLauncher,
        "_terminate_process",
        staticmethod(lambda candidate: terminated.append(candidate) or ""),
    )

    status = launcher.start(timeout_seconds=0.01)
    deadline = time.monotonic() + 1
    while status["state"] != "failed" and time.monotonic() < deadline:
        time.sleep(0.01)
        status = launcher.status(probe_health=False)

    assert status["state"] == "failed"
    assert status["owned"] is False
    assert "managed process was stopped" in status["last_error"]
    assert terminated == [process]


def test_funasr_launcher_surfaces_invalid_persisted_config(tmp_path: Path) -> None:
    (tmp_path / "funasr_launcher.json").write_text("{broken", encoding="utf-8")

    status = FunAsrLauncher(root_dir=tmp_path).status()

    assert status["configured"] is False
    assert status["state"] == "invalid"
    assert status["config_error"]


def test_desktop_api_exposes_funasr_launcher_without_touching_asr_provider_config(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    saved = service.dispatch("funasr.launcher.save", {"launcher": _config(tmp_path)})
    status = service.dispatch("funasr.launcher.status")

    assert saved["configured"] is True
    assert status["state"] == "stopped"
    assert not (tmp_path / "pipeline.yaml").exists()

    removed = service.dispatch("funasr.launcher.delete")
    assert removed["state"] == "unconfigured"
    assert not (tmp_path / "funasr_launcher.json").exists()


def test_agent_cli_can_save_and_inspect_verified_funasr_launcher(
    tmp_path: Path,
    monkeypatch,
    capsys,
) -> None:
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "funasr-launcher-save",
            "--json-payload",
            json.dumps(_config(tmp_path)),
            "--json",
        ],
    )
    cli_main()
    saved = json.loads(capsys.readouterr().out)

    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "funasr-launcher-status",
            "--json",
        ],
    )
    cli_main()
    status = json.loads(capsys.readouterr().out)

    assert saved["configured"] is True
    assert status["configured"] is True
    assert status["config"]["arguments"] == ["-m", "funasr_server"]
