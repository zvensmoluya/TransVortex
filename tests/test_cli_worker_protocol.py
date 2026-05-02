from __future__ import annotations

import json
from pathlib import Path

from transvortex.cli import main
from transvortex.models import TaskRecord
from transvortex.task_store import TaskStore


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


def test_status_events_and_cancel_cli_json(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="t1",
        input_file="demo.mp4",
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        status="ASR",
        created_at="2026-02-13T00:00:00+00:00",
        updated_at="2026-02-13T00:00:00+00:00",
    )
    store.save_task(task)
    store.append_event("t1", "stage", stage="ASR", message="working", progress=0.25)

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "status", "--task-id", "t1", "--json"],
    )
    main()
    payload = json.loads(capsys.readouterr().out)
    assert payload["task_id"] == "t1"
    assert payload["status"] == "ASR"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "events", "--task-id", "t1"],
    )
    main()
    first_event = json.loads(capsys.readouterr().out.splitlines()[0])
    assert first_event["type"] == "stage"

    monkeypatch.setattr(
        "sys.argv",
        ["transvortex", "--root", str(tmp_path), "cancel", "--task-id", "t1", "--json"],
    )
    main()
    cancelled = json.loads(capsys.readouterr().out)
    assert cancelled["status"] == "CANCEL_REQUESTED"
    assert store.is_cancel_requested("t1")
