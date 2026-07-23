from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ASR_STORAGE_CONFIG_VERSION = 1
WORKSPACE_STORAGE_CONFIG_VERSION = 1
WORKSPACE_MARKER_NAME = ".transvortex-workspace.json"


class UninstallCleanupError(RuntimeError):
    pass


@dataclass(frozen=True)
class UninstallCleanupOptions:
    remove_asr_resources: bool = False
    remove_settings: bool = False
    remove_tasks: bool = False
    remove_credentials: bool = False


def inspect_uninstall_data(*, app_data_root: Path, credential_file: Path) -> dict[str, object]:
    app_root = _validated_app_data_root(app_data_root)
    credential_path = _validated_absolute_file(credential_file, "credential_file")
    storage_root, storage_warning = _configured_asr_storage_root(app_root)
    workspace_root, workspace_warning = _configured_workspace_root(app_root)
    asr_targets = _asr_resource_targets(app_root, storage_root)
    task_targets = _task_targets(app_root, workspace_root)
    asr_bytes = sum(_path_size(path) for path in asr_targets)
    task_bytes = sum(_path_size(path) for path in task_targets)
    config_root = app_root / "Config"
    warnings = [value for value in (storage_warning, workspace_warning) if value]
    return {
        "ok": not warnings,
        "warning": "；".join(warnings),
        "app_data_root": str(app_root),
        "asr_storage_root": str(storage_root),
        "workspace_root": str(workspace_root),
        "asr_resource_bytes": asr_bytes,
        "asr_resource_size_label": _format_bytes(asr_bytes),
        "asr_resources_present": any(_path_exists(path) for path in asr_targets),
        "settings_present": _path_exists(config_root),
        "tasks_present": any(_path_exists(path) for path in task_targets),
        "task_bytes": task_bytes,
        "task_size_label": _format_bytes(task_bytes),
        "credentials_present": _path_exists(credential_path),
        "credential_file": str(credential_path),
    }


def cleanup_uninstall_data(
    *,
    app_data_root: Path,
    credential_file: Path,
    options: UninstallCleanupOptions,
) -> dict[str, object]:
    inspection = inspect_uninstall_data(
        app_data_root=app_data_root,
        credential_file=credential_file,
    )
    app_root = Path(str(inspection["app_data_root"]))
    credential_path = Path(str(inspection["credential_file"]))
    storage_root = Path(str(inspection["asr_storage_root"]))
    workspace_root = Path(str(inspection["workspace_root"]))
    removed: list[str] = []
    errors: list[str] = []

    # Resolve the configured ASR root before Config can be removed.
    if options.remove_asr_resources:
        for target in _asr_resource_targets(app_root, storage_root):
            _remove_target(target, removed=removed, errors=errors)
        _remove_empty_directories(
            (
                storage_root / "Models",
                storage_root / "Downloads",
                app_root / "Models",
                app_root / "Downloads",
            )
        )

    if options.remove_tasks:
        for target in _task_targets(app_root, workspace_root):
            _remove_target(target, removed=removed, errors=errors)
        _remove_empty_directories((workspace_root, app_root / "Workspace"))

    if options.remove_settings:
        _remove_target(app_root / "Config", removed=removed, errors=errors)

    if options.remove_credentials:
        _remove_target(credential_path, removed=removed, errors=errors)
        _remove_empty_directories((credential_path.parent,))

    _remove_empty_directories((app_root,))
    warnings = [str(inspection["warning"])] if inspection["warning"] else []
    return {
        **inspection,
        "ok": not errors,
        "removed": removed,
        "errors": errors,
        "warnings": warnings,
        "remove_asr_resources": options.remove_asr_resources,
        "remove_settings": options.remove_settings,
        "remove_tasks": options.remove_tasks,
        "remove_credentials": options.remove_credentials,
    }


def _validated_app_data_root(path: Path) -> Path:
    root = _validated_absolute_directory(path, "app_data_root")
    if root.name.casefold() != "transvortex":
        raise UninstallCleanupError("app_data_root must be the dedicated TransVortex directory")
    return root


