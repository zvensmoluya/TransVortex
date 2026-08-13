from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import ProxyHandler, build_opener


FUNASR_LAUNCHER_SCHEMA_VERSION = 1
FUNASR_LAUNCHER_FILE_NAME = "funasr_launcher.json"
FUNASR_START_TIMEOUT_SECONDS = 90.0
FUNASR_HEALTH_POLL_SECONDS = 0.5
FUNASR_STATUS_HEALTH_TIMEOUT_SECONDS = 0.35


class FunAsrLauncherError(RuntimeError):
    pass


def _launcher_path(root_dir: Path) -> Path:
    return root_dir / FUNASR_LAUNCHER_FILE_NAME


def _logs_dir(root_dir: Path) -> Path:
    return root_dir / "Logs" / "FunASR"


def _as_text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _validate_loopback_health_url(value: str) -> None:
    try:
        parsed = urlparse(value)
        host = (parsed.hostname or "").casefold()
        _ = parsed.port
    except ValueError as exc:
        raise FunAsrLauncherError("FunASR launcher health URL is invalid") from exc
    if (
        parsed.scheme.casefold() != "http"
        or host not in {"127.0.0.1", "localhost", "::1"}
        or parsed.username is not None
        or parsed.password is not None
        or bool(parsed.fragment)
    ):
        raise FunAsrLauncherError("FunASR launcher health URL must use local http loopback")


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def normalize_funasr_launcher_config(raw: dict[str, Any]) -> dict[str, Any]:
    executable = _as_text(raw.get("executable"))
    arguments = raw.get("arguments", [])
    if not isinstance(arguments, list) or not all(isinstance(item, str) for item in arguments):
        raise FunAsrLauncherError("FunASR launcher arguments must be an array of strings")
    if len(arguments) > 256:
        raise FunAsrLauncherError("FunASR launcher accepts at most 256 arguments")
    normalized_arguments: list[str] = []
    for item in arguments:
        argument = item.strip()
        if not argument:
            continue
        if len(argument) > 32_768 or any(character in argument for character in ("\0", "\r", "\n")):
            raise FunAsrLauncherError("FunASR launcher arguments must be single-line text")
        normalized_arguments.append(argument)

    working_directory = _as_text(raw.get("working_directory"))
    health_url = _as_text(raw.get("health_url"))
    if not executable:
        raise FunAsrLauncherError("FunASR launcher executable is required")
    try:
        executable_path = Path(executable).expanduser()
        if not executable_path.is_absolute() or not executable_path.is_file():
            raise FunAsrLauncherError(
                "FunASR launcher executable must be an existing absolute file path"
            )
        resolved_executable = executable_path.resolve()
    except OSError as exc:
        raise FunAsrLauncherError("FunASR launcher executable cannot be resolved") from exc
    resolved_working_directory = ""
    if working_directory:
        try:
            working_path = Path(working_directory).expanduser()
            if not working_path.is_absolute() or not working_path.is_dir():
                raise FunAsrLauncherError(
                    "FunASR launcher working directory must be an existing absolute directory"
                )
            resolved_working_directory = str(working_path.resolve())
        except OSError as exc:
            raise FunAsrLauncherError(
                "FunASR launcher working directory cannot be resolved"
            ) from exc
    if not health_url:
        raise FunAsrLauncherError("FunASR launcher health URL is required")
    _validate_loopback_health_url(health_url)
    return {
        "schema_version": FUNASR_LAUNCHER_SCHEMA_VERSION,
        "executable": str(resolved_executable),
        "arguments": normalized_arguments,
        "working_directory": resolved_working_directory,
        "health_url": health_url,
        "stop_on_service_exit": raw.get("stop_on_service_exit") is not False,
    }


