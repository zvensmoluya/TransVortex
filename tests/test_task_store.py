from __future__ import annotations

from transvortex.app.models import TaskRecord
from transvortex.artifacts.task_store import TaskStore
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
    assert store.load_task("t1").updated_at == event["created_at"]

    cancelled = store.request_cancel("t1")
    assert cancelled.status == "CANCEL_REQUESTED"
    assert store.is_cancel_requested("t1")
    assert store.read_events("t1")[-1]["type"] == "cancel_requested"

    store.clear_cancel("t1")
    assert not store.is_cancel_requested("t1")


def test_cancel_request_keeps_terminal_task_status(tmp_path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="done",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="DONE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)

    cancelled = store.request_cancel("done")

    assert cancelled.status == "DONE"
    assert not store.is_cancel_requested("done")
    assert store.read_events("done") == []


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


def test_read_events_page_uses_line_cursor(tmp_path) -> None:
    store = TaskStore(tmp_path / "artifacts")
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
    store.append_event("t1", "first", message="一")
    store.append_event("t1", "second", message="二")
    store.append_event("t1", "third", message="三")

    first = store.read_events_page("t1", cursor=0, limit=2)
    second = store.read_events_page("t1", cursor=first["next_cursor"], limit=2)

    assert [event["type"] for event in first["events"]] == ["first", "second"]
    assert first["next_cursor"] == 2
    assert first["has_more"] is True
    assert [event["type"] for event in second["events"]] == ["third"]
    assert second["next_cursor"] == 3
    assert second["has_more"] is False


def test_append_event_rounds_progress_and_refreshes_task_updated_at(tmp_path) -> None:
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t1",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="TRANSLATE",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)

    event = store.append_event("t1", "progress", stage="TRANSLATE", message="working", progress=0.41000000000000003)

    assert event["progress"] == 0.41
    assert store.read_events("t1")[0]["progress"] == 0.41
    assert store.load_task("t1").updated_at == event["created_at"]
