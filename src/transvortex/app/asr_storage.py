from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from ..utils import read_json, write_json
from .asr_runtime import ASR_STORAGE_CONFIG_NAME, ASR_STORAGE_CONFIG_VERSION


class AsrStorageError(ValueError):
    pass


def save_asr_storage(
    *,
    config_root: Path,
    storage_root: Path,
    update_windows_registry: bool = False,
) -> Path:
    config = _absolute_directory(config_root, "config_root")
    storage = _absolute_directory(storage_root, "storage_root")
    if config.name.casefold() == "config" and (
        storage == config or config in storage.parents
    ):
        raise AsrStorageError("storage_root cannot be inside the Config directory")
    target = config / ASR_STORAGE_CONFIG_NAME
    write_json(
        target,
        {
            "schema_version": ASR_STORAGE_CONFIG_VERSION,
            "storage_root": str(storage),
        },
    )
    if update_windows_registry:
        try:
            write_windows_registry_location(storage)
        except OSError:
            # JSON remains authoritative for the running app. Registry state is
            # only a reinstall recovery hint.
            pass
    return target


def ensure_asr_storage(
    *,
    config_root: Path,
    default_storage_root: Path,
    update_windows_registry: bool = False,
) -> Path:
    config = _absolute_directory(config_root, "config_root")
    if config.name.casefold() != "config":
        raise AsrStorageError("config_root must be the dedicated Config directory")
    default_storage = _absolute_directory(default_storage_root, "default_storage_root")
    selected = default_storage
    target = config / ASR_STORAGE_CONFIG_NAME
    if target.is_file():
        try:
            payload = read_json(target)
            if not isinstance(payload, dict):
                raise ValueError("expected an object")
            if int(payload.get("schema_version") or 0) != ASR_STORAGE_CONFIG_VERSION:
                raise ValueError("unsupported schema")
            raw_root = str(payload.get("storage_root") or "").strip()
            selected = _absolute_directory(Path(raw_root), "storage_root")
        except (OSError, TypeError, ValueError, json.JSONDecodeError, AsrStorageError):
            selected = default_storage
    return save_asr_storage(
        config_root=config,
        storage_root=selected,
        update_windows_registry=update_windows_registry,
    )


def write_windows_registry_location(storage_root: Path) -> None:
    if os.name != "nt":
        return
    import winreg

    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\TransVortex") as key:
        winreg.SetValueEx(key, "AsrStorageLocation", 0, winreg.REG_SZ, str(storage_root))


def _absolute_directory(path: Path, field: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise AsrStorageError(f"{field} must be absolute")
    normalized = Path(os.path.abspath(candidate))
    if normalized == normalized.parent:
        raise AsrStorageError(f"{field} cannot be a filesystem root")
    return normalized


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Save the installed app ASR storage location.")
    parser.add_argument("--config-root", type=Path, required=True)
    parser.add_argument("--default-storage-root", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        ensure_asr_storage(
            config_root=args.config_root,
            default_storage_root=args.default_storage_root,
            update_windows_registry=True,
        )
    except (OSError, AsrStorageError) as exc:
        print(str(exc))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
