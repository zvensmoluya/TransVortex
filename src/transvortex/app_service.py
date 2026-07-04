from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any

from .app.config import load_app_config
from .app.desktop_api import DesktopApi, DesktopApiError
from .artifacts.runtime import DEFAULT_CANCEL_GRACE_SECONDS, TaskRuntime
from .artifacts.task_store import TaskStore
from .protocol.errors import classify_exception
from .protocol.redaction import redact


JSONRPC_VERSION = "2.0"
PUMP_INTERVAL_SECONDS = 1.0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="transvortex.app_service")
    parser.add_argument("--root", default=".", help="Project root")
    parser.add_argument("--providers-file", default=None, help="Optional providers config file path")
    parser.add_argument("--no-pump", action="store_true", help="Disable the local service queue pump")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    providers_file = Path(args.providers_file).resolve() if args.providers_file else None
    pump = LocalServicePump(root_dir=root, providers_file=providers_file)
    service = DesktopApi(
        root_dir=root,
        providers_file=providers_file,
        pump_status=pump.status,
        shutdown_callback=pump.stop,
    )
    if not args.no_pump:
        pump.start()
    try:
        serve(service, root_dir=root)
    finally:
        pump.stop()
        pump.join(timeout=3.0)


def serve(service: DesktopApi, *, root_dir: Path) -> None:
    for raw in sys.stdin:
        line = raw.strip().lstrip("\ufeff")
        if not line:
            continue
        response = handle_line(service, line, root_dir=root_dir)
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
        if service.shutdown_requested:
            break


class LocalServicePump:
    def __init__(
        self,
        *,
        root_dir: Path,
        providers_file: Path | None = None,
        interval_seconds: float = PUMP_INTERVAL_SECONDS,
        cancel_grace_seconds: float = DEFAULT_CANCEL_GRACE_SECONDS,
        worker_launcher: Any | None = None,
    ) -> None:
        self.root_dir = root_dir
        self.providers_file = providers_file
        self.interval_seconds = interval_seconds
        self.cancel_grace_seconds = cancel_grace_seconds
        self.worker_launcher = worker_launcher
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._started_at = ""
        self._last_tick_at = ""
        self._last_error = ""
        self._launch_count = 0

    def start(self) -> None:
        if self._thread is not None:
            return
        self._started_at = _now_for_status()
        self._thread = threading.Thread(target=self._run, name="transvortex-local-service-pump", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def join(self, timeout: float | None = None) -> None:
        thread = self._thread
        if thread is not None:
            thread.join(timeout=timeout)

    def status(self) -> dict[str, Any]:
        thread = self._thread
        with self._lock:
            return {
                "enabled": True,
                "running": bool(thread and thread.is_alive() and not self._stop.is_set()),
                "started_at": self._started_at,
                "last_tick_at": self._last_tick_at,
                "last_error": self._last_error,
                "launch_count": self._launch_count,
            }

    def tick(self) -> None:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        runtime = TaskRuntime(config.pipeline.artifacts_dir)
        runtime.reconcile()
        runtime.force_cancel_expired(grace_seconds=self.cancel_grace_seconds)
        acquired = runtime.acquire_next(root_dir=self.root_dir, providers_file=self.providers_file, reconcile=False)
        if not acquired.get("acquired"):
            return
        launch = acquired.get("launch") if isinstance(acquired.get("launch"), dict) else {}
        task_id = str(launch.get("task_id") or "")
        try:
            worker_args = list(launch.get("args") or ["_worker", "--task-id", task_id])
            if self.providers_file is not None:
                worker_args.extend(["--providers-file", str(self.providers_file)])
            launcher = self.worker_launcher or _default_worker_launcher()
            worker = launcher(root=self.root_dir, task_dir=config.pipeline.artifacts_dir / task_id, worker_args=worker_args)
            TaskStore(config.pipeline.artifacts_dir).append_event(
                task_id,
                "worker_launch_requested",
                stage="QUEUED",
                message="Worker launch requested",
                details={"pid": worker.get("pid"), "stdout_log": worker.get("stdout_log"), "stderr_log": worker.get("stderr_log")},
            )
            with self._lock:
                self._launch_count += 1
        except Exception as exc:
            runtime.release_active(task_id, reason="worker_launch_failed")
            TaskStore(config.pipeline.artifacts_dir).append_event(
                task_id,
                "worker_launch_failed",
                stage="INTERRUPTED",
                message="Worker launch failed",
                level="error",
                details={"error_info": classify_exception(exc), "reason": str(exc)},
            )
            raise

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
                with self._lock:
                    self._last_tick_at = _now_for_status()
                    self._last_error = ""
            except Exception:
                print(traceback.format_exc(), file=sys.stderr, flush=True)
                with self._lock:
                    self._last_tick_at = _now_for_status()
                    self._last_error = "pump_tick_failed"
            self._stop.wait(self.interval_seconds)


def _default_worker_launcher() -> Any:
    from .cli.entry import _spawn_detached_worker

    return _spawn_detached_worker


def _now_for_status() -> str:
    from .utils import utc_now_iso

    return utc_now_iso()


def handle_line(service: DesktopApi, line: str, *, root_dir: Path) -> dict[str, Any]:
    request_id: Any = None
    try:
        request = json.loads(line)
        if not isinstance(request, dict):
            raise DesktopApiError("invalid_request", "request must be an object")
        request_id = request.get("id")
        method = request.get("method")
        if not isinstance(method, str) or not method:
            raise DesktopApiError("invalid_request", "method is required")
        params = request.get("params") or {}
        if not isinstance(params, dict):
            raise DesktopApiError("invalid_request", "params must be an object")
        result = service.dispatch(method, params)
        return {
            "jsonrpc": JSONRPC_VERSION,
            "id": request_id,
            "result": redact(result, root_dir=root_dir),
        }
    except json.JSONDecodeError as exc:
        return _error_response(None, "parse_error", f"Invalid JSON: {exc.msg}", root_dir=root_dir)
    except DesktopApiError as exc:
        return _error_response(request_id, exc.code, exc.message, details=exc.details, root_dir=root_dir)
    except Exception as exc:  # noqa: BLE001 - Local Service must report handler errors
        print(traceback.format_exc(), file=sys.stderr, flush=True)
        err = classify_exception(exc)
        return _error_response(
            request_id,
            str(err.get("code") or "internal_error"),
            str(err.get("message") or exc),
            details={"error_info": err},
            root_dir=root_dir,
        )


def _error_response(
    request_id: Any,
    code: str,
    message: str,
    *,
    details: dict[str, Any] | None = None,
    root_dir: Path,
) -> dict[str, Any]:
    return {
        "jsonrpc": JSONRPC_VERSION,
        "id": request_id,
        "error": redact(
            {
                "code": code,
                "message": message,
                "details": details or {},
            },
            root_dir=root_dir,
        ),
    }


if __name__ == "__main__":
    main()
