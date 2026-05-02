from __future__ import annotations

from transvortex.models import TaskRecord
from transvortex.task_store import TaskStore


def test_done_status_clears_previous_error(tmp_path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t1",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="FAILED",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
        error="previous error",
    )
    store.save_task(task)
    updated = store.update_task_status("t1", "DONE", output_path="out.srt")
    assert updated.status == "DONE"
    assert updated.output_path == "out.srt"
    assert updated.error is None
