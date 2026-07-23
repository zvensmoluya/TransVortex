from __future__ import annotations

import argparse
import os
from pathlib import Path

from ..utils import write_json


WORKSPACE_STORAGE_CONFIG_VERSION = 1
WORKSPACE_STORAGE_CONFIG_NAME = "workspace_storage.json"
WORKSPACE_MARKER_NAME = ".transvortex-workspace.json"


class WorkspaceStorageError(ValueError):
    pass


def save_workspace_storage(
    *,
    config_root: Path,
    workspace_root: Path,
    update_windows_registry: bool = False,
) -> Path:
    config = _absolute_directory(config_root, "config_root")
    workspace = _absolute_directory(workspace_root, "workspace_root")
    if config.name.casefold() != "config":
        raise WorkspaceStorageError("config_root must be the dedicated Config directory")
    if workspace == config or config in workspace.parents:
        raise WorkspaceStorageError("workspace_root cannot be inside the Config directory")
    write_json(
        workspace / WORKSPACE_MARKER_NAME,
        {
            "schema_version": WORKSPACE_STORAGE_CONFIG_VERSION,
            "app_id": "TransVortex",
        },
    )
    target = config / WORKSPACE_STORAGE_CONFIG_NAME
    write_json(
        target,
        {
            "schema_version": WORKSPACE_STORAGE_CONFIG_VERSION,
            "workspace_root": str(workspace),
        },
    )
    if update_windows_registry:
        try:
            _write_windows_registry_location(workspace)
        except OSError:
            # The JSON config is authoritative for the running app. A locked
            # HKCU registry entry must not roll back an otherwise safe switch.
            pass
    return target


def _write_windows_registry_location(workspace_root: Path) -> None:
    if os.name != "nt":
        return
    import winreg

    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\TransVortex") as key:
        winreg.SetValueEx(key, "WorkspaceLocation", 0, winreg.REG_SZ, str(workspace_root))


def _absolute_directory(path: Path, field: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise WorkspaceStorageError(f"{field} must be absolute")
    normalized = Path(os.path.abspath(candidate))
    if normalized == normalized.parent:
        raise WorkspaceStorageError(f"{field} cannot be a filesystem root")
    return normalized


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Save the installed app workspace location.")
    parser.add_argument("--config-root", type=Path, required=True)
    parser.add_argument("--workspace-root", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        save_workspace_storage(
            config_root=args.config_root,
            workspace_root=args.workspace_root,
        )
    except (OSError, WorkspaceStorageError) as exc:
        print(str(exc))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
