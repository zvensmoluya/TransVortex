from __future__ import annotations

import configparser
import json
from pathlib import Path

import pytest

from transvortex.app.uninstall_cleanup import (
    UninstallCleanupError,
    UninstallCleanupOptions,
    cleanup_uninstall_data,
    inspect_uninstall_data,
    main,
)


def _write(path: Path, content: bytes = b"data") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def test_inspection_reports_managed_resources_without_reading_file_contents(tmp_path: Path) -> None:
    app_root = tmp_path / "TransVortex"
    credential_file = tmp_path / ".transvortex" / "auth.json"
    _write(app_root / "Components" / "whisper" / "component.json", b"1234")
    _write(app_root / "Models" / "faster-whisper" / "small" / "model.bin", b"123456")
    _write(app_root / "Workspace" / "Tasks" / "task-1" / "result.srt", b"123")
    _write(credential_file, b'{"credentials":{"provider":"example-token"}}')

    report = inspect_uninstall_data(app_data_root=app_root, credential_file=credential_file)

    assert report["ok"] is True
    assert report["asr_storage_root"] == str(app_root)
    assert report["asr_resources_present"] is True
    assert report["asr_resource_bytes"] == 10
    assert report["settings_present"] is False
    assert report["tasks_present"] is True
    assert report["credentials_present"] is True


def test_asr_cleanup_removes_only_managed_children_from_default_and_custom_roots(tmp_path: Path) -> None:
    app_root = tmp_path / "TransVortex"
    custom_root = tmp_path / "ASR Resources"
    external_model = tmp_path / "customer-model" / "model.bin"
    credential_file = tmp_path / ".transvortex" / "auth.json"
    config_file = app_root / "Config" / "asr_storage.json"
    config_file.parent.mkdir(parents=True)
    config_file.write_text(
        json.dumps({"schema_version": 1, "storage_root": str(custom_root)}),
        encoding="utf-8",
    )
    _write(custom_root / "Components" / "runtime" / "component.json")
    _write(custom_root / "Models" / "faster-whisper" / "small" / "model.bin")
    _write(custom_root / "Downloads" / "ASR" / "model.bin.part")
    _write(app_root / "Components" / "orphan" / "component.json")
    custom_sentinel = _write(custom_root / "keep-user-file.txt")
    external_sentinel = _write(external_model)

    report = cleanup_uninstall_data(
        app_data_root=app_root,
        credential_file=credential_file,
        options=UninstallCleanupOptions(remove_asr_resources=True),
    )

    assert report["ok"] is True
    assert not (custom_root / "Components").exists()
    assert not (custom_root / "Models" / "faster-whisper").exists()
    assert not (custom_root / "Downloads" / "ASR").exists()
    assert not (app_root / "Components").exists()
    assert custom_sentinel.read_bytes() == b"data"
    assert external_sentinel.read_bytes() == b"data"
    assert config_file.is_file()


def test_cleanup_keeps_each_user_data_category_independent(tmp_path: Path) -> None:
    app_root = tmp_path / "TransVortex"
    credential_file = tmp_path / ".transvortex" / "auth.json"
    _write(app_root / "Config" / "pipeline.yaml")
    _write(app_root / "Workspace" / "Tasks" / "task-1" / "result.srt")
    _write(app_root / "Workspace" / "Cache" / "task-1.wav")
    resource = _write(app_root / "Models" / "faster-whisper" / "small" / "model.bin")
    app_sentinel = _write(app_root / "keep-user-file.txt")
    _write(credential_file, b'{"credentials":{"provider":"example-token"}}')
    credential_sentinel = _write(credential_file.parent / "keep-cli-file.txt")

    report = cleanup_uninstall_data(
        app_data_root=app_root,
        credential_file=credential_file,
        options=UninstallCleanupOptions(
            remove_settings=True,
            remove_tasks=True,
            remove_credentials=True,
        ),
    )

    assert report["ok"] is True
    assert not (app_root / "Config").exists()
    assert not (app_root / "Workspace").exists()
    assert not credential_file.exists()
    assert resource.is_file()
    assert app_sentinel.read_bytes() == b"data"
    assert credential_sentinel.read_bytes() == b"data"


def test_invalid_storage_config_never_expands_the_cleanup_scope(tmp_path: Path) -> None:
    app_root = tmp_path / "TransVortex"
    credential_file = tmp_path / ".transvortex" / "auth.json"
    config_file = app_root / "Config" / "asr_storage.json"
    config_file.parent.mkdir(parents=True)
    config_file.write_text('{"schema_version":1,"storage_root":"C:\\\\"}', encoding="utf-8")
    default_resource = _write(app_root / "Components" / "runtime" / "component.json")
    outside_resource = _write(tmp_path / "Components" / "keep.txt")

    report = cleanup_uninstall_data(
        app_data_root=app_root,
        credential_file=credential_file,
        options=UninstallCleanupOptions(remove_asr_resources=True),
    )

    assert report["ok"] is True
    assert report["warnings"]
    assert not default_resource.exists()
    assert outside_resource.read_bytes() == b"data"
    assert config_file.is_file()


def test_cleanup_rejects_a_non_dedicated_app_data_root(tmp_path: Path) -> None:
    with pytest.raises(UninstallCleanupError, match="dedicated TransVortex"):
        inspect_uninstall_data(
            app_data_root=tmp_path / "OtherApp",
            credential_file=tmp_path / ".transvortex" / "auth.json",
        )


def test_cli_writes_a_unicode_ini_report_for_nsis(tmp_path: Path) -> None:
    app_root = tmp_path / "TransVortex"
    credential_file = tmp_path / ".transvortex" / "auth.json"
    report_file = tmp_path / "卸载报告.ini"
    _write(app_root / "Models" / "faster-whisper" / "small" / "model.bin", b"model")

    exit_code = main(
        [
            "--inspect",
            "--app-data-root",
            str(app_root),
            "--credential-file",
            str(credential_file),
            "--report-ini",
            str(report_file),
        ]
    )

    parser = configparser.ConfigParser(interpolation=None)
    parser.read(report_file, encoding="utf-16")
    assert exit_code == 0
    assert parser["Summary"]["status"] == "ok"
    assert parser["Summary"]["asr_present"] == "1"
    assert parser["Summary"]["asr_size"] == "5 B"
