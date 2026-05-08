from __future__ import annotations

from transvortex.models import TaskRecord
from transvortex.task_store import TaskStore
from transvortex.utils import write_json


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
    updated = store.update_task_status("t1", "DONE", output_path="out.srt", output_paths={"srt": "out.srt"})
    assert updated.status == "DONE"
    assert updated.output_path == "out.srt"
    assert updated.output_paths == {"srt": "out.srt"}
    assert updated.error is None


def test_events_and_cancel_request(tmp_path) -> None:
    streamed = []
    store = TaskStore(tmp_path / "artifacts", event_sink=streamed.append)
    task = TaskRecord(
        task_id="t1",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="RUNNING",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)

    event = store.append_event("t1", "stage", stage="ASR", message="working", progress=2.5)
    assert event["progress"] == 1.0
    assert store.read_events("t1")[0]["message"] == "working"
    assert streamed[0]["message"] == "working"

    cancelled = store.request_cancel("t1")
    assert cancelled.status == "CANCEL_REQUESTED"
    assert store.is_cancel_requested("t1")
    assert store.read_events("t1")[-1]["type"] == "cancel_requested"

    store.clear_cancel("t1")
    assert not store.is_cancel_requested("t1")


def test_read_events_tolerates_missing_events_file_for_existing_task(tmp_path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="legacy",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="DONE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    write_json(store.task_file("legacy"), task)

    assert store.read_events("legacy") == []
