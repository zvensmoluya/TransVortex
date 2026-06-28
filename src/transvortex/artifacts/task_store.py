from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from ..app.models import TaskRecord
from ..utils import append_jsonl, read_json, read_jsonl, utc_now_iso, write_json


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

    def save_task(self, task: TaskRecord) -> None:
        write_json(self.task_file(task.task_id), task)
        self.events_file(task.task_id).parent.mkdir(parents=True, exist_ok=True)
        self.events_file(task.task_id).touch(exist_ok=True)

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
        self.save_task(task)
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
        append_jsonl(self.events_file(task_id), event)
        try:
            task = self.load_task(task_id)
            task.updated_at = created_at
            self.save_task(task)
        except Exception:
            pass
        if self.event_sink is not None:
            try:
                self.event_sink(event)
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

    def request_cancel(self, task_id: str) -> TaskRecord:
        task = self.load_task(task_id)
        if task.status in {"CANCEL_REQUESTED", "DONE", "FAILED", "CANCELLED"}:
            return task
        self.task_dir(task_id).mkdir(parents=True, exist_ok=True)
        self.cancel_file(task_id).write_text(utc_now_iso(), encoding="utf-8")
        task = self.update_task_status(task_id, "CANCEL_REQUESTED")
        self.append_event(task_id, "cancel_requested", message="Cancel requested")
        return task

    def clear_cancel(self, task_id: str) -> None:
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
        data["updated_at"] = utc_now_iso()
        write_json(self.checkpoint_file(task_id), data)
