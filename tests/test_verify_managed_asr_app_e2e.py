from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import sys
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType

import pytest


def _load_helper() -> ModuleType:
    script = Path(__file__).resolve().parents[1] / "scripts" / "verify_managed_asr_app_e2e.py"
    spec = importlib.util.spec_from_file_location("verify_managed_asr_app_e2e", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


HELPER = _load_helper()
WORKSPACE_PYTHON = Path(sys.executable).resolve()


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture()
def e2e_fixture(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> dict[str, Path | str]:
    session_root = tmp_path / "managed-session"
    local_app_data = session_root / "LocalAppData"
    task_id = "tvx_20260718_010203_abcdef"
    task_dir = (
        local_app_data
        / "TransVortex"
        / "Workspace"
        / "Tasks"
        / task_id
    )
    stage_report = session_root / "stage_report.json"
    marker = session_root / HELPER.STAGING_MARKER_NAME
    installer = tmp_path / "TransVortex-setup.exe"
    install_root = session_root / "installed-app-parent" / "TransVortex"
    output_report = session_root / "managed_asr_installed_app_e2e.json"
    source = tmp_path / "media" / "sample.mp4"
    srt = tmp_path / "media" / "sample.zh-CN.srt"
    ass = tmp_path / "media" / "sample.zh-CN.ass"

    installer.write_bytes(b"installer")
    (install_root / "runtime" / "python").mkdir(parents=True)
    (install_root / "TransVortex.exe").write_bytes(b"app")
    (install_root / "runtime" / "python" / "python.exe").write_bytes(b"python")
    (install_root / "Uninstall.exe").write_bytes(b"uninstaller")
    source.parent.mkdir(parents=True)
    source.write_bytes(b"media")
    srt.write_text("1\n00:00:00,000 --> 00:00:01,000\ntranslated\n", encoding="utf-8")
    ass.write_text("[Script Info]\nTitle: translated\n", encoding="utf-8")

    _write_json(
        marker,
        {
            "schema_version": 1,
            "owner": HELPER.STAGING_OWNER,
            "session_root": str(session_root.resolve()),
        },
    )
    _write_json(
        stage_report,
        {
            "schema_version": 1,
            "ok": True,
            "plan_only": False,
            "side_effects_applied": True,
            "session": {
                "root": str(session_root.resolve()),
                "ownership_marker": str(marker.resolve()),
                "report_path": str(stage_report.resolve()),
            },
            "environment": {"LOCALAPPDATA": str(local_app_data.resolve())},
        },
    )
    _write_json(
        task_dir / "task.json",
        {
            "task_id": task_id,
            "input_file": str(source.resolve()),
            "status": "DONE",
            "updated_at": "2026-07-18T01:02:30+00:00",
            "output_path": str(srt.resolve()),
            "output_paths": {"srt": str(srt.resolve()), "ass": str(ass.resolve())},
            "settings": {"reexport_bilingual": True},
        },
    )
    _write_json(
        task_dir / "checkpoint.json",
        {
            "status": "DONE",
            "asr_total_segments": 1,
            "asr_done_count": 1,
            "source_segment_count": 2,
            "translate_total_chunks": 1,
            "translate_done_count": 1,
            "model_request_count": 4,
            "updated_at": "2026-07-18T01:01:00+00:00",
        },
    )
    _write_json(
        task_dir / "worker.json",
        {
            "task_id": task_id,
            "owner": "python",
            "command": "_worker",
            "executable": str((install_root / "runtime" / "python" / "python.exe").resolve()),
            "executable_sha256": _sha256(install_root / "runtime" / "python" / "python.exe"),
            "state": "ended",
            "exit_code": 0,
            "started_at": "2026-07-18T01:00:00+00:00",
            "ended_at": "2026-07-18T01:02:00+00:00",
        },
    )
    events = task_dir / "events.jsonl"
    events.parent.mkdir(parents=True, exist_ok=True)
    events.write_text(
        json.dumps(
            {
                "type": "done",
                "stage": "DONE",
                "progress": 1.0,
                "created_at": "2026-07-18T01:02:00+00:00",
            }
        )
        + "\n",
        encoding="utf-8",
    )
    rows = [
        {
            "start": 0.0,
            "end": 1.0,
            "text": "source",
            "meta": dict(HELPER.EXPECTED_ASR_META),
        },
        {
            "start": 1.0,
            "end": 2.0,
            "text": "source two",
            "meta": dict(HELPER.EXPECTED_ASR_META),
        },
    ]
    _write_json(task_dir / "source" / "asr" / "rows" / "segment_00000.json", rows)

    reexported_at = datetime(2026, 7, 18, 1, 2, 30, tzinfo=timezone.utc).timestamp()
    os.utime(srt, (reexported_at, reexported_at))
    os.utime(ass, (reexported_at, reexported_at))
    monkeypatch.setattr(
        HELPER.sys,
        "executable",
        str(install_root / "runtime" / "python" / "python.exe"),
    )
    return {
        "session_root": session_root,
        "stage_report": stage_report,
        "task_id": task_id,
        "task_dir": task_dir,
        "installer": installer,
        "install_root": install_root,
        "output_report": output_report,
    }


def _run(fixture: dict[str, Path | str], **overrides: object) -> dict[str, object]:
    arguments: dict[str, object] = {
        "stage_report": fixture["stage_report"],
        "task_id": fixture["task_id"],
        "installer": fixture["installer"],
        "install_root": fixture["install_root"],
        "output_report": fixture["output_report"],
    }
    arguments.update(overrides)
    return HELPER.run_verification(**arguments)


def test_verifies_managed_asr_task_outputs_and_post_completion_reexport(
    e2e_fixture: dict[str, Path | str],
) -> None:
    report = _run(e2e_fixture)

    assert report["ok"] is True
    assert report["task"]["task_status"] == "DONE"
    assert report["worker"]["exit_code"] == 0
    assert report["asr"]["runtime_source"] == "managed"
    assert report["asr"]["row_count"] == 2
    assert report["review_reexport"]["verified"] is True
    assert report["outputs"]["srt"]["sha256"] == _sha256(
        Path(str(report["outputs"]["srt"]["path"]))
    )
    written = json.loads(Path(e2e_fixture["output_report"]).read_text(encoding="utf-8"))
    assert written["acceptance"] == HELPER.ACCEPTANCE_ID


def test_rejects_non_managed_asr_rows(e2e_fixture: dict[str, Path | str]) -> None:
    row_file = Path(e2e_fixture["task_dir"]) / "source" / "asr" / "rows" / "segment_00000.json"
    rows = json.loads(row_file.read_text(encoding="utf-8"))
    rows[0]["meta"]["runtime_source"] = "external"
    _write_json(row_file, rows)

    with pytest.raises(RuntimeError, match="managed CUDA"):
        _run(e2e_fixture)


def test_rejects_task_that_did_not_finish(e2e_fixture: dict[str, Path | str]) -> None:
    task_file = Path(e2e_fixture["task_dir"]) / "task.json"
    task = json.loads(task_file.read_text(encoding="utf-8"))
    task["status"] = "FAILED"
    _write_json(task_file, task)

    with pytest.raises(RuntimeError, match="must both be DONE"):
        _run(e2e_fixture)


def test_rejects_report_outside_owned_session(
    e2e_fixture: dict[str, Path | str],
    tmp_path: Path,
) -> None:
    outside = tmp_path / "outside.json"

    with pytest.raises(ValueError, match="owned staging session"):
        _run(e2e_fixture, output_report=outside)

    assert not outside.exists()


def test_rejects_workspace_python_provenance(
    e2e_fixture: dict[str, Path | str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(HELPER.sys, "executable", str(WORKSPACE_PYTHON))
    with pytest.raises(RuntimeError, match="installed runtime Python"):
        _run(e2e_fixture)


def test_rejects_report_inside_task_evidence(e2e_fixture: dict[str, Path | str]) -> None:
    with pytest.raises(ValueError, match="session root or its reports"):
        _run(e2e_fixture, output_report=Path(e2e_fixture["task_dir"]) / "checkpoint.json")


def test_rejects_report_overwriting_stage_evidence(e2e_fixture: dict[str, Path | str]) -> None:
    with pytest.raises(ValueError, match="ownership evidence"):
        _run(e2e_fixture, output_report=Path(e2e_fixture["stage_report"]))


def test_rejects_worker_from_another_python(e2e_fixture: dict[str, Path | str]) -> None:
    worker_file = Path(e2e_fixture["task_dir"]) / "worker.json"
    worker = json.loads(worker_file.read_text(encoding="utf-8"))
    worker["executable"] = str(WORKSPACE_PYTHON)
    worker["executable_sha256"] = _sha256(WORKSPACE_PYTHON)
    _write_json(worker_file, worker)

    with pytest.raises(RuntimeError, match="did not exit cleanly"):
        _run(e2e_fixture)
