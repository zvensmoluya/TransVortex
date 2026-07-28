from __future__ import annotations

import shutil
from pathlib import Path

from transvortex.app.doctor import doctor_report, format_doctor_report


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: faster_whisper_large_v3}
asr_engines:
  - id: faster_whisper_large_v3
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
    device: cpu
    compute_type: int8
        """.strip(),
        encoding="utf-8",
    )
    (root / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: TVX_MODEL_API_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )


def _status_by_name(report: dict) -> dict[str, str]:
    return {item["name"]: item["status"] for item in report["checks"]}


def test_doctor_report_passes_with_runtime_config_and_key(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr(
        "transvortex.app.doctor.asr_provider_readiness",
        lambda *_args, **_kwargs: {"state": "ready", "code": "ready"},
    )

    report = doctor_report(root_dir=tmp_path)

    assert report["status"] == "PASS"
    assert report["root_dir"] == str(tmp_path.resolve())
    assert isinstance(report["checks"], list)
    statuses = _status_by_name(report)
    assert statuses["ffmpeg"] == "PASS"
    assert statuses["ffprobe"] == "PASS"
    assert statuses["provider_env_key"] == "PASS"
    assert statuses["provider_protocol"] == "PASS"
    assert "TransVortex Doctor: PASS" in format_doctor_report(report)


def test_doctor_reports_unavailable_faster_whisper_worker(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr(
        "transvortex.app.doctor.asr_provider_readiness",
        lambda *_args, **_kwargs: {
            "state": "unavailable",
            "code": "runtime_incompatible",
        },
    )

    report = doctor_report(root_dir=tmp_path)
    wh_check = next(item for item in report["checks"] if item["name"] == "faster_whisper")

    assert report["status"] == "FAIL"
    assert wh_check["code"] == "runtime_incompatible"


def test_doctor_reports_missing_key_with_legacy_hint(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    (tmp_path / ".env").write_text("OPENAI_API_KEY=old\n", encoding="utf-8")
    monkeypatch.delenv("TVX_MODEL_API_KEY", raising=False)
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr(
        "transvortex.app.doctor.asr_provider_readiness",
        lambda *_args, **_kwargs: {"state": "ready", "code": "ready"},
    )

    report = doctor_report(root_dir=tmp_path)
    key_check = next(item for item in report["checks"] if item["name"] == "provider_env_key")

    assert report["status"] == "FAIL"
    assert key_check["code"] == "missing_env"
    assert key_check["details"]["env_key"] == "TVX_MODEL_API_KEY"
    assert key_check["details"]["legacy_keys_present"] == ["OPENAI_API_KEY"]
    assert "TVX_MODEL_API_KEY" in key_check["hint_zh"]


def test_doctor_reports_missing_binary_and_asr_dependency(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: None)
    monkeypatch.setattr(
        "transvortex.app.doctor.asr_provider_readiness",
        lambda *_args, **_kwargs: {"state": "unavailable", "code": "runtime_missing"},
    )

    report = doctor_report(root_dir=tmp_path)
    statuses = _status_by_name(report)

    assert report["status"] == "FAIL"
    assert statuses["ffmpeg"] == "FAIL"
    assert statuses["ffprobe"] == "FAIL"
    assert statuses["faster_whisper"] == "FAIL"


def test_doctor_reports_remote_asr_provider_and_key(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: openai_asr}
asr_engines:
  - id: openai_asr
    type: openai_transcription
    model: whisper-1
    endpoint:
      credential:
        binding_id: openai_asr
        secret_ref: openai_asr
        env_fallback: OPENAI_API_KEY
        """.strip(),
        encoding="utf-8",
    )
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setenv("OPENAI_API_KEY", "asr-key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.app.doctor.importlib.util.find_spec", lambda name: None)

    report = doctor_report(root_dir=tmp_path)
    statuses = _status_by_name(report)

    assert statuses["faster_whisper"] == "WARN"
    assert statuses["asr_provider"] == "PASS"
    assert statuses["asr_env_key"] == "PASS"


def test_doctor_reports_managed_whisper_readiness(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: managed_whisper}
asr_engines:
  - id: managed_whisper
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
    device: auto
    compute_type: auto
        """.strip(),
        encoding="utf-8",
    )
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")

    report = doctor_report(root_dir=tmp_path)
    check = next(item for item in report["checks"] if item["name"] == "faster_whisper")

    assert check["status"] == "WARN"
    assert check["code"] == "runtime_missing"
    assert check["details"]["kind"] == "local_worker"


def test_doctor_reports_config_load_failure(tmp_path: Path) -> None:
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    (tmp_path / "providers.yaml").write_text("providers:\n  - name: broken\n", encoding="utf-8")

    report = doctor_report(root_dir=tmp_path)

    assert report["status"] == "FAIL"
    assert any(item["name"] == "config_load" for item in report["checks"])
