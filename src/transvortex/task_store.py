from __future__ import annotations

from pathlib import Path

from .models import TaskRecord
from .utils import read_json, utc_now_iso, write_json


class TaskStore:
    def __init__(self, artifacts_dir: Path) -> None:
        self.artifacts_dir = artifacts_dir

    def task_dir(self, task_id: str) -> Path:
        return self.artifacts_dir / task_id

    def task_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "task.json"

    def checkpoint_file(self, task_id: str) -> Path:
        return self.task_dir(task_id) / "checkpoint.json"

    def save_task(self, task: TaskRecord) -> None:
        write_json(self.task_file(task.task_id), task)

    def load_task(self, task_id: str) -> TaskRecord:
        data = read_json(self.task_file(task_id))
        return TaskRecord(**data)

    def update_task_status(
        self,
        task_id: str,
        status: str,
        *,
        output_path: str | None = None,
        error: str | None = None,
    ) -> TaskRecord:
        task = self.load_task(task_id)
        task.status = status
        task.updated_at = utc_now_iso()
        if output_path is not None:
            task.output_path = output_path
        if error is not None:
            task.error = error
        elif status == "DONE":
            task.error = None
        self.save_task(task)
        return task

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
