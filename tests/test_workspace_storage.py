from __future__ import annotations

import json
from pathlib import Path

import pytest

from transvortex.app.workspace_storage import (
    WORKSPACE_MARKER_NAME,
    WorkspaceStorageError,
    main,
    save_workspace_storage,
)


def test_save_workspace_storage_writes_utf8_config(tmp_path: Path) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    workspace_root = tmp_path / "字幕任务资料"

    target = save_workspace_storage(
        config_root=config_root,
        workspace_root=workspace_root,
    )

    assert json.loads(target.read_text(encoding="utf-8")) == {
        "schema_version": 1,
        "workspace_root": str(workspace_root),
    }
    assert json.loads(
        (workspace_root / WORKSPACE_MARKER_NAME).read_text(encoding="utf-8")
    ) == {"schema_version": 1, "app_id": "TransVortex"}


def test_save_workspace_storage_rejects_relative_or_config_child_paths(
    tmp_path: Path,
) -> None:
    config_root = tmp_path / "TransVortex" / "Config"
    with pytest.raises(WorkspaceStorageError, match="must be absolute"):
        save_workspace_storage(
            config_root=config_root,
            workspace_root=Path("relative"),
        )
    with pytest.raises(WorkspaceStorageError, match="inside the Config"):
        save_workspace_storage(
            config_root=config_root,
            workspace_root=config_root / "Workspace",
        )


def test_workspace_storage_cli_reports_invalid_root(tmp_path: Path) -> None:
    exit_code = main(
        [
            "--config-root",
            str(tmp_path / "TransVortex" / "Other"),
            "--workspace-root",
            str(tmp_path / "Workspace"),
        ]
    )

    assert exit_code == 2
