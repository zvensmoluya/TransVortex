from __future__ import annotations

import ctypes
import os
import signal
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..app.desktop_requests import (
    ResumeRequest,
    RunRequest,
    resume_request_from_payload,
    resume_request_to_payload,
    run_request_from_payload,
    run_request_to_payload,
)
from ..app.models import TaskRecord
from ..core.orchestrator import create_pipeline_task, queue_resume_task
from ..protocol.errors import classify_exception
from ..utils import read_json, utc_now_iso, write_json
from .task_store import TaskStore


TERMINAL_STATUSES = {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}
CLAIM_STALE_SECONDS = 60
RUNNING_STATUSES = {
    "INIT",
    "QUEUED",
    "PRECHECK",
    "INGEST",
    "ASR",
    "SEGMENT",
    "TRANSLATE",
    "ALIGN",
    "QUALITY",
    "EXPORT",
    "CANCEL_REQUESTED",
}


@dataclass(frozen=True)
class LaunchSpec:
    task_id: str
    command: str
    request: dict[str, Any]


class TaskRuntime:
    def __init__(self, artifacts_dir: Path) -> None:
        self.artifacts_dir = artifacts_dir
        self.store = TaskStore(artifacts_dir)
        self.runtime_dir = artifacts_dir / ".runtime"
        self.active_file = self.runtime_dir / "active.json"

    def request_file(self, task_id: str) -> Path:
        return self.store.task_dir(task_id) / "runtime_request.json"

    def worker_file(self, task_id: str) -> Path:
        return self.store.task_dir(task_id) / "worker.json"

    def submit_run(
        self,
        *,
        root_dir: Path,
        request: RunRequest,
        providers_file: Path | None = None,
    ) -> dict[str, Any]:
        task_id, artifacts_dir = create_pipeline_task(
            root_dir=root_dir,
            input_file=Path(request.input),
            source_lang=request.source_lang,
            target_lang=request.target_lang,
            bilingual=request.bilingual,
            providers_file=providers_file,
            cli_overrides=request.overrides,
            provider_name=request.provider or None,
            model=request.model or None,
            input_type=request.input_type,
            status="QUEUED",
        )
        self.save_runtime_request(task_id, "run", run_request_to_payload(request))
        task = self.store.load_task(task_id)
        return self._submit_payload(task, artifacts_dir)

    def submit_resume(
        self,
        *,
        root_dir: Path,
        request: ResumeRequest,
        providers_file: Path | None = None,
    ) -> dict[str, Any]:
        artifacts_dir = queue_resume_task(
            root_dir=root_dir,
            task_id=request.task_id,
            providers_file=providers_file,
            cli_overrides=request.overrides,
            provider_name=request.provider or None,
            model=request.model or None,
        )
        self.save_runtime_request(request.task_id, "resume", resume_request_to_payload(request))
        task = self.store.load_task(request.task_id)
        return self._submit_payload(task, artifacts_dir)

    def acquire_next(self, *, root_dir: Path, providers_file: Path | None = None) -> dict[str, Any]:
        self.reconcile()
        active = self._active_payload()
        if active is not None:
            return {"acquired": False, "reason": "active_worker", "active": active}
        for task in sorted(self.store.list_tasks(), key=lambda item: item.created_at):
            if task.status != "QUEUED":
                continue
            request_payload = self._read_runtime_request(task.task_id)
            if not request_payload:
                continue
            command = str(request_payload.get("command") or "run")
            active_payload = {
                "task_id": task.task_id,
                "state": "claimed",
                "claimed_at": utc_now_iso(),
                "root_dir": str(root_dir),
                "providers_file": str(providers_file) if providers_file else "",
                "command": command,
            }
            write_json(self.active_file, active_payload)
            return {
                "acquired": True,
                "launch": {
                    "task_id": task.task_id,
                    "command": command,
                    "request_file": str(self.request_file(task.task_id)),
                    "args": ["_worker", "--task-id", task.task_id],
                },
            }
        return {"acquired": False, "reason": "no_queued_task"}

    def register_worker(
        self,
        *,
        task_id: str,
        pid: int | None = None,
        owner: str = "python",
        command: str = "worker",
    ) -> dict[str, Any]:
        now = utc_now_iso()
        payload = {
            "task_id": task_id,
            "pid": int(pid or os.getpid()),
            "owner": owner,
            "command": command,
            "state": "running",
            "started_at": now,
            "last_seen": now,
            "ended_at": "",
            "exit_code": None,
        }
        write_json(self.worker_file(task_id), payload)
        active = self._active_payload() or {}
        active.update(
            {
                "task_id": task_id,
                "pid": payload["pid"],
                "owner": owner,
                "state": "running",
                "started_at": now,
                "last_seen": now,
                "command": command,
            }
        )
        write_json(self.active_file, active)
        self.store.append_event(
            task_id,
            "worker_started",
            stage=self.store.load_task(task_id).status,
            message="Worker started",
            details={"pid": payload["pid"], "owner": owner},
        )
        return payload

    def is_tracked(self, task_id: str) -> bool:
        active = self._active_payload()
        active_matches = bool(
            active
            and active.get("task_id") == task_id
            and (active.get("pid") or active.get("state") == "running")
        )
        return active_matches or self.worker_file(task_id).exists()

    def heartbeat(self, task_id: str, *, pid: int | None = None) -> None:
        now = utc_now_iso()
        worker = self._read_worker(task_id) or {"task_id": task_id, "pid": int(pid or os.getpid())}
        worker["last_seen"] = now
        worker.setdefault("state", "running")
        write_json(self.worker_file(task_id), worker)
        active = self._active_payload()
        if active and active.get("task_id") == task_id:
            active["last_seen"] = now
            active["pid"] = int(worker.get("pid") or pid or os.getpid())
            active["state"] = "running"
            write_json(self.active_file, active)

    def finish_worker(self, task_id: str, *, exit_code: int = 0, state: str = "ended") -> None:
        now = utc_now_iso()
        active = self._active_payload()
        worker = self._read_worker(task_id) or {
            "task_id": task_id,
            "pid": _int_or_none(active.get("pid")) if active and active.get("task_id") == task_id else None,
        }
        worker["state"] = state
        worker["ended_at"] = now
        worker["last_seen"] = now
        worker["exit_code"] = exit_code
        write_json(self.worker_file(task_id), worker)
        if active and active.get("task_id") == task_id:
            self.active_file.unlink(missing_ok=True)

    def reconcile(self) -> dict[str, Any]:
        active = self._active_payload()
        interrupted: list[str] = []
        if active:
            task_id = str(active.get("task_id") or "")
            pid = _int_or_none(active.get("pid"))
            state = str(active.get("state") or "")
            try:
                task = self.store.load_task(task_id)
            except Exception:
                self.active_file.unlink(missing_ok=True)
            else:
                if task.status in TERMINAL_STATUSES:
                    self.finish_worker(task_id, exit_code=0, state="ended")
                elif pid and is_pid_alive(pid):
                    self.heartbeat(task_id, pid=pid)
                elif state == "claimed":
                    if _is_claim_stale(active.get("claimed_at")):
                        self._mark_interrupted(task, reason="worker_launch_abandoned")
                        interrupted.append(task_id)
                        self.active_file.unlink(missing_ok=True)
                else:
                    self._mark_interrupted(task, reason="worker_process_missing")
                    interrupted.append(task_id)
                    self.active_file.unlink(missing_ok=True)

        stale: list[str] = []
        for task in self.store.list_tasks():
            if task.status in RUNNING_STATUSES and task.status != "QUEUED":
                worker = self._read_worker(task.task_id)
                if not worker:
                    continue
                pid = _int_or_none((worker or {}).get("pid"))
                if pid and is_pid_alive(pid):
                    continue
                if self._active_payload() and self._active_payload().get("task_id") == task.task_id:
                    continue
                self._mark_interrupted(task, reason="no_active_worker")
                stale.append(task.task_id)
        return {"ok": True, "interrupted": interrupted, "stale": stale}

    def snapshot(self) -> dict[str, Any]:
        self.reconcile()
        tasks = self.store.list_tasks()
        active = self._active_payload()
        active_task_id = str((active or {}).get("task_id") or "")
        return {
            "active": active,
            "queued": [
                task.task_id
                for task in sorted(tasks, key=lambda item: item.created_at)
                if task.status == "QUEUED" and task.task_id != active_task_id
            ],
            "interrupted": [task.task_id for task in tasks if task.status == "INTERRUPTED"],
        }

    def release_active(self, task_id: str, *, state: str = "interrupted", reason: str = "worker_launch_failed") -> dict[str, Any]:
        active = self._active_payload()
        if active and active.get("task_id") == task_id:
            self.active_file.unlink(missing_ok=True)
        task = self.store.load_task(task_id)
        if state == "queued":
            self.store.update_task_status(task_id, "QUEUED", clear_error=True)
            return {"ok": True, "task_id": task_id, "status": "QUEUED"}
        self._mark_interrupted(task, reason=reason)
        return {"ok": True, "task_id": task_id, "status": "INTERRUPTED"}

    def status_payload(self, task: TaskRecord) -> dict[str, Any]:
        active = self._active_payload()
        worker = self._read_worker(task.task_id)
        pid = _int_or_none((worker or {}).get("pid"))
        active_for_task = bool(active and active.get("task_id") == task.task_id)
        alive = bool(pid and is_pid_alive(pid))
        stale_reason = ""
        state = "terminal" if task.status in TERMINAL_STATUSES else "queued" if task.status == "QUEUED" else "idle"
        if active_for_task and alive:
            state = "running"
        elif active_for_task:
            state = str(active.get("state") or "claimed")
        elif task.status == "INTERRUPTED":
            state = "interrupted"
            stale_reason = "worker_process_missing"
        elif task.status in RUNNING_STATUSES and task.status != "QUEUED":
            state = "stale"
            stale_reason = "no_active_worker"
        return {
            "state": state,
            "can_cancel": task.status not in TERMINAL_STATUSES,
            "can_resume": task.status in {"FAILED", "CANCELLED", "INTERRUPTED"},
            "worker_pid": pid,
            "last_seen": str((worker or {}).get("last_seen") or (active or {}).get("last_seen") or ""),
            "stale_reason": stale_reason,
        }

    def force_cancel(self, task_id: str, *, reason: str = "forced_cancel") -> TaskRecord:
        task = self.store.load_task(task_id)
        worker = self._read_worker(task_id)
        pid = _int_or_none((worker or {}).get("pid"))
        if pid and is_pid_alive(pid):
            terminate_pid(pid)
        err = classify_exception(RuntimeError("Task cancelled"), stage=task.status)
        task = self.store.update_task_status(task_id, "CANCELLED", error=reason, error_info=err)
        self.store.clear_cancel(task_id)
        self.store.append_event(
            task_id,
            "cancelled",
            stage="CANCELLED",
            message="Task cancelled",
            level="warning",
            details={"forced": True, "reason": reason, "error_info": err},
        )
        self.finish_worker(task_id, exit_code=-1, state="cancelled")
        return task

    def _submit_payload(self, task: TaskRecord, artifacts_dir: Path) -> dict[str, Any]:
        return {
            "ok": True,
            "task_id": task.task_id,
            "status": task.status,
            "task_dir": str(artifacts_dir / task.task_id),
            "terminal": False,
            "message": "Task queued.",
        }

    def save_runtime_request(self, task_id: str, command: str, request: dict[str, Any]) -> None:
        write_json(self.request_file(task_id), {"command": command, "request": request})

    def _read_runtime_request(self, task_id: str) -> dict[str, Any]:
        path = self.request_file(task_id)
        if not path.exists():
            return {}
        payload = read_json(path)
        return payload if isinstance(payload, dict) else {}

    def load_worker_request(self, task_id: str) -> tuple[str, RunRequest | ResumeRequest] | None:
        payload = self._read_runtime_request(task_id)
        request_payload = payload.get("request")
        if not isinstance(request_payload, dict):
            return None
        command = str(payload.get("command") or "run")
        if command == "resume":
            return command, resume_request_from_payload(request_payload)
        return command, run_request_from_payload(request_payload)

    def _active_payload(self) -> dict[str, Any] | None:
        if not self.active_file.exists():
            return None
        try:
            payload = read_json(self.active_file)
        except Exception:
            return None
        return payload if isinstance(payload, dict) else None

    def _read_worker(self, task_id: str) -> dict[str, Any] | None:
        path = self.worker_file(task_id)
        if not path.exists():
            return None
        try:
            payload = read_json(path)
        except Exception:
            return None
        return payload if isinstance(payload, dict) else None

    def _mark_interrupted(self, task: TaskRecord, *, reason: str) -> None:
        err = classify_exception(RuntimeError(f"Task interrupted: {reason}"), stage=task.status)
        self.store.update_task_status(task.task_id, "INTERRUPTED", error=reason, error_info=err)
        checkpoint = self.store.load_checkpoint(task.task_id)
        checkpoint["status"] = "INTERRUPTED"
        checkpoint["error"] = reason
        checkpoint["error_info"] = err
        self.store.save_checkpoint(task.task_id, checkpoint)
        self.store.append_event(
            task.task_id,
            "interrupted",
            stage="INTERRUPTED",
            message=reason,
            level="warning",
            details={"error_info": err, "reason": reason},
        )
        self.finish_worker(task.task_id, exit_code=-1, state="interrupted")


def _int_or_none(value: Any) -> int | None:
    try:
        parsed = int(value)
    except Exception:
        return None
    return parsed if parsed > 0 else None


def _is_claim_stale(value: Any) -> bool:
    if not isinstance(value, str) or not value:
        return True
    try:
        parsed = datetime.fromisoformat(value)
    except Exception:
        return True
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - parsed).total_seconds() > CLAIM_STALE_SECONDS


def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        return _windows_pid_alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_pid(pid: int) -> None:
    if pid <= 0:
        return
    if os.name == "nt":
        PROCESS_TERMINATE = 0x0001
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_TERMINATE, False, pid)
        if handle:
            try:
                ctypes.windll.kernel32.TerminateProcess(handle, 1)
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        return
    os.kill(pid, signal.SIGTERM)


def _windows_pid_alive(pid: int) -> bool:
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_ulong()
        if not ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        STILL_ACTIVE = 259
        return exit_code.value == STILL_ACTIVE
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)
