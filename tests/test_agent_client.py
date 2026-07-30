from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest

import transvortex.app.agent_client as agent_client
from transvortex.app.agent_client import (
    CODEX_INITIAL_PROMPT,
    AgentClientError,
    codex_client_status,
    has_active_agent_handoffs,
    launch_asr_agent_handoff,
    launch_codex_client,
)


def _ready_client(executable: Path) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "id": "codex_cli",
        "name": "Codex CLI",
        "default": True,
        "detected": True,
        "ready": True,
        "launch_supported": True,
        "executable": str(executable),
        "version": "0.144.6",
        "version_label": "codex-cli 0.144.6",
        "status_code": "ready",
        "message": "Codex CLI is ready",
    }


class _FakeProcess:
    def __init__(self, *, pid: int = 4321, exit_code: int = 0) -> None:
        self.pid = pid
        self._exit_code = exit_code

    def wait(self) -> int:
        return self._exit_code


@pytest.mark.skipif(os.name != "nt", reason="Windows cmd shim behavior")
def test_codex_client_status_uses_the_user_path_client(tmp_path: Path, monkeypatch) -> None:
    executable = tmp_path / "codex.cmd"
    executable.write_text("@echo off\n", encoding="utf-8")
    captured: list[tuple[str | list[str], dict[str, Any]]] = []

    def run(argv: str | list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        captured.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, 0, stdout="codex-cli 0.144.6\n", stderr="")

    monkeypatch.setattr(agent_client.subprocess, "run", run)

    payload = codex_client_status(executable=executable)

    assert payload["ready"] is True
    assert payload["executable"] == str(executable.resolve())
    assert payload["version"] == "0.144.6"
    command, kwargs = captured[0]
    assert isinstance(command, str)
    assert "--version" not in command
    assert kwargs["env"]["TRANSVORTEX_CODEX_ARG_0"] == "--version"


def test_codex_client_status_reports_missing_client(monkeypatch) -> None:
    monkeypatch.setattr(agent_client.shutil, "which", lambda _name: None)

    payload = codex_client_status()

    assert payload["detected"] is False
    assert payload["ready"] is False
    assert payload["status_code"] == "codex_cli_not_found"


def test_windows_cmd_invocation_keeps_paths_out_of_the_command_string(monkeypatch) -> None:
    executable = Path(r"C:\Users\A&B\codex.cmd")
    workspace = r"D:\Agent work\One&Two%Ready"
    monkeypatch.setattr(agent_client.os, "name", "nt")

    command, environment = agent_client._codex_invocation(
        executable,
        ["-C", workspace, CODEX_INITIAL_PROMPT],
    )

    assert isinstance(command, str)
    assert command.endswith(
        '/c "call "%TRANSVORTEX_CODEX_EXECUTABLE%" '
        '"%TRANSVORTEX_CODEX_ARG_0%" '
        '"%TRANSVORTEX_CODEX_ARG_1%" '
        '"%TRANSVORTEX_CODEX_ARG_2%""'
    )
    assert "A&B" not in command
    assert "One&Two" not in command
    assert environment is not None
    assert environment["TRANSVORTEX_CODEX_EXECUTABLE"] == str(executable)
    assert environment["TRANSVORTEX_CODEX_ARG_1"] == workspace


@pytest.mark.skipif(os.name != "nt", reason="Windows cmd shim behavior")
def test_codex_probe_runs_a_cmd_shim_from_a_metacharacter_path(tmp_path: Path) -> None:
    executable = tmp_path / "A&B" / "codex.cmd"
    executable.parent.mkdir()
    executable.write_text("@echo off\r\necho codex-cli 9.8.7\r\n", encoding="ascii")

    payload = codex_client_status(executable=executable)

    assert payload["ready"] is True
    assert payload["version"] == "9.8.7"


