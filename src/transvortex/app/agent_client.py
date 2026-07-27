from __future__ import annotations

import ctypes
import os
import re
import shutil
import subprocess
import tempfile
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from ..utils import read_json, utc_now_iso, write_json


AGENT_CLIENT_SCHEMA_VERSION = 1
AGENT_HANDOFF_SCHEMA_VERSION = 1
AGENT_HANDOFF_DIRECTORY_NAME = "AgentHandoffs"
AGENT_HANDOFF_DOCUMENT_NAME = "handoff.md"
AGENT_HANDOFF_STATE_NAME = "handoff.json"
AGENT_HANDOFF_RETENTION_DAYS = 7
CODEX_CLIENT_ID = "codex_cli"
CODEX_INITIAL_PROMPT = "请读取当前工作区的 handoff.md，并按其中限定的任务范围完成工作。"
SUPPORTED_ASR_HANDOFF_SCOPES = {
    "inspect",
    "prepare_model",
    "prepare_accelerator",
    "register",
    "full",
}


class AgentClientError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def codex_client_status(*, executable: Path | None = None) -> dict[str, Any]:
    resolved = _resolve_codex_executable(executable)
    if resolved is None:
        return _client_payload(
            detected=False,
            ready=False,
            launch_supported=os.name == "nt",
            executable=None,
            status_code="codex_cli_not_found",
            message="Codex CLI was not found on PATH",
        )

    launch_supported = os.name == "nt"
    try:
        command, environment = _codex_invocation(resolved, ["--version"])
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
            check=False,
            creationflags=_no_window_creation_flags(),
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return _client_payload(
            detected=True,
            ready=False,
            launch_supported=launch_supported,
            executable=resolved,
            status_code="codex_cli_probe_failed",
            message=f"Codex CLI could not be queried: {type(exc).__name__}",
        )

    version_label = _first_output_line(completed.stdout, completed.stderr)
    version = _codex_version(version_label)
    if completed.returncode != 0:
        return _client_payload(
            detected=True,
            ready=False,
            launch_supported=launch_supported,
            executable=resolved,
            version=version,
            version_label=version_label,
            status_code="codex_cli_probe_failed",
            message="Codex CLI returned an error while reporting its version",
        )
    if not launch_supported:
        return _client_payload(
            detected=True,
            ready=False,
            launch_supported=False,
            executable=resolved,
            version=version,
            version_label=version_label,
            status_code="codex_cli_terminal_unsupported",
            message="Launching a visible Codex terminal is not supported on this platform",
        )
    return _client_payload(
        detected=True,
        ready=True,
        launch_supported=True,
        executable=resolved,
        version=version,
        version_label=version_label,
        status_code="ready",
        message="Codex CLI is ready",
    )


def launch_codex_client(
    *,
    cache_root: Path,
    executable: Path | None = None,
) -> dict[str, Any]:
    client = codex_client_status(executable=executable)
    resolved = _require_ready_client(client)
    handoff_root = _handoff_root(cache_root)
    handoff_root.mkdir(parents=True, exist_ok=True)
    _cleanup_expired_handoffs(handoff_root)
    session_id = _new_session_id("client")
    workspace = handoff_root / session_id
    workspace.mkdir(parents=False, exist_ok=False)
    state_path = workspace / AGENT_HANDOFF_STATE_NAME
    created_at = utc_now_iso()
    state: dict[str, Any] = {
        "schema_version": AGENT_HANDOFF_SCHEMA_VERSION,
        "product": "TransVortex",
        "handoff_id": session_id,
        "workflow": "client_open",
        "scope": None,
        "status": "prepared",
        "created_at": created_at,
        "updated_at": created_at,
        "files": {},
        "client": {
            "id": CODEX_CLIENT_ID,
            "executable": client["executable"],
            "version": client["version"],
        },
    }
    write_json(state_path, state)
    try:
        process = _start_codex_process(resolved, ["-C", str(workspace)], cwd=workspace)
    except OSError as exc:
        state.update(
            {
                "status": "launch_failed",
                "updated_at": utc_now_iso(),
                "error_code": "codex_cli_launch_failed",
            }
        )
        write_json(state_path, state)
        raise AgentClientError(
            "codex_cli_launch_failed",
            f"Codex CLI could not be launched: {type(exc).__name__}",
        ) from exc
    state.update(
        {
            "status": "launched",
            "updated_at": utc_now_iso(),
            "pid": process.pid,
        }
    )
    write_json(state_path, state)
    _watch_process(process, state_path=state_path)
    return {
        "ok": True,
        "launched": True,
        "pid": process.pid,
        "handoff_id": session_id,
        "workflow": "client_open",
        "workspace": str(workspace),
        "client": client,
    }


