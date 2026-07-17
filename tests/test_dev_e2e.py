from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from transvortex.app import dev_e2e
from transvortex.app.asr_runtime import (
    asr_provider_readiness,
    load_asr_catalog,
    model_catalog_entry,
    resolve_whisper_runtime,
)
from transvortex.app.config import load_app_config


REPO_ROOT = Path(__file__).resolve().parents[1]


def _successful_probe(python: Path, model: Path, *, device: str = "cuda") -> dict[str, object]:
    return {
        "ok": True,
        "protocol_version": 1,
        "python_executable": str(python),
        "python_version": "3.13.14",
        "faster_whisper_version": "1.2.1",
        "ctranslate2_version": "4.8.1",
        "cpu_compute_types": ["int8", "float32"],
        "cuda": {
            "available": device == "cuda",
            "device_count": 1 if device == "cuda" else 0,
            "compute_types": ["float16", "int8_float16"] if device == "cuda" else [],
        },
        "model": {
            "loaded": True,
            "model_path": str(model),
            "device": device,
            "compute_type": "int8_float16" if device == "cuda" else "int8",
        },
        "transcription": {"ok": True, "row_count": 0},
        "model_paths": {"large-v3": str(model)},
    }


def test_resolve_model_path_uses_pinned_hf_hub_cache(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    catalog = load_asr_catalog()
    model = model_catalog_entry(catalog, "large-v3")
    assert model is not None
    repository = str(model["repository"]).replace("/", "--")
    expected = (
        tmp_path
        / f"models--{repository}"
        / "snapshots"
        / str(model["revision"])
    )
    expected.mkdir(parents=True)
    monkeypatch.setattr(
        dev_e2e,
        "validate_model_path_identity",
        lambda *_args, **_kwargs: {"method": "test"},
    )

    resolved = dev_e2e.resolve_model_path(
        "large-v3",
        environment={"HF_HUB_CACHE": str(tmp_path)},
        home=tmp_path / "unused-home",
    )

    assert resolved == expected.resolve()


def test_explicit_model_path_must_match_model_id(tmp_path: Path) -> None:
    model = tmp_path / "wrong-model"
    model.mkdir()
    (model / "config.json").write_text('{"model": "not-large-v3"}', encoding="utf-8")

    with pytest.raises(ValueError, match="does not match catalog model id large-v3"):
        dev_e2e.resolve_model_path("large-v3", str(model))


def test_prepare_home_never_claims_unmarked_directory_with_force(tmp_path: Path) -> None:
    home = tmp_path / "not-owned"
    home.mkdir()
    (home / "keep.txt").write_text("user data", encoding="utf-8")

    with pytest.raises(FileExistsError, match="not an APP E2E home"):
        dev_e2e._prepare_home(home, force=True)

    assert (home / "keep.txt").read_text(encoding="utf-8") == "user data"


def test_prepare_external_worker_home_is_ready_and_isolated(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session_root = tmp_path / "session"
    app_data_root = session_root / "LocalAppData" / "TransVortex"
    unrelated_home = tmp_path / "real-user-home"
    monkeypatch.setenv("TRANSVORTEX_HOME", str(unrelated_home))

    python = tmp_path / "python.exe"
    python.write_bytes(b"test executable")
    model = tmp_path / "large-v3"
    model.mkdir()
    monkeypatch.setattr(
        dev_e2e,
        "probe_python_environment",
        lambda *_args, **_kwargs: _successful_probe(python, model),
    )
    monkeypatch.setattr(
        dev_e2e,
        "validate_model_path_identity",
        lambda *_args, **_kwargs: {
            "method": "catalog_config_sha256",
            "config_sha256": "test",
            "revision": "test",
        },
    )

    report = dev_e2e.prepare_app_e2e_environment(
        e2e_home=app_data_root,
        python_executable=python,
        model_path=model,
        model_id="large-v3",
        device="cuda",
        compute_type="auto",
        pipeline_template=REPO_ROOT / "pipeline.desktop.yaml",
        base_providers_file=REPO_ROOT / "providers.yaml",
    )

    config_root = app_data_root / "Config"
    state_path = config_root / "asr_runtime_state.json"
    assert state_path.is_file()
    assert not (unrelated_home / "Config" / "asr_runtime_state.json").exists()
    assert report["readiness"] == {"state": "ready", "code": "ready", "can_run": True}
    assert report["asr_provider"]["runtime_source"] == "external"

    pipeline = yaml.safe_load((config_root / "pipeline.yaml").read_text(encoding="utf-8"))
    row = next(
        item
        for item in pipeline["asr_providers"]
        if item["name"] == "faster_whisper_large_v3"
    )
    assert row["kind"] == "local_worker"
    assert row["runtime"]["source"] == "external"
    assert row["local"]["model_source"] == "external"
    assert row["local"]["model_path"] == str(model.resolve())

    config = load_app_config(root_dir=config_root)
    provider = config.asr_providers["faster_whisper_large_v3"]
    readiness = asr_provider_readiness(
        provider,
        root_dir=config_root,
        app_data_root=app_data_root,
    )
    runtime = resolve_whisper_runtime(
        provider,
        root_dir=config_root,
        app_data_root=app_data_root,
    )
    assert readiness["can_run"] is True
    assert runtime["python_executable"] == str(python.resolve())
    assert runtime["model_path"] == str(model.resolve())


def test_cuda_probe_must_load_the_model_on_cuda() -> None:
    probe = _successful_probe(Path("python.exe"), Path("model"), device="cpu")
    probe["cuda"] = {
        "available": True,
        "device_count": 1,
        "compute_types": ["float16"],
    }

    with pytest.raises(RuntimeError, match="CUDA was requested"):
        dev_e2e._require_successful_probe(probe, requested_device="cuda")


def test_verify_session_requires_real_external_worker_task_evidence(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session_root = tmp_path / "session"
    home = session_root / "LocalAppData" / "TransVortex"
    model = tmp_path / "model"
    model.mkdir()
    python = tmp_path / "python.exe"
    python.write_bytes(b"python")
    input_path = tmp_path / "input.mp4"
    input_path.write_bytes(b"media")
    executable = tmp_path / "TransVortex.exe"
    executable.write_bytes(b"release")
    output = tmp_path / "result.srt"
    output.write_text("1\n00:00:00,000 --> 00:00:01,000\nhello\n", encoding="utf-8")

    monkeypatch.setattr(
        dev_e2e,
        "validate_model_path_identity",
        lambda *_args, **_kwargs: {
            "method": "catalog_config_sha256",
            "config_sha256": "test",
            "revision": "test",
        },
    )
    monkeypatch.setattr(
        dev_e2e,
        "probe_python_environment",
        lambda *_args, **_kwargs: _successful_probe(python, model),
    )
    preparation = dev_e2e.prepare_app_e2e_environment(
        e2e_home=home,
        python_executable=python,
        model_path=model,
        model_id="large-v3",
        device="cuda",
        compute_type="auto",
        pipeline_template=REPO_ROOT / "pipeline.desktop.yaml",
        base_providers_file=REPO_ROOT / "providers.yaml",
    )
    assert preparation["ok"] is True

    manual_report = session_root / "Acceptance" / "manual_release_acceptance.json"
    manual_report.parent.mkdir(parents=True)
    manual_report.write_text(
        """
{
  "ok": true,
  "launch_check": false,
  "manual_visible_e2e_ok": true,
  "input_path": "%s",
  "started_at": "2026-07-17T10:00:00+08:00",
  "ended_at": "2026-07-17T10:05:00+08:00",
  "steps": [{"id": "task_completed", "confirmed": true, "notes": "secret-token"}]
}
        """.strip()
        % str(input_path.resolve()).replace("\\", "\\\\"),
        encoding="utf-8",
    )
    task_dir = home / "Workspace" / "Tasks" / "tvx_test"
    rows_dir = task_dir / "source" / "asr" / "rows"
    rows_dir.mkdir(parents=True)
    (task_dir / "task.json").write_text(
        """
{
  "task_id": "tvx_test",
  "input_file": "%s",
  "status": "DONE",
  "created_at": "2026-07-17T02:01:00+00:00",
  "updated_at": "2026-07-17T02:04:00+00:00",
  "output_path": "%s",
  "output_paths": {"srt": "%s"},
  "settings": {
    "input_type": "video_asr_translate",
    "asr_provider": "faster_whisper_large_v3"
  }
}
        """.strip()
        % tuple(
            str(path.resolve()).replace("\\", "\\\\")
            for path in (input_path, output, output)
        ),
        encoding="utf-8",
    )
    (task_dir / "checkpoint.json").write_text(
        '{"status": "DONE", "asr_total_segments": 1, "asr_done_count": 1, "asr_done_segments": [0]}',
        encoding="utf-8",
    )
    (task_dir / "worker.json").write_text(
        '{"owner": "python", "command": "_worker", "state": "ended", "exit_code": 0}',
        encoding="utf-8",
    )
    (task_dir / "events.jsonl").write_text(
        '{"type": "done", "stage": "DONE", "progress": 1.0, "created_at": "2026-07-17T02:04:00+00:00"}\n',
        encoding="utf-8",
    )
    (rows_dir / "segment_00000.json").write_text(
        json.dumps(
            [
                {
                    "start": 0.0,
                    "end": 1.0,
                    "text": "hello",
                    "meta": {
                        "source": "asr",
                        "provider": "faster_whisper_large_v3",
                        "protocol": "faster_whisper",
                        "runtime_source": "external",
                        "runtime_id": preparation["asr_provider"]["runtime_id"],
                        "transport": "stdio_jsonl",
                        "device": "cuda",
                        "compute_type": "int8_float16",
                    },
                }
            ]
        ),
        encoding="utf-8",
    )
    session_report = session_root / "app_e2e_session.json"

    report = dev_e2e.verify_app_e2e_session(
        e2e_home=home,
        session_root=session_root,
        manual_report_path=manual_report,
        expected_input_path=input_path,
        exe_path=executable,
        repo_root=REPO_ROOT,
        session_report_path=session_report,
    )

    assert report["ok"] is True
    assert report["task"]["id"] == "tvx_test"
    assert report["asr_evidence"]["runtime_source"] == "external"
    assert report["asr_evidence"]["transport"] == "stdio_jsonl"
    assert report["asr_evidence"]["row_count"] == 1
    assert "secret-token" not in session_report.read_text(encoding="utf-8")
