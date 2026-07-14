from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


MEDIA_TOOLS_DIR_ENV = "TRANSVORTEX_MEDIA_TOOLS_DIR"
SUPPORTED_MEDIA_EXECUTABLES = {"ffmpeg", "ffprobe"}


def _executable_name(name: str) -> str:
    return f"{name}.exe" if os.name == "nt" else name


def _bundled_media_tools_dir() -> Path | None:
    executable = Path(sys.executable).resolve()
    if len(executable.parents) < 3:
        return None
    app_root = executable.parents[2]
    if not (app_root / "runtime" / "app_runtime.json").is_file():
        return None
    return app_root / "tools" / "ffmpeg" / "bin"


def resolve_media_executable(name: str) -> str | None:
    """Resolve an FFmpeg executable from the release bundle or development PATH."""
    normalized = str(name).strip().lower()
    if normalized not in SUPPORTED_MEDIA_EXECUTABLES:
        raise ValueError(f"Unsupported media executable: {name}")

    configured_dir = os.environ.get(MEDIA_TOOLS_DIR_ENV, "").strip()
    if configured_dir:
        configured = Path(configured_dir).expanduser() / _executable_name(normalized)
        return str(configured.resolve()) if configured.is_file() else None

    bundled_dir = _bundled_media_tools_dir()
    if bundled_dir is not None:
        bundled = bundled_dir / _executable_name(normalized)
        return str(bundled.resolve()) if bundled.is_file() else None

    return shutil.which(normalized)
