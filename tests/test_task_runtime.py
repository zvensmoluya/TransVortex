from __future__ import annotations

import os
from pathlib import Path

from transvortex.app.desktop_requests import ResumeRequest, RunRequest
from transvortex.app.models import TaskRecord
from transvortex.artifacts.runtime import TaskRuntime
from transvortex.artifacts.task_store import TaskStore
from transvortex.utils import read_json, write_json


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


def _task(task_id: str, status: str) -> TaskRecord:
    return TaskRecord(
        task_id=task_id,
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status=status,
        created_at=f"2026-02-13T00:00:0{1 if task_id.endswith('1') else 2}+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )


def test_runtime_submit_run_queues_task_and_saves_request(tmp_path: Path) -> None:
    _write_config(tmp_path)
    runtime = TaskRuntime(tmp_path / "artifacts")
    request = RunRequest(
        input=str(tmp_path / "demo.mp4"),
        source_lang="en",
        target_lang="zh-CN",
        provider="p1",
        model="m1",
        overrides={"source_mode": "asr"},
    )

    payload = runtime.submit_run(root_dir=tmp_path, request=request, providers_file=tmp_path / "providers.yaml")

    assert payload["ok"] is True
    assert payload["status"] == "QUEUED"
    task_id = payload["task_id"]
    assert runtime.store.load_task(task_id).status == "QUEUED"
    saved = runtime.load_worker_request(task_id)
    assert saved is not None
    command, saved_request = saved
    assert command == "run"
    assert saved_request.overrides["source_mode"] == "asr"
    assert not runtime.worker_file(task_id).exists()


def test_runtime_acquire_next_is_fifo_and_single_active(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    store = runtime.store
    store.save_task(_task("task1", "QUEUED"))
    store.save_task(_task("task2", "QUEUED"))
    runtime.save_runtime_request("task1", "run", {"request_version": 1, "input": "a.mp4", "source_lang": "en", "target_lang": "zh-CN"})
    runtime.save_runtime_request("task2", "run", {"request_version": 1, "input": "b.mp4", "source_lang": "en", "target_lang": "zh-CN"})

    first = runtime.acquire_next(root_dir=tmp_path)
    second = runtime.acquire_next(root_dir=tmp_path)

    assert first["acquired"] is True
    assert first["launch"]["task_id"] == "task1"
    assert second["acquired"] is False
    assert second["reason"] == "active_worker"
    assert runtime.snapshot()["queued"] == ["task2"]


def test_runtime_acquire_next_reconciles_by_default(tmp_path: Path, monkeypatch) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    calls = []
    original_reconcile = TaskRuntime.reconcile

    def counted_reconcile(self):  # noqa: ANN001
        calls.append("reconcile")
        return original_reconcile(self)

    monkeypatch.setattr(TaskRuntime, "reconcile", counted_reconcile)

    runtime.acquire_next(root_dir=tmp_path)

    assert calls == ["reconcile"]


def test_runtime_worker_heartbeat_and_finish(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "TRANSLATE"))

    worker = runtime.register_worker(task_id="task1", pid=os.getpid(), owner="test")
    runtime.heartbeat("task1", pid=os.getpid())
    runtime.finish_worker("task1", exit_code=0)

    saved = runtime.worker_file("task1").read_text(encoding="utf-8")
    assert str(worker["pid"]) in saved
    assert not runtime.active_file.exists()


def test_runtime_reconcile_marks_missing_worker_interrupted(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "TRANSLATE"))
    runtime.register_worker(task_id="task1", pid=99999999, owner="test")

    payload = runtime.reconcile()

    assert "task1" in payload["interrupted"]
    assert runtime.store.load_task("task1").status == "INTERRUPTED"
    assert runtime.store.read_events("task1")[-1]["type"] == "interrupted"


def test_runtime_load_worker_request_supports_resume(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "FAILED"))
    runtime.save_runtime_request("task1", "resume", {"request_version": 1, "task_id": "task1", "provider": "p1"})

    loaded = runtime.load_worker_request("task1")

    assert loaded is not None
    command, request = loaded
    assert command == "resume"
    assert isinstance(request, ResumeRequest)
    assert request.task_id == "task1"
    assert request.provider == "p1"


def test_runtime_force_cancel_marks_task_cancelled(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "TRANSLATE"))
    runtime.register_worker(task_id="task1", pid=99999999, owner="test")

    task = runtime.force_cancel("task1", reason="test_force")

    assert task.status == "CANCELLED"
    assert runtime.store.read_events("task1")[-1]["details"]["forced"] is True


def test_runtime_force_cancel_expired_uses_request_grace(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "TRANSLATE"))
    runtime.register_worker(task_id="task1", pid=99999999, owner="test")
    runtime.store.request_cancel("task1", force_after_grace=0)

    cancelled = runtime.force_cancel_expired(grace_seconds=60)

    assert cancelled == ["task1"]
    assert runtime.store.load_task("task1").status == "CANCELLED"


def test_runtime_release_claimed_task_marks_interrupted(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "QUEUED"))
    runtime.save_runtime_request("task1", "run", {"request_version": 1, "input": "a.mp4", "source_lang": "en", "target_lang": "zh-CN"})
    runtime.acquire_next(root_dir=tmp_path)

    payload = runtime.release_active("task1", reason="launch_failed")

    assert payload["status"] == "INTERRUPTED"
    assert runtime.store.load_task("task1").status == "INTERRUPTED"
    assert not runtime.active_file.exists()


def test_runtime_reconcile_marks_stale_claim_interrupted(tmp_path: Path) -> None:
    runtime = TaskRuntime(tmp_path / "artifacts")
    runtime.store.save_task(_task("task1", "QUEUED"))
    runtime.save_runtime_request("task1", "run", {"request_version": 1, "input": "a.mp4", "source_lang": "en", "target_lang": "zh-CN"})
    runtime.acquire_next(root_dir=tmp_path)
    active = read_json(runtime.active_file)
    active["claimed_at"] = "2026-01-01T00:00:00+00:00"
    write_json(runtime.active_file, active)

    payload = runtime.reconcile()

    assert "task1" in payload["interrupted"]
    assert runtime.store.load_task("task1").status == "INTERRUPTED"
    assert not runtime.active_file.exists()
