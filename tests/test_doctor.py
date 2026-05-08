from __future__ import annotations

import shutil
from pathlib import Path

from transvortex.doctor import doctor_report, format_doctor_report


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  mode: local
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
    monkeypatch.setattr("transvortex.doctor.importlib.util.find_spec", lambda name: object())

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


def test_doctor_reports_missing_key_with_legacy_hint(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    (tmp_path / ".env").write_text("OPENAI_API_KEY=old\nVECTORENGINE_API_KEY=old\n", encoding="utf-8")
    monkeypatch.delenv("TVX_MODEL_API_KEY", raising=False)
    monkeypatch.setattr(shutil, "which", lambda name: f"C:/bin/{name}.exe")
    monkeypatch.setattr("transvortex.doctor.importlib.util.find_spec", lambda name: object())

    report = doctor_report(root_dir=tmp_path)
    key_check = next(item for item in report["checks"] if item["name"] == "provider_env_key")

    assert report["status"] == "FAIL"
    assert key_check["code"] == "missing_env"
    assert key_check["details"]["env_key"] == "TVX_MODEL_API_KEY"
    assert key_check["details"]["legacy_keys_present"] == ["OPENAI_API_KEY", "VECTORENGINE_API_KEY"]
    assert "TVX_MODEL_API_KEY" in key_check["hint_zh"]


def test_doctor_reports_missing_binary_and_asr_dependency(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TVX_MODEL_API_KEY", "key")
    monkeypatch.setattr(shutil, "which", lambda name: None)
    monkeypatch.setattr("transvortex.doctor.importlib.util.find_spec", lambda name: None)

    report = doctor_report(root_dir=tmp_path)
    statuses = _status_by_name(report)

    assert report["status"] == "FAIL"
    assert statuses["ffmpeg"] == "FAIL"
    assert statuses["ffprobe"] == "FAIL"
    assert statuses["faster_whisper"] == "FAIL"


def test_doctor_reports_config_load_failure(tmp_path: Path) -> None:
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    (tmp_path / "providers.yaml").write_text("providers:\n  - name: broken\n", encoding="utf-8")

    report = doctor_report(root_dir=tmp_path)

    assert report["status"] == "FAIL"
    assert any(item["name"] == "config_load" for item in report["checks"])
