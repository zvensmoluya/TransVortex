from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


ASR_STORAGE_CONFIG_NAME = "asr_storage.json"
ASR_STORAGE_CONFIG_VERSION = 1


class StorageConfigError(ValueError):
    pass


def resolve_storage_root(config_root: Path) -> Path:
    config = _absolute_directory(config_root, "config_root")
    if config.name.casefold() != "config":
        raise StorageConfigError("config_root must be the dedicated Config directory")
    payload = json.loads(
        (config / ASR_STORAGE_CONFIG_NAME).read_text(encoding="utf-8-sig")
    )
    if not isinstance(payload, dict):
        raise StorageConfigError("ASR storage config must contain an object")
    if int(payload.get("schema_version") or 0) != ASR_STORAGE_CONFIG_VERSION:
        raise StorageConfigError("unsupported ASR storage config version")
    raw_root = payload.get("storage_root")
    if not isinstance(raw_root, str) or not raw_root.strip():
        raise StorageConfigError("storage_root must be a non-empty string")
    if any(ord(character) < 32 for character in raw_root):
        raise StorageConfigError("storage_root cannot contain control characters")
    storage = _absolute_directory(Path(raw_root), "storage_root")
    if storage == config or config in storage.parents:
        raise StorageConfigError("storage_root cannot be inside the Config directory")
    return storage


def write_nsis_ini(path: Path, storage_root: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"[Storage]\nRoot={storage_root}\n",
        encoding="utf-16",
    )


def _absolute_directory(path: Path, field: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise StorageConfigError(f"{field} must be absolute")
    normalized = Path(os.path.abspath(candidate))
    if normalized == normalized.parent:
        raise StorageConfigError(f"{field} cannot be a filesystem root")
    return normalized


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve the authoritative ASR storage config for an installer upgrade."
    )
    parser.add_argument("--config-root", type=Path, required=True)
    parser.add_argument("--output-ini", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.output_ini.exists():
            args.output_ini.unlink()
        storage_root = resolve_storage_root(args.config_root)
        write_nsis_ini(args.output_ini, storage_root)
    except (OSError, TypeError, ValueError):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