def launch_asr_agent_handoff(
    *,
    cache_root: Path,
    scope: str,
    handoff_text: str,
    executable: Path | None = None,
) -> dict[str, Any]:
    normalized_scope = scope.strip()
    if normalized_scope not in SUPPORTED_ASR_HANDOFF_SCOPES:
        raise AgentClientError("agent_handoff_scope_invalid", "The requested ASR handoff scope is invalid")
    instructions = handoff_text.strip()
    if not instructions:
        raise AgentClientError("agent_handoff_empty", "The ASR handoff instructions are empty")

    client = codex_client_status(executable=executable)
    resolved = _require_ready_client(client)
    handoff_root = _handoff_root(cache_root)
    handoff_root.mkdir(parents=True, exist_ok=True)
    _cleanup_expired_handoffs(handoff_root)

    handoff_id = _new_session_id("handoff")
    workspace = handoff_root / handoff_id
    workspace.mkdir(parents=False, exist_ok=False)
    document_path = workspace / AGENT_HANDOFF_DOCUMENT_NAME
    state_path = workspace / AGENT_HANDOFF_STATE_NAME
    _atomic_write_text(document_path, f"# TransVortex Agent Handoff\n\n{instructions}\n")

    created_at = utc_now_iso()
    state: dict[str, Any] = {
        "schema_version": AGENT_HANDOFF_SCHEMA_VERSION,
        "product": "TransVortex",
        "handoff_id": handoff_id,
        "workflow": "asr_environment",
        "scope": normalized_scope,
        "status": "prepared",
        "created_at": created_at,
        "updated_at": created_at,
        "files": {"instructions": AGENT_HANDOFF_DOCUMENT_NAME},
        "client": {
            "id": CODEX_CLIENT_ID,
            "executable": client["executable"],
            "version": client["version"],
        },
    }
    write_json(state_path, state)

    try:
        process = _start_codex_process(
            resolved,
            ["-C", str(workspace), CODEX_INITIAL_PROMPT],
            cwd=workspace,
        )
    except OSError as exc:
        state.update(
            {
                "status": "launch_failed",
                "updated_at": utc_now_iso(),
                "error_code": "codex_cli_launch_failed",
            }
        )
        write_json(state_path, state)
        raise AgentClientError(
            "codex_cli_launch_failed",
            f"Codex CLI could not be launched: {type(exc).__name__}",
        ) from exc

    state.update(
        {
            "status": "launched",
            "updated_at": utc_now_iso(),
            "pid": process.pid,
        }
    )
    write_json(state_path, state)
    _watch_process(process, state_path=state_path)
    return {
        "ok": True,
        "launched": True,
        "handoff_id": handoff_id,
        "workflow": "asr_environment",
        "scope": normalized_scope,
        "workspace": str(workspace),
        "handoff_document": str(document_path),
        "pid": process.pid,
        "client": client,
    }


def has_active_agent_handoffs(cache_root: Path) -> bool:
    root = _handoff_root(cache_root)
    if not root.is_dir():
        return False
    for child in root.iterdir():
        if child.is_symlink() or not child.is_dir():
            continue
        state = _owned_handoff_state(child)
        if state is None or state.get("status") != "launched":
            continue
        pid = state.get("pid")
        if isinstance(pid, int) and _process_is_running(pid):
            return True
    return False


def _client_payload(
    *,
    detected: bool,
    ready: bool,
    launch_supported: bool,
    executable: Path | None,
    status_code: str,
    message: str,
    version: str = "",
    version_label: str = "",
) -> dict[str, Any]:
    return {
        "schema_version": AGENT_CLIENT_SCHEMA_VERSION,
        "id": CODEX_CLIENT_ID,
        "name": "Codex CLI",
        "default": True,
        "detected": detected,
        "ready": ready,
        "launch_supported": launch_supported,
        "executable": str(executable) if executable is not None else None,
        "version": version,
        "version_label": version_label,
        "status_code": status_code,
        "message": message,
    }


def _resolve_codex_executable(executable: Path | None) -> Path | None:
    explicit = str(executable).strip() if executable is not None else ""
    if explicit:
        candidate = Path(explicit).expanduser()
        if candidate.is_file():
            return candidate.resolve()
        discovered = shutil.which(explicit)
        return Path(discovered).resolve() if discovered else None
    discovered = shutil.which("codex")
    if discovered:
        return Path(discovered).resolve()
    if os.name == "nt":
        for name in ("codex.cmd", "codex.exe"):
            discovered = shutil.which(name)
            if discovered:
                return Path(discovered).resolve()
    return None


