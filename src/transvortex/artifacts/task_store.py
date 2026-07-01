from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable

from ..app.models import TaskRecord
from ..utils import FileLock, append_jsonl, read_json, read_jsonl, utc_now_iso, write_json
from .catalog import try_sync_task


def _normalize_progress(progress: float) -> float:
    clamped = max(0.0, min(1.0, float(progress)))
    return round(clamped, 4)


class TaskStore:
    def __init__(self, artifacts_dir: Path, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.artifacts_dir = artifacts_dir
        self.event_sink = event_sink

    def task_dir(self, task_id: str) -> Path:
        return self.artifacts_dir / task_id

    def task_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "task.json"

    def checkpoint_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "checkpoint.json"

    def events_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "events.jsonl"

    def cancel_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "cancel.requested"

    def runtime_lock_file(self) -> Path:
        return self.artifacts_dir / ".runtime" / "runtime.lock"

    def lock(self) -> FileLock:
        return FileLock(self.runtime_lock_file())

    def save_task(self, task: TaskRecord) -> None:
        with self.lock():
            self._save_task_unlocked(task)

    def _save_task_unlocked(self, task: TaskRecord) -> None:
        write_json(self.task_file(task.task_id), task)
        self.events_file(task.task_id).parent.mkdir(parents=True, exist_ok=True)
        self.events_file(task.task_id).touch(exist_ok=True)
        try_sync_task(self.artifacts_dir, task)

    def load_task(self, task_id: str) -> TaskRecord:
        task_file = self.task_file(task_id)
        if not task_file.exists():
            raise FileNotFoundError(f"Task not found: {task_id}")
        data = read_json(task_file)
        return TaskRecord(**data)

    def update_task_status(
        self,
        task_id: str,
        status: str,
        *,
        output_path: str | None = None,
        output_paths: dict[str, str] | None = None,
        error: str | None = None,
        error_info: dict[str, Any] | None = None,
        clear_error: bool = False,
    ) -> TaskRecord:
        with self.lock():
            task = self.load_task(task_id)
            task.status = status
            task.updated_at = utc_now_iso()
            if output_path is not None:
                task.output_path = output_path
            if output_paths is not None:
                task.output_paths = output_paths
            if error is not None:
                task.error = error
            if error_info is not None:
                task.error_info = error_info
            if clear_error or status == "DONE":
                task.error = None
                task.error_info = None
            self._save_task_unlocked(task)
            return task

    def append_event(
        self,
        task_id: str,
        event_type: str,
        *,
        stage: str | None = None,
        message: str = "",
        progress: float | None = None,
        level: str = "info",
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        created_at = utc_now_iso()
        event: dict[str, Any] = {
            "type": event_type,
            "task_id": task_id,
            "created_at": created_at,
            "level": level,
            "message": message,
        }
        if stage is not None:
            event["stage"] = stage
        if progress is not None:
            event["progress"] = _normalize_progress(progress)
        if details:
            event["details"] = details
        with self.lock():
            append_jsonl(self.events_file(task_id), event)
            try:
                task = self.load_task(task_id)
                task.updated_at = created_at
                write_json(self.task_file(task.task_id), task)
                self.events_file(task.task_id).parent.mkdir(parents=True, exist_ok=True)
                self.events_file(task.task_id).touch(exist_ok=True)
                try_sync_task(self.artifacts_dir, task, last_event_at=created_at)
            except Exception:
                pass
        if self.event_sink is not None:
            try:
                self.event_sink(event)
            except Exception:
                pass
        try:
            from .runtime import TaskRuntime

            runtime = TaskRuntime(self.artifacts_dir)
            if runtime.is_tracked(task_id):
                runtime.heartbeat(task_id)
        except Exception:
            pass
        return event

    def list_tasks(self) -> list[TaskRecord]:
        if not self.artifacts_dir.exists():
            return []
        tasks: list[TaskRecord] = []
        for child in self.artifacts_dir.iterdir():
            if not child.is_dir():
                continue
            task_file = child / "task.json"
            if not task_file.exists():
                continue
            try:
                tasks.append(TaskRecord(**read_json(task_file)))
            except Exception:
                continue
        tasks.sort(key=lambda task: task.updated_at, reverse=True)
        return tasks

    def read_events(self, task_id: str) -> list[dict[str, Any]]:
        self.load_task(task_id)
        return read_jsonl(self.events_file(task_id))

    def read_events_page(self, task_id: str, *, cursor: int = 0, limit: int = 500) -> dict[str, Any]:
        self.load_task(task_id)
        safe_cursor = max(0, int(cursor))
        safe_limit = max(1, min(5000, int(limit)))
        path = self.events_file(task_id)
        events: list[dict[str, Any]] = []
        line_index = 0
        has_more = False
        if path.exists():
            with path.open("r", encoding="utf-8") as f:
                for line in f:
                    stripped = line.strip()
                    if not stripped:
                        continue
                    if line_index < safe_cursor:
                        line_index += 1
                        continue
                    if len(events) >= safe_limit:
                        has_more = True
                        break
                    events.append(read_event_line(stripped))
                    line_index += 1
        return {
            "task_id": task_id,
            "events": events,
            "cursor": safe_cursor,
            "next_cursor": safe_cursor + len(events),
            "has_more": has_more,
        }

    def request_cancel(self, task_id: str, *, force_after_grace: float | None = None) -> TaskRecord:
        with self.lock():
            task = self.load_task(task_id)
            if task.status in {"CANCEL_REQUESTED", "DONE", "FAILED", "CANCELLED"}:
                return task
            self.task_dir(task_id).mkdir(parents=True, exist_ok=True)
            write_json(
                self.cancel_file(task_id),
                {
                    "requested_at": utc_now_iso(),
                    "force_after_grace": force_after_grace,
                },
            )
            task = self.update_task_status(task_id, "CANCEL_REQUESTED")
            self.append_event(task_id, "cancel_requested", message="Cancel requested")
            return task

    def clear_cancel(self, task_id: str) -> None:
        with self.lock():
            self.cancel_file(task_id).unlink(missing_ok=True)

    def is_cancel_requested(self, task_id: str) -> bool:
        return self.cancel_file(task_id).exists()

    def load_checkpoint(self, task_id: str) -> dict:
        file = self.checkpoint_file(task_id)
        if not file.exists():
            return {
                "status": "INIT",
                "ingest_done": False,
                "asr_done_segments": [],
                "translate_done_chunks": [],
            }
        return read_json(file)

    def save_checkpoint(self, task_id: str, data: dict) -> None:
        with self.lock():
            data["updated_at"] = utc_now_iso()
            write_json(self.checkpoint_file(task_id), data)


def read_event_line(line: str) -> dict[str, Any]:
    payload = json.loads(line)
    return payload if isinstance(payload, dict) else {"value": payload}
