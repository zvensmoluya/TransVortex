from pathlib import Path

from transvortex.app.models import TaskRecord
from transvortex.artifacts.task_cache import cleanup_completed_task_caches
from transvortex.artifacts.task_store import TaskStore


def _task(task_id: str, status: str) -> TaskRecord:
    return TaskRecord(
        task_id=task_id,
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status=status,
        created_at="2026-07-14T00:00:00+00:00",
        updated_at="2026-07-14T00:00:00+00:00",
    )


def test_startup_cleanup_removes_only_completed_task_caches(tmp_path: Path) -> None:
    artifacts_dir = tmp_path / "Tasks"
    cache_root = tmp_path / "Cache"
    store = TaskStore(artifacts_dir)
    store.save_task(_task("done-task", "DONE"))
    store.save_task(_task("failed-task", "FAILED"))
    (cache_root / "done-task" / "media").mkdir(parents=True)
    (cache_root / "done-task" / "media" / "part.wav").write_bytes(b"done")
    (cache_root / "failed-task" / "media").mkdir(parents=True)
    (cache_root / "failed-task" / "media" / "part.wav").write_bytes(b"resume")

    cleaned = cleanup_completed_task_caches(artifacts_dir, cache_root)

    assert cleaned == ["done-task"]
    assert not (cache_root / "done-task").exists()
    assert (cache_root / "failed-task" / "media" / "part.wav").exists()
