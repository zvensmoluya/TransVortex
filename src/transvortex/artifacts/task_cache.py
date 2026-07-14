from __future__ import annotations

import shutil
from pathlib import Path

from .task_store import TaskStore


def task_cache_dir(cache_root: Path, task_id: str) -> Path:
    return cache_root / task_id


def cleanup_task_cache(cache_root: Path, task_id: str) -> bool:
    target = task_cache_dir(cache_root, task_id)
    if not target.exists():
        return False
    shutil.rmtree(target)
    return True


def cleanup_completed_task_caches(artifacts_dir: Path, cache_root: Path) -> list[str]:
    cleaned: list[str] = []
    for task in TaskStore(artifacts_dir).list_tasks():
        if task.status != "DONE":
            continue
        try:
            if cleanup_task_cache(cache_root, task.task_id):
                cleaned.append(task.task_id)
        except OSError:
            # Cache cleanup is recoverable and must not prevent service startup.
            continue
    return cleaned
