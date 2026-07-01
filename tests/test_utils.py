from __future__ import annotations

import os

import pytest

from transvortex import utils
from transvortex.utils import read_json, write_json


def test_write_json_preserves_utf8_payload(tmp_path) -> None:
    path = tmp_path / "nested" / "payload.json"

    write_json(path, {"message": "中文内容", "items": ["字幕", "翻译"]})

    assert read_json(path) == {"message": "中文内容", "items": ["字幕", "翻译"]}
    assert not list(path.parent.glob("*.tmp"))


def test_write_json_retries_permission_error_on_replace(tmp_path, monkeypatch) -> None:
    path = tmp_path / "payload.json"
    calls = []
    real_replace = os.replace

    def flaky_replace(src, dst):  # noqa: ANN001
        calls.append((src, dst))
        if len(calls) < 3:
            raise PermissionError("temporary sharing violation")
        real_replace(src, dst)

    monkeypatch.setattr(utils.os, "replace", flaky_replace)
    monkeypatch.setattr(utils.time, "sleep", lambda _seconds: None)

    write_json(path, {"ok": True})

    assert len(calls) == 3
    assert read_json(path) == {"ok": True}
    assert not list(path.parent.glob("*.tmp"))


def test_write_json_cleans_temp_file_when_replace_keeps_failing(tmp_path, monkeypatch) -> None:
    path = tmp_path / "payload.json"

    def failing_replace(_src, _dst):  # noqa: ANN001
        raise PermissionError("persistent sharing violation")

    monkeypatch.setattr(utils.os, "replace", failing_replace)
    monkeypatch.setattr(utils.time, "sleep", lambda _seconds: None)

    with pytest.raises(PermissionError):
        write_json(path, {"ok": True})

    assert not path.exists()
    assert not list(path.parent.glob("*.tmp"))