class FunAsrLauncher:
    """Own only a user- or Agent-configured FunASR server process.

    This deliberately has no installation, environment discovery, model download,
    or command-string execution behavior. The saved executable and argv are a
    previously verified launch recipe.
    """

    def __init__(self, *, root_dir: Path) -> None:
        self.root_dir = root_dir
        self._process: subprocess.Popen[Any] | None = None
        self._state = "stopped"
        self._healthy = False
        self._stdout_log = ""
        self._stderr_log = ""
        self._last_error = ""
        self._started_at = ""
        self._ready_at = ""
        self._exit_code: int | None = None
        self._generation = 0
        self._monitor: threading.Thread | None = None
        self._lock = threading.RLock()
        self._restore_latest_log_paths()

    def _read_config(self) -> tuple[dict[str, Any] | None, str]:
        path = _launcher_path(self.root_dir)
        if not path.is_file():
            return None, ""
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise FunAsrLauncherError("FunASR launcher config must be an object")
            return normalize_funasr_launcher_config(raw), ""
        except (OSError, json.JSONDecodeError, FunAsrLauncherError) as exc:
            return None, str(exc)

    def config(self) -> dict[str, Any] | None:
        return self._read_config()[0]

    def save_config(self, raw: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            if self._owned_process_alive_locked():
                raise FunAsrLauncherError("Stop the managed FunASR process before changing its launcher")
        config = normalize_funasr_launcher_config(raw)
        _atomic_write_json(_launcher_path(self.root_dir), config)
        with self._lock:
            self._last_error = ""
            self._exit_code = None
            if self._state in {"failed", "unconfigured"}:
                self._state = "stopped"
        return self.status()

    def delete_config(self) -> dict[str, Any]:
        with self._lock:
            if self._owned_process_alive_locked():
                raise FunAsrLauncherError("Stop the managed FunASR process before removing its launcher")
        try:
            _launcher_path(self.root_dir).unlink(missing_ok=True)
        except OSError as exc:
            raise FunAsrLauncherError("Could not remove the FunASR launcher config") from exc
        with self._lock:
            self._state = "unconfigured"
            self._healthy = False
            self._last_error = ""
            self._exit_code = None
        return self.status(probe_health=False)

    def status(self, *, probe_health: bool = True) -> dict[str, Any]:
        config, config_error = self._read_config()
        health_url = str(config.get("health_url") or "") if config is not None else ""
        healthy = (
            self._health_ready(health_url, timeout=FUNASR_STATUS_HEALTH_TIMEOUT_SECONDS)
            if probe_health and health_url
            else None
        )
        with self._lock:
            self._reconcile_process_locked()
            if healthy is not None:
                self._healthy = healthy
                if self._owned_process_alive_locked():
                    if self._state == "stopping":
                        pass
                    elif healthy:
                        if self._state != "ready":
                            self._ready_at = _utc_now()
                        self._state = "ready"
                    elif self._state == "ready":
                        self._state = "unhealthy"
                elif healthy:
                    self._state = "external"
                elif self._state == "external":
                    self._state = "stopped"
            if config is None and not config_error and not self._owned_process_alive_locked():
                self._state = "unconfigured"
            elif config is None and config_error and not self._owned_process_alive_locked():
                self._state = "invalid"
            return self._status_locked(config=config, config_error=config_error)

    def start(self, *, timeout_seconds: float = FUNASR_START_TIMEOUT_SECONDS) -> dict[str, Any]:
        config, config_error = self._read_config()
        if config is None:
            raise FunAsrLauncherError(config_error or "FunASR launcher is not configured")
        current = self.status()
        if current["state"] in {"starting", "ready", "unhealthy", "external"}:
            return current

        with self._lock:
            if self._owned_process_alive_locked():
                return self._status_locked(config=config, config_error="")
            self._generation += 1
            generation = self._generation
            log_dir = _logs_dir(self.root_dir)
            log_dir.mkdir(parents=True, exist_ok=True)
            launch_id = f"{time.strftime('%Y%m%d-%H%M%S')}-{time.time_ns() % 1_000_000:06d}"
            stdout_path = log_dir / f"{launch_id}-stdout.log"
            stderr_path = log_dir / f"{launch_id}-stderr.log"
            stdout = stdout_path.open("ab")
            stderr = stderr_path.open("ab")
            try:
                process = subprocess.Popen(
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
                self._state = "failed"
                self._last_error = f"Could not start configured FunASR executable: {exc}"
                raise FunAsrLauncherError(self._last_error) from exc
            finally:
                stdout.close()
                stderr.close()
            self._process = process
            self._state = "starting"
            self._healthy = False
            self._stdout_log = str(stdout_path)
            self._stderr_log = str(stderr_path)
            self._started_at = _utc_now()
            self._ready_at = ""
            self._exit_code = None
            self._last_error = ""
            monitor = threading.Thread(
                target=self._monitor_start,
                args=(generation, process, config["health_url"], timeout_seconds),
                name="transvortex-funasr-launcher",
                daemon=True,
            )
            self._monitor = monitor
            monitor.start()
            return self._status_locked(config=config, config_error="")

    def stop(self) -> dict[str, Any]:
        with self._lock:
            self._generation += 1
            process = self._process
            self._process = None
            self._state = "stopping" if process is not None and process.poll() is None else "stopped"
        termination_error = self._terminate_process(process) if process is not None else ""
        with self._lock:
            self._state = "stopped"
            self._healthy = False
            self._last_error = termination_error
            if process is not None:
                self._exit_code = process.poll()
        return self.status()

    def close(self) -> None:
        config, _config_error = self._read_config()
        if config is None or config.get("stop_on_service_exit") is not False:
            self.stop()

    def _monitor_start(
        self,
        generation: int,
        process: subprocess.Popen[Any],
        health_url: str,
        timeout_seconds: float,
    ) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            with self._lock:
                if generation != self._generation or process is not self._process:
                    return
                returncode = process.poll()
                if returncode is not None:
                    self._process = None
                    self._state = "failed"
                    self._healthy = False
                    self._exit_code = returncode
                    self._last_error = f"FunASR process exited with code {returncode} before it became ready"
                    return
            if self._health_ready(health_url, timeout=2.0):
                with self._lock:
                    if generation != self._generation or process is not self._process:
                        return
                    self._state = "ready"
                    self._healthy = True
                    self._ready_at = _utc_now()
                    self._last_error = ""
                return
            time.sleep(FUNASR_HEALTH_POLL_SECONDS)

        with self._lock:
            if generation != self._generation or process is not self._process:
                return
            self._state = "stopping"
            self._healthy = False
            self._last_error = (
                f"FunASR did not become healthy within {int(timeout_seconds)} seconds; "
                "the managed process was stopped"
            )
        termination_error = self._terminate_process(process)
        with self._lock:
            if generation != self._generation or process is not self._process:
                return
            self._process = None
            self._state = "failed"
            self._exit_code = process.poll()
            if termination_error:
                self._last_error = f"{self._last_error}. {termination_error}"

    def _reconcile_process_locked(self) -> None:
        process = self._process
        if process is None:
            return
        returncode = process.poll()
        if returncode is None:
            return
        self._process = None
        self._healthy = False
        self._exit_code = returncode
        if self._state not in {"stopped", "stopping"}:
            self._state = "failed"
            self._last_error = f"FunASR process exited with code {returncode}"

    def _owned_process_alive_locked(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def _status_locked(
        self,
        *,
        config: dict[str, Any] | None,
        config_error: str,
    ) -> dict[str, Any]:
        process = self._process if self._owned_process_alive_locked() else None
        state = self._state
        owned = process is not None
        return {
            "configured": config is not None,
            "config_error": config_error,
            "config": config or {},
            "state": state,
            "healthy": self._healthy,
            "owned": owned,
            "can_start": config is not None and state in {"stopped", "failed"},
            "can_stop": owned,
            "pid": process.pid if process is not None else None,
            "started_at": self._started_at,
            "ready_at": self._ready_at,
            "exit_code": self._exit_code,
            "stdout_log": self._stdout_log,
            "stderr_log": self._stderr_log,
            "last_error": self._last_error,
        }

    def _restore_latest_log_paths(self) -> None:
        log_dir = _logs_dir(self.root_dir)
        if not log_dir.is_dir():
            return
        try:
            stdout_logs = sorted(
                log_dir.glob("*-stdout.log"),
                key=lambda path: path.stat().st_mtime_ns,
            )
            stderr_logs = sorted(
                log_dir.glob("*-stderr.log"),
                key=lambda path: path.stat().st_mtime_ns,
            )
        except OSError:
            return
        legacy_stdout = log_dir / "stdout.log"
        legacy_stderr = log_dir / "stderr.log"
        if stdout_logs:
            self._stdout_log = str(stdout_logs[-1])
        elif legacy_stdout.is_file():
            self._stdout_log = str(legacy_stdout)
        if stderr_logs:
            self._stderr_log = str(stderr_logs[-1])
        elif legacy_stderr.is_file():
            self._stderr_log = str(legacy_stderr)

    @staticmethod
    def _terminate_process(process: subprocess.Popen[Any] | None) -> str:
        if process is None or process.poll() is not None:
            return ""
        try:
            if os.name == "nt":
                completed = subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                    check=False,
                    timeout=10.0,
                )
                if completed.returncode != 0 and process.poll() is None:
                    return f"Could not stop the FunASR process tree (taskkill exit {completed.returncode})"
            else:
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5.0)
        except (OSError, subprocess.SubprocessError) as exc:
            return f"Could not stop the FunASR process: {exc}"
        return ""

    @staticmethod
    def _health_ready(url: str, *, timeout: float) -> bool:
        try:
            opener = build_opener(ProxyHandler({}))
            with opener.open(url, timeout=timeout) as response:
                return 200 <= response.status < 300
        except (OSError, ValueError):
            return False


def _utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