@pytest.mark.skipif(os.name != "nt", reason="Windows cmd shim behavior")
def test_cmd_shim_receives_metacharacter_arguments_verbatim(tmp_path: Path) -> None:
    executable = tmp_path / "A&B" / "codex.cmd"
    executable.parent.mkdir()
    executable.write_text("@echo off\r\necho [%1][%2]\r\n", encoding="ascii")
    workspace = str(tmp_path / "Work&100%Ready")
    command, environment = agent_client._codex_invocation(executable, ["-C", workspace])

    completed = subprocess.run(
        command,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=5,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout.strip() == f'["-C"]["{workspace}"]'


def test_launch_asr_handoff_writes_isolated_workspace_and_argv(tmp_path: Path, monkeypatch) -> None:
    executable = tmp_path / "codex.cmd"
    executable.write_text("@echo off\n", encoding="utf-8")
    monkeypatch.setattr(agent_client, "codex_client_status", lambda **_kwargs: _ready_client(executable))
    monkeypatch.setattr(agent_client, "_watch_process", lambda *_args, **_kwargs: None)
    captured: dict[str, Any] = {}

    def start(executable_arg: Path, arguments: list[str], *, cwd: Path) -> _FakeProcess:
        captured.update(executable=executable_arg, arguments=arguments, cwd=cwd)
        return _FakeProcess()

    monkeypatch.setattr(agent_client, "_start_codex_process", start)

    result = launch_asr_agent_handoff(
        cache_root=tmp_path / "Cache",
        scope="prepare_model",
        handoff_text="prepare the model and verify it",
    )

    workspace = Path(result["workspace"])
    document = (workspace / "handoff.md").read_text(encoding="utf-8")
    state = json.loads((workspace / "handoff.json").read_text(encoding="utf-8"))
    assert workspace.parent == (tmp_path / "Cache" / "AgentHandoffs").resolve()
    assert document.endswith("prepare the model and verify it\n")
    assert state["scope"] == "prepare_model"
    assert state["status"] == "launched"
    assert state["pid"] == 4321
    assert captured == {
        "executable": executable,
        "arguments": ["-C", str(workspace), CODEX_INITIAL_PROMPT],
        "cwd": workspace,
    }


def test_open_codex_uses_a_unique_tracked_workspace(tmp_path: Path, monkeypatch) -> None:
    executable = tmp_path / "codex.cmd"
    executable.write_text("@echo off\n", encoding="utf-8")
    monkeypatch.setattr(agent_client, "codex_client_status", lambda **_kwargs: _ready_client(executable))
    monkeypatch.setattr(agent_client, "_watch_process", lambda *_args, **_kwargs: None)
    captured: dict[str, Any] = {}

    def start(executable_arg: Path, arguments: list[str], *, cwd: Path) -> _FakeProcess:
        captured.update(executable=executable_arg, arguments=arguments, cwd=cwd)
        return _FakeProcess(pid=9876)

    monkeypatch.setattr(agent_client, "_start_codex_process", start)

    result = launch_codex_client(cache_root=tmp_path / "Cache")

    workspace = Path(result["workspace"])
    state = json.loads((workspace / "handoff.json").read_text(encoding="utf-8"))
    assert workspace.name.startswith("client_")
    assert state["workflow"] == "client_open"
    assert state["status"] == "launched"
    assert state["pid"] == 9876
    assert captured["arguments"] == ["-C", str(workspace)]


def test_launch_asr_handoff_rejects_unknown_scope_before_writing(tmp_path: Path) -> None:
    with pytest.raises(AgentClientError) as exc_info:
        launch_asr_agent_handoff(
            cache_root=tmp_path / "Cache",
            scope="arbitrary_command",
            handoff_text="do anything",
        )

    assert exc_info.value.code == "agent_handoff_scope_invalid"
    assert not (tmp_path / "Cache" / "AgentHandoffs").exists()


def test_expired_cleanup_preserves_active_and_unowned_directories(tmp_path: Path, monkeypatch) -> None:
    cache_root = tmp_path / "Cache"
    root = cache_root / "AgentHandoffs"
    expired = root / "expired"
    active = root / "active"
    unowned = root / "notes"
    for directory in (expired, active, unowned):
        directory.mkdir(parents=True)
    old = (datetime.now(timezone.utc) - timedelta(days=8)).replace(microsecond=0).isoformat()
    (expired / "handoff.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "product": "TransVortex",
                "handoff_id": "expired",
                "status": "completed",
                "created_at": old,
                "updated_at": old,
            }
        ),
        encoding="utf-8",
    )
    (active / "handoff.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "product": "TransVortex",
                "handoff_id": "active",
                "status": "launched",
                "pid": 4321,
                "created_at": old,
                "updated_at": old,
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_client, "_process_is_running", lambda pid: pid == 4321)

    agent_client._cleanup_expired_handoffs(root)

    assert not expired.exists()
    assert active.exists()
    assert unowned.exists()
    assert has_active_agent_handoffs(cache_root) is True
