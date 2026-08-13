from __future__ import annotations

import sys
from pathlib import Path

import pytest

from transvortex.app.funasr_launcher import FunAsrLauncher, FunAsrLauncherError
from transvortex.app.desktop_api import DesktopApi


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


def test_funasr_launcher_starts_argv_and_waits_for_health(tmp_path: Path, monkeypatch) -> None:
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
    monkeypatch.setattr(FunAsrLauncher, "_health_ready", staticmethod(lambda _url: True))

    result = launcher.start(timeout_seconds=1)

    assert result["ready"] is True
    assert result["pid"] == 1234
    assert calls["argv"] == [str(Path(sys.executable).resolve()), "-m", "funasr_server"]
    assert Path(str(result["stdout_log"])).is_file()
    assert Path(str(result["stderr_log"])).is_file()


def test_desktop_api_exposes_funasr_launcher_without_touching_asr_provider_config(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    saved = service.dispatch("funasr.launcher.save", {"launcher": _config(tmp_path)})
    status = service.dispatch("funasr.launcher.status")

    assert saved["configured"] is True
    assert status["state"] == "stopped"
    assert not (tmp_path / "pipeline.yaml").exists()
