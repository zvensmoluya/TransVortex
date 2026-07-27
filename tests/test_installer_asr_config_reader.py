from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / "installer" / "windows" / "resolve_asr_storage_config.py"


def test_installer_reader_returns_authoritative_asr_storage_root(
    tmp_path: Path,
) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    config_root.mkdir(parents=True)
    storage_root = tmp_path / "selected-resources"
    (config_root / "asr_storage.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "storage_root": str(storage_root),
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    output_ini = tmp_path / "installer" / "asr-storage.ini"

    result = subprocess.run(
        [
            sys.executable,
            str(READER),
            "--config-root",
            str(config_root),
            "--output-ini",
            str(output_ini),
        ],
        check=False,
    )

    assert result.returncode == 0
    assert output_ini.read_text(encoding="utf-16") == (
        f"[Storage]\nRoot={storage_root}\n"
    )


def test_installer_reader_rejects_invalid_or_nested_storage_root(
    tmp_path: Path,
) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    config_root.mkdir(parents=True)
    output_ini = tmp_path / "asr-storage.ini"
    output_ini.write_text("stale", encoding="utf-8")
    (config_root / "asr_storage.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "storage_root": str(config_root / "Resources"),
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            str(READER),
            "--config-root",
            str(config_root),
            "--output-ini",
            str(output_ini),
        ],
        check=False,
    )

    assert result.returncode == 2
    assert not output_ini.exists()