def _validated_absolute_directory(path: Path, field: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise UninstallCleanupError(f"{field} must be absolute")
    normalized = Path(os.path.abspath(candidate))
    if normalized == normalized.parent:
        raise UninstallCleanupError(f"{field} cannot be a filesystem root")
    return normalized


def _validated_absolute_file(path: Path, field: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise UninstallCleanupError(f"{field} must be absolute")
    return Path(os.path.abspath(candidate))


def _configured_asr_storage_root(app_root: Path) -> tuple[Path, str]:
    config_file = app_root / "Config" / "asr_storage.json"
    if not config_file.is_file():
        return app_root, ""
    try:
        payload = json.loads(config_file.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("expected an object")
        if int(payload.get("schema_version") or 0) != ASR_STORAGE_CONFIG_VERSION:
            raise ValueError("unsupported schema")
        raw_root = str(payload.get("storage_root") or "").strip()
        if not raw_root:
            raise ValueError("storage_root is empty")
        storage_root = _validated_absolute_directory(Path(raw_root), "storage_root")
        return storage_root, ""
    except (OSError, TypeError, ValueError, json.JSONDecodeError, UninstallCleanupError) as exc:
        return app_root, f"无法读取自选识别资源位置；仅检查默认位置：{exc}"


def _configured_workspace_root(app_root: Path) -> tuple[Path, str]:
    default_root = app_root / "Workspace"
    config_file = app_root / "Config" / "workspace_storage.json"
    if not config_file.is_file():
        return default_root, ""
    try:
        payload = json.loads(config_file.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("expected an object")
        if int(payload.get("schema_version") or 0) != WORKSPACE_STORAGE_CONFIG_VERSION:
            raise ValueError("unsupported schema")
        raw_root = str(payload.get("workspace_root") or "").strip()
        if not raw_root:
            raise ValueError("workspace_root is empty")
        workspace_root = _validated_absolute_directory(Path(raw_root), "workspace_root")
        if os.path.normcase(str(workspace_root)) != os.path.normcase(str(default_root)):
            marker = json.loads(
                (workspace_root / WORKSPACE_MARKER_NAME).read_text(encoding="utf-8")
            )
            if not isinstance(marker, dict):
                raise ValueError("workspace marker must be an object")
            if int(marker.get("schema_version") or 0) != WORKSPACE_STORAGE_CONFIG_VERSION:
                raise ValueError("workspace marker schema is unsupported")
            if marker.get("app_id") != "TransVortex":
                raise ValueError("workspace marker ownership does not match")
        return workspace_root, ""
    except (OSError, TypeError, ValueError, json.JSONDecodeError, UninstallCleanupError) as exc:
        return default_root, f"无法读取工作数据位置；仅检查默认位置：{exc}"


def _asr_resource_targets(app_root: Path, storage_root: Path) -> tuple[Path, ...]:
    roots = [app_root]
    if os.path.normcase(str(storage_root)) != os.path.normcase(str(app_root)):
        roots.append(storage_root)
    targets: list[Path] = []
    for root in roots:
        targets.extend(
            (
                _safe_child(root, "Components"),
                _safe_child(root, "Models", "faster-whisper"),
                _safe_child(root, "Downloads", "ASR"),
            )
        )
    return tuple(targets)


def _task_targets(app_root: Path, workspace_root: Path) -> tuple[Path, ...]:
    roots = [app_root / "Workspace"]
    if os.path.normcase(str(workspace_root)) != os.path.normcase(str(roots[0])):
        roots.append(workspace_root)
    targets: list[Path] = []
    for root in roots:
        targets.extend((_safe_child(root, "Tasks"), _safe_child(root, "Cache")))
    return tuple(targets)


def _safe_child(root: Path, *parts: str) -> Path:
    root_text = os.path.abspath(root)
    target = Path(os.path.abspath(root.joinpath(*parts)))
    try:
        common = os.path.commonpath((root_text, str(target)))
    except ValueError as exc:
        raise UninstallCleanupError(f"cleanup target is outside its root: {target}") from exc
    if os.path.normcase(common) != os.path.normcase(root_text) or target == Path(root_text):
        raise UninstallCleanupError(f"cleanup target is outside its root: {target}")
    return target


def _path_exists(path: Path) -> bool:
    return path.exists() or path.is_symlink() or _is_junction(path)


def _is_junction(path: Path) -> bool:
    checker = getattr(path, "is_junction", None)
    if checker is None:
        return False
    try:
        return bool(checker())
    except OSError:
        return False


def _path_size(path: Path) -> int:
    if not _path_exists(path):
        return 0
    if path.is_symlink() or _is_junction(path):
        try:
            return int(path.lstat().st_size)
        except OSError:
            return 0
    if path.is_file():
        try:
            return int(path.stat().st_size)
        except OSError:
            return 0
    total = 0
    stack = [path]
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        if entry.is_symlink():
                            total += int(entry.stat(follow_symlinks=False).st_size)
                        elif entry.is_dir(follow_symlinks=False):
                            stack.append(Path(entry.path))
                        else:
                            total += int(entry.stat(follow_symlinks=False).st_size)
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def _remove_target(path: Path, *, removed: list[str], errors: list[str]) -> None:
    if not _path_exists(path):
        return
    try:
        if path.is_symlink():
            path.unlink()
        elif _is_junction(path):
            path.rmdir()
        elif path.is_dir():
            shutil.rmtree(path, onerror=_retry_readonly_removal)
        else:
            path.unlink()
        removed.append(str(path))
    except OSError as exc:
        errors.append(f"{path}: {exc}")


def _retry_readonly_removal(function: object, path: str, _error: object) -> None:
    os.chmod(path, stat.S_IWRITE)
    function(path)  # type: ignore[operator]


def _remove_empty_directories(paths: Iterable[Path]) -> None:
    for path in paths:
        try:
            path.rmdir()
        except OSError:
            continue


def _format_bytes(value: int) -> str:
    size = max(int(value), 0)
    units = ("B", "KB", "MB", "GB", "TB")
    amount = float(size)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(amount)} {unit}"
            return f"{amount:.1f} {unit}"
        amount /= 1024
    return f"{size} B"


def _write_ini_report(path: Path, report: dict[str, object]) -> None:
    path = _validated_absolute_file(path, "report_ini")
    path.parent.mkdir(parents=True, exist_ok=True)
    errors = [str(value) for value in report.get("errors", [])]
    warnings = [str(value) for value in report.get("warnings", [])]
    warning = str(report.get("warning") or "")
    if warning and warning not in warnings:
        warnings.append(warning)
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    parser["Summary"] = {
        "status": "ok" if bool(report.get("ok")) else "error",
        "message": "；".join(errors or warnings),
        "asr_root": str(report.get("asr_storage_root") or ""),
        "workspace_root": str(report.get("workspace_root") or ""),
        "asr_size": str(report.get("asr_resource_size_label") or "0 B"),
        "asr_present": "1" if bool(report.get("asr_resources_present")) else "0",
        "settings_present": "1" if bool(report.get("settings_present")) else "0",
        "tasks_present": "1" if bool(report.get("tasks_present")) else "0",
        "task_size": str(report.get("task_size_label") or "0 B"),
        "credentials_present": "1" if bool(report.get("credentials_present")) else "0",
        "removed_count": str(len(report.get("removed", []))),
    }
    with path.open("w", encoding="utf-16", newline="") as handle:
        parser.write(handle)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect or remove TransVortex user data during uninstall.")
    parser.add_argument("--app-data-root", type=Path, required=True)
    parser.add_argument("--credential-file", type=Path, required=True)
    parser.add_argument("--report-ini", type=Path, required=True)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--remove-asr-resources", action="store_true")
    parser.add_argument("--remove-settings", action="store_true")
    parser.add_argument("--remove-tasks", action="store_true")
    parser.add_argument("--remove-credentials", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.inspect:
            report = inspect_uninstall_data(
                app_data_root=args.app_data_root,
                credential_file=args.credential_file,
            )
        else:
            report = cleanup_uninstall_data(
                app_data_root=args.app_data_root,
                credential_file=args.credential_file,
                options=UninstallCleanupOptions(
                    remove_asr_resources=args.remove_asr_resources,
                    remove_settings=args.remove_settings,
                    remove_tasks=args.remove_tasks,
                    remove_credentials=args.remove_credentials,
                ),
            )
        _write_ini_report(args.report_ini, report)
        return 0 if bool(report.get("ok")) else 2
    except (OSError, UninstallCleanupError) as exc:
        report = {"ok": False, "errors": [str(exc)]}
        try:
            _write_ini_report(args.report_ini, report)
        except (OSError, UninstallCleanupError):
            pass
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