def _require_ready_client(client: dict[str, Any]) -> Path:
    if client.get("ready") is not True:
        code = str(client.get("status_code") or "codex_cli_unavailable")
        message = str(client.get("message") or "Codex CLI is unavailable")
        raise AgentClientError(code, message)
    executable = str(client.get("executable") or "").strip()
    if not executable:
        raise AgentClientError("codex_cli_not_found", "Codex CLI was not found on PATH")
    return Path(executable)


def _codex_invocation(
    executable: Path,
    arguments: list[str],
) -> tuple[str | list[str], dict[str, str] | None]:
    suffix = executable.suffix.casefold()
    if os.name == "nt" and suffix in {".cmd", ".bat"}:
        environment = os.environ.copy()
        environment["TRANSVORTEX_CODEX_EXECUTABLE"] = str(executable)
        argument_names: list[str] = []
        for index, argument in enumerate(arguments):
            name = f"TRANSVORTEX_CODEX_ARG_{index}"
            environment[name] = argument
            argument_names.append(name)
        command_line = "call \"%TRANSVORTEX_CODEX_EXECUTABLE%\""
        if argument_names:
            command_line += " " + " ".join(f'\"%{name}%\"' for name in argument_names)
        comspec = subprocess.list2cmdline([os.environ.get("COMSPEC", "cmd.exe")])
        command = f'{comspec} /d /v:off /s /c "{command_line}"'
        return command, environment
    return [str(executable), *arguments], None


def _start_codex_process(executable: Path, arguments: list[str], *, cwd: Path) -> subprocess.Popen[Any]:
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_CONSOLE | subprocess.CREATE_NEW_PROCESS_GROUP
    command, environment = _codex_invocation(executable, arguments)
    return subprocess.Popen(
        command,
        cwd=str(cwd),
        creationflags=creationflags,
        env=environment,
    )


def _watch_process(process: subprocess.Popen[Any], *, state_path: Path | None = None) -> None:
    def wait_for_exit() -> None:
        exit_code = process.wait()
        if state_path is None:
            return
        try:
            state = read_json(state_path)
            if not isinstance(state, dict) or state.get("status") != "launched":
                return
            state.update(
                {
                    "status": "client_exited",
                    "updated_at": utc_now_iso(),
                    "exit_code": exit_code,
                }
            )
            write_json(state_path, state)
        except (OSError, ValueError):
            return

    threading.Thread(target=wait_for_exit, name="codex-handoff-monitor", daemon=True).start()


def _handoff_root(cache_root: Path) -> Path:
    cache = cache_root.expanduser().resolve()
    if cache == cache.parent:
        raise AgentClientError("agent_handoff_cache_invalid", "The Agent handoff cache cannot be a filesystem root")
    return cache / AGENT_HANDOFF_DIRECTORY_NAME


def _new_session_id(prefix: str) -> str:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{prefix}_{timestamp}_{uuid.uuid4().hex[:8]}"


def _cleanup_expired_handoffs(root: Path) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=AGENT_HANDOFF_RETENTION_DAYS)
    for child in root.iterdir():
        if child.is_symlink() or not child.is_dir():
            continue
        state = _owned_handoff_state(child)
        if state is None:
            continue
        if state.get("status") == "launched":
            pid = state.get("pid")
            if isinstance(pid, int) and _process_is_running(pid):
                continue
            state.update({"status": "client_exited", "updated_at": utc_now_iso()})
            write_json(child / AGENT_HANDOFF_STATE_NAME, state)
            continue
        updated_at = _parse_timestamp(state.get("updated_at") or state.get("created_at"))
        if updated_at is None or updated_at > cutoff:
            continue
        resolved = child.resolve()
        if resolved.parent != root.resolve():
            continue
        shutil.rmtree(resolved)


def _owned_handoff_state(directory: Path) -> dict[str, Any] | None:
    state_path = directory / AGENT_HANDOFF_STATE_NAME
    if not state_path.is_file():
        return None
    try:
        state = read_json(state_path)
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict):
        return None
    if state.get("schema_version") != AGENT_HANDOFF_SCHEMA_VERSION:
        return None
    if state.get("product") != "TransVortex" or state.get("handoff_id") != directory.name:
        return None
    return state


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _process_is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel32.GetExitCodeProcess.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    handle = kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_uint32()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        return exit_code.value == 259
    finally:
        kernel32.CloseHandle(handle)


def _first_output_line(*values: str) -> str:
    for value in values:
        for line in value.splitlines():
            cleaned = line.strip()
            if cleaned:
                return cleaned[:160]
    return ""


def _codex_version(label: str) -> str:
    match = re.search(r"\b\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9_.-]+)?\b", label)
    return match.group(0) if match else ""


def _no_window_creation_flags() -> int:
    if os.name != "nt":
        return 0
    return subprocess.CREATE_NO_WINDOW


def _atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
