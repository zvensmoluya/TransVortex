from __future__ import annotations

from pathlib import Path
from typing import Any

from ..artifacts.task_store import TaskStore
from ..utils import read_json

class TaskCancelled(RuntimeError):
    pass

def _check_cancel(store: TaskStore, task_id: str) -> None:
    if store.is_cancel_requested(task_id):
        raise TaskCancelled("Task cancelled")


def _ensure_artifact_dirs(paths: dict[str, Path]) -> None:
    for p in paths.values():
        p.mkdir(parents=True, exist_ok=True)


def _require_file(path: Path, label: str) -> None:
    if not path.exists() or path.stat().st_size == 0:
        raise RuntimeError(f"Missing or empty artifact: {label}")


def _is_nonempty_file(path: Path) -> bool:
    return path.exists() and path.is_file() and path.stat().st_size > 0


def _is_valid_json_list(path: Path) -> bool:
    if not _is_nonempty_file(path):
        return False
    try:
        return isinstance(read_json(path), list)
    except Exception:
        return False
