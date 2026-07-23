from __future__ import annotations

import json
from pathlib import Path

import pytest

from transvortex.app.asr_storage import (
    AsrStorageError,
    ensure_asr_storage,
    main,
    save_asr_storage,
)


def test_save_asr_storage_writes_location_config(tmp_path: Path) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    storage_root = tmp_path / "TransVortexResources"

    target = save_asr_storage(
        config_root=config_root,
        storage_root=storage_root,
    )

    assert json.loads(target.read_text(encoding="utf-8")) == {
        "schema_version": 1,
        "storage_root": str(storage_root),
    }


def test_ensure_asr_storage_preserves_existing_selection(tmp_path: Path) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    existing_root = tmp_path / "ExistingResources"
    suggested_root = tmp_path / "NewInstallResources"
    save_asr_storage(config_root=config_root, storage_root=existing_root)

    target = ensure_asr_storage(
        config_root=config_root,
        default_storage_root=suggested_root,
    )

    assert json.loads(target.read_text(encoding="utf-8"))["storage_root"] == str(
        existing_root
    )


def test_save_asr_storage_rejects_relative_root_and_config_children(
    tmp_path: Path,
) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    with pytest.raises(AsrStorageError, match="must be absolute"):
        save_asr_storage(config_root=config_root, storage_root=Path("relative"))
    with pytest.raises(AsrStorageError, match="inside the Config"):
        save_asr_storage(
            config_root=config_root,
            storage_root=config_root / "Resources",
        )


def test_asr_storage_cli_reports_invalid_config_root(tmp_path: Path) -> None:
    exit_code = main(
        [
            "--config-root",
            str(tmp_path / "TransVortex" / "Other"),
            "--default-storage-root",
            str(tmp_path / "TransVortexResources"),
        ]
    )

    assert exit_code == 2
