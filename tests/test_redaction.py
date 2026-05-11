from __future__ import annotations

import json
from pathlib import Path

from transvortex.redaction import REDACTED, redact
from transvortex.task_store import TaskStore
from transvortex.utils import write_json


def test_redact_masks_env_and_dotenv_secret_values(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TVX_MODEL_API_KEY", "sk-secret-from-env")
    (tmp_path / ".env").write_text("TVX_PROVIDER_CUSTOM_API_KEY=dotenv-secret\n", encoding="utf-8")

    payload = {
        "message": "env sk-secret-from-env and dotenv dotenv-secret",
        "url": "https://example.com/v1?key=abc123456789&model=m",
        "headers": {"Authorization": "Bearer token-secret-123456", "x-api-key": "raw-key"},
    }

    redacted = redact(payload, root_dir=tmp_path)
    raw = json.dumps(redacted, ensure_ascii=False)
    assert "sk-secret-from-env" not in raw
    assert "dotenv-secret" not in raw
    assert "abc123456789" not in raw
    assert "token-secret-123456" not in raw
    assert "raw-key" not in raw
    assert REDACTED in raw


def test_write_json_and_events_redact_persisted_secrets(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TVX_MODEL_API_KEY", "sk-persist-secret")
    output = tmp_path / "payload.json"
    write_json(output, {"error": "leaked sk-persist-secret", "api_key": "direct-secret"})

    raw_json = output.read_text(encoding="utf-8")
    assert "sk-persist-secret" not in raw_json
    assert "direct-secret" not in raw_json

    store = TaskStore(tmp_path / "artifacts")
    from transvortex.models import TaskRecord

    store.save_task(
        TaskRecord(
            task_id="t1",
            input_file="demo.mp4",
            source_lang="en",
            target_lang="zh-CN",
            bilingual=False,
            status="INIT",
            created_at="2026-02-13T00:00:00+00:00",
            updated_at="2026-02-13T00:00:00+00:00",
        )
    )
    store.append_event("t1", "error", message="bad key sk-persist-secret", details={"token": "event-token"})
    raw_event = store.events_file("t1").read_text(encoding="utf-8")
    assert "sk-persist-secret" not in raw_event
    assert "event-token" not in raw_event
