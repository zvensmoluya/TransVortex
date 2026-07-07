from __future__ import annotations

import sqlite3
from pathlib import Path

from transvortex.app.desktop_api import DesktopApi
from transvortex.app.models import TaskRecord
from transvortex.app_service import handle_line
from transvortex.artifacts.catalog import CATALOG_SCHEMA_VERSION, TaskCatalog
from transvortex.artifacts.runtime import TaskRuntime
from transvortex.artifacts.task_store import TaskStore
from transvortex.utils import read_json, write_json


def _task(task_id: str, status: str = "INIT", updated_at: str = "2026-02-13T00:00:00+00:00") -> TaskRecord:
    return TaskRecord(
        task_id=task_id,
        input_file=f"{task_id}.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status=status,
        created_at="2026-02-13T00:00:00+00:00",
        updated_at=updated_at,
        output_path="",
        output_paths={},
    )


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
    (root / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )


def _request(method: str, params: dict | None = None) -> str:
    import json

    return json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def test_task_catalog_initializes_schema(tmp_path: Path) -> None:
    catalog = TaskCatalog(tmp_path / "artifacts")

    status = catalog.status()

    assert status["ok"] is True
    assert status["schema_version"] == CATALOG_SCHEMA_VERSION
    assert status["task_count"] == 0
    assert (tmp_path / "artifacts" / ".runtime" / "catalog.sqlite").exists()


def test_task_store_syncs_task_and_status_to_catalog(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    store.save_task(_task("task1", "INIT"))

    store.update_task_status("task1", "DONE", output_paths={"srt": "out.srt"})

    with sqlite3.connect(TaskCatalog(artifacts).db_path) as conn:
        row = conn.execute("select status, output_paths_json from tasks where task_id = 'task1'").fetchone()
    assert row[0] == "DONE"
    assert "out.srt" in row[1]


def test_append_event_updates_last_event_at_without_storing_event_body(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    store.save_task(_task("task1"))

    event = store.append_event("task1", "progress", message="secret event body")

    with sqlite3.connect(TaskCatalog(artifacts).db_path) as conn:
        row = conn.execute("select last_event_at from tasks where task_id = 'task1'").fetchone()
        names = [item[1] for item in conn.execute("pragma table_info(tasks)").fetchall()]
        dump = "\n".join(conn.iterdump())
    assert row[0] == event["created_at"]
    assert "message" not in names
    assert "secret event body" not in dump


def test_task_catalog_rebuild_indexes_valid_tasks_and_skips_bad_dirs(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    store.save_task(_task("task1", updated_at="2026-02-13T00:00:01+00:00"))
    store.save_task(_task("task2", updated_at="2026-02-13T00:00:02+00:00"))
    bad_dir = artifacts / "bad"
    bad_dir.mkdir(parents=True)
    (bad_dir / "task.json").write_text("{bad", encoding="utf-8")
    TaskCatalog(artifacts).db_path.unlink()

    payload = TaskCatalog(artifacts).rebuild()

    assert payload["indexed"] == 2
    assert payload["skipped"] == ["bad"]
    assert TaskCatalog(artifacts).list_task_ids(order="updated_desc") == ["task2", "task1"]


def test_catalog_delete_can_be_rebuilt_without_touching_task_files(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    store.save_task(_task("task1"))
    task_before = read_json(artifacts / "task1" / "task.json")
    TaskCatalog(artifacts).db_path.unlink()

    TaskCatalog(artifacts).rebuild()

    assert read_json(artifacts / "task1" / "task.json") == task_before
    assert TaskCatalog(artifacts).status()["task_count"] == 1


def test_desktop_tasks_list_uses_rebuildable_catalog_shape(tmp_path: Path) -> None:
    _write_config(tmp_path)
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    store.save_task(_task("task1", "DONE"))
    TaskCatalog(artifacts).db_path.unlink()
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("tasks.list"), root_dir=tmp_path)

    assert response["result"][0]["task_id"] == "task1"
    assert response["result"][0]["status"] == "DONE"
    assert response["result"][0]["task_dir"].endswith("task1")
    assert response["result"][0]["input_type"] == ""


def test_runtime_submit_cancel_and_reconcile_update_catalog(tmp_path: Path) -> None:
    _write_config(tmp_path)
    runtime = TaskRuntime(tmp_path / "artifacts")
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }
    service = DesktopApi(root_dir=tmp_path)
    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    task_id = submitted["result"]["task_id"]

    runtime.register_worker(task_id=task_id, pid=99999999, owner="test")
    runtime.reconcile()

    with sqlite3.connect(TaskCatalog(tmp_path / "artifacts").db_path) as conn:
        status = conn.execute("select status from tasks where task_id = ?", (task_id,)).fetchone()[0]
    assert status == "INTERRUPTED"


def test_catalog_does_not_store_secret_values(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    store = TaskStore(artifacts)
    task = _task("task1", "FAILED")
    task.error = "provider failed"
    task.error_info = {"message": "token should stay out"}
    store.save_task(task)
    secret = "sk-test-secret"
    write_json(artifacts / "task1" / "runtime_request.json", {"api_key": secret})

    TaskCatalog(artifacts).rebuild()

    with sqlite3.connect(TaskCatalog(artifacts).db_path) as conn:
        dump = "\n".join(conn.iterdump())
    assert secret not in dump
    assert "token should stay out" not in dump
    assert "provider failed" in dump
