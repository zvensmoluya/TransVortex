from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import ProxyHandler, build_opener


FUNASR_LAUNCHER_SCHEMA_VERSION = 1
FUNASR_LAUNCHER_FILE_NAME = "funasr_launcher.json"
FUNASR_START_TIMEOUT_SECONDS = 90.0


class FunAsrLauncherError(RuntimeError):
    pass


def _launcher_path(root_dir: Path) -> Path:
    return root_dir / FUNASR_LAUNCHER_FILE_NAME


def _logs_dir(root_dir: Path) -> Path:
    return root_dir / "Logs" / "FunASR"


def _as_text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _is_loopback_http_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def normalize_funasr_launcher_config(raw: dict[str, Any]) -> dict[str, Any]:
    executable = _as_text(raw.get("executable"))
    arguments = raw.get("arguments", [])
    if not isinstance(arguments, list) or not all(isinstance(item, str) for item in arguments):
        raise FunAsrLauncherError("FunASR launcher arguments must be an array of strings")
    working_directory = _as_text(raw.get("working_directory"))
    health_url = _as_text(raw.get("health_url"))
    if not executable:
        raise FunAsrLauncherError("FunASR launcher executable is required")
    executable_path = Path(executable).expanduser()
    if not executable_path.is_absolute() or not executable_path.is_file():
        raise FunAsrLauncherError("FunASR launcher executable must be an existing absolute file path")
    if working_directory:
        working_path = Path(working_directory).expanduser()
        if not working_path.is_absolute() or not working_path.is_dir():
            raise FunAsrLauncherError("FunASR launcher working directory must be an existing absolute directory")
    if not health_url or not _is_loopback_http_url(health_url):
        raise FunAsrLauncherError("FunASR launcher health URL must use local http loopback")
    return {
        "schema_version": FUNASR_LAUNCHER_SCHEMA_VERSION,
        "executable": str(executable_path.resolve()),
        "arguments": [item.strip() for item in arguments],
        "working_directory": str(Path(working_directory).expanduser().resolve()) if working_directory else "",
        "health_url": health_url,
        "stop_on_service_exit": raw.get("stop_on_service_exit") is not False,
    }


class FunAsrLauncher:
    """Owns only a user/Agent-configured FunASR server process.

    It deliberately has no installation, model download, environment discovery, or
    command-string execution behaviour.  The executable and argv are persisted as
    a previously verified launch recipe.
    """

    def __init__(self, *, root_dir: Path) -> None:
        self.root_dir = root_dir
        self._process: subprocess.Popen[bytes] | None = None
        self._stdout_log = ""
        self._stderr_log = ""
        self._last_error = ""
        self._started_at = ""
        self._lock = threading.RLock()

    def config(self) -> dict[str, Any] | None:
        path = _launcher_path(self.root_dir)
        if not path.is_file():
            return None
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            return normalize_funasr_launcher_config(raw) if isinstance(raw, dict) else None
        except (OSError, json.JSONDecodeError, FunAsrLauncherError):
            return None

    def save_config(self, raw: dict[str, Any]) -> dict[str, Any]:
        config = normalize_funasr_launcher_config(raw)
        _atomic_write_json(_launcher_path(self.root_dir), config)
        return self.status()

    def status(self) -> dict[str, Any]:
        config = self.config()
        with self._lock:
            process = self._process
            returncode = process.poll() if process is not None else None
            if process is not None and returncode is not None:
                self._last_error = f"FunASR process exited with code {returncode}"
                self._process = None
                process = None
            return {
                "configured": config is not None,
                "config": config or {},
                "state": "running" if process is not None else "stopped",
                "pid": process.pid if process is not None else None,
                "started_at": self._started_at,
                "stdout_log": self._stdout_log,
                "stderr_log": self._stderr_log,
                "last_error": self._last_error,
            }

    def start(self, *, timeout_seconds: float = FUNASR_START_TIMEOUT_SECONDS) -> dict[str, Any]:
        config = self.config()
        if config is None:
            raise FunAsrLauncherError("FunASR launcher is not configured")
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                return self.status()
            log_dir = _logs_dir(self.root_dir)
            log_dir.mkdir(parents=True, exist_ok=True)
            stdout_path = log_dir / "stdout.log"
            stderr_path = log_dir / "stderr.log"
            stdout = stdout_path.open("ab")
            stderr = stderr_path.open("ab")
            try:
                self._process = subprocess.Popen(
                    [config["executable"], *config["arguments"]],
                    cwd=config["working_directory"] or None,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout,
                    stderr=stderr,
                    close_fds=False,
                    creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
                    | getattr(subprocess, "CREATE_NO_WINDOW", 0),
                    env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"},
                )
            except OSError as exc:
                self._last_error = f"Could not start configured FunASR executable: {exc}"
                raise FunAsrLauncherError(self._last_error) from exc
            finally:
                stdout.close()
                stderr.close()
            self._stdout_log = str(stdout_path)
            self._stderr_log = str(stderr_path)
            self._started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self._last_error = ""

        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            status = self.status()
            if status["state"] != "running":
                raise FunAsrLauncherError(status["last_error"] or "FunASR process stopped before it became ready")
            if self._health_ready(config["health_url"]):
                status["ready"] = True
                return status
            time.sleep(0.5)
        self._last_error = f"FunASR did not become healthy within {int(timeout_seconds)} seconds"
        raise FunAsrLauncherError(self._last_error)

    def stop(self) -> dict[str, Any]:
        with self._lock:
            process = self._process
            self._process = None
        if process is not None and process.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True, check=False)
            else:
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
        return self.status()

    def close(self) -> None:
        config = self.config()
        if config is not None and config["stop_on_service_exit"]:
            self.stop()

    @staticmethod
    def _health_ready(url: str) -> bool:
        try:
            opener = build_opener(ProxyHandler({}))
            with opener.open(url, timeout=2.0) as response:
                return 200 <= response.status < 300
        except OSError:
            return False
