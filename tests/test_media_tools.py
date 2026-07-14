from __future__ import annotations

import os
from pathlib import Path

from transvortex.core import media_tools


def _binary_name(name: str) -> str:
    return f"{name}.exe" if os.name == "nt" else name


def test_resolve_media_executable_prefers_configured_directory(tmp_path: Path, monkeypatch) -> None:
    tools_dir = tmp_path / "media-tools"
    tools_dir.mkdir()
    ffmpeg = tools_dir / _binary_name("ffmpeg")
    ffmpeg.write_bytes(b"binary")
    monkeypatch.setenv(media_tools.MEDIA_TOOLS_DIR_ENV, str(tools_dir))
    monkeypatch.setattr(media_tools.shutil, "which", lambda _name: "PATH-FFMPEG")

    assert media_tools.resolve_media_executable("ffmpeg") == str(ffmpeg.resolve())


def test_invalid_configured_directory_does_not_fall_back_to_path(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv(media_tools.MEDIA_TOOLS_DIR_ENV, str(tmp_path / "missing"))
    monkeypatch.setattr(media_tools.shutil, "which", lambda _name: "PATH-FFMPEG")

    assert media_tools.resolve_media_executable("ffmpeg") is None


def test_resolve_media_executable_finds_fixed_app_layout(tmp_path: Path, monkeypatch) -> None:
    python = tmp_path / "runtime" / "python" / _binary_name("python")
    python.parent.mkdir(parents=True)
    python.write_bytes(b"")
    (tmp_path / "runtime" / "app_runtime.json").write_text("{}", encoding="utf-8")
    tools_dir = tmp_path / "tools" / "ffmpeg" / "bin"
    tools_dir.mkdir(parents=True)
    ffprobe = tools_dir / _binary_name("ffprobe")
    ffprobe.write_bytes(b"binary")
    monkeypatch.delenv(media_tools.MEDIA_TOOLS_DIR_ENV, raising=False)
    monkeypatch.setattr(media_tools.sys, "executable", str(python))
    monkeypatch.setattr(media_tools.shutil, "which", lambda _name: None)

    assert media_tools.resolve_media_executable("ffprobe") == str(ffprobe.resolve())


def test_resolve_media_executable_rejects_unrelated_tools() -> None:
    try:
        media_tools.resolve_media_executable("python")
    except ValueError as exc:
        assert "Unsupported media executable" in str(exc)
    else:
        raise AssertionError("Expected unsupported media executable to be rejected")
