from __future__ import annotations

from pathlib import Path
from typing import Any

from ..core.media import list_subtitle_streams, select_subtitle_stream


SUBTITLE_EXTENSIONS = {".srt", ".ass", ".ssa", ".vtt", ".lrc"}
AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".flac", ".aac", ".ogg", ".opus"}


def inspect_media_source(
    input_path: Path,
    *,
    source_lang: str = "auto",
    source_mode: str = "auto",
    subtitle_track: str = "auto",
) -> dict[str, Any]:
    path = Path(input_path).expanduser().resolve()
    suffix = path.suffix.lower()
    if suffix in SUBTITLE_EXTENSIONS:
        return {
            "input": str(path),
            "kind": "subtitle",
            "source_mode": "subtitle_file",
            "needs_asr": False,
            "subtitle_streams": [],
            "selected_subtitle_stream": None,
        }
    if suffix in AUDIO_EXTENSIONS:
        return {
            "input": str(path),
            "kind": "audio",
            "source_mode": "asr",
            "needs_asr": True,
            "subtitle_streams": [],
            "selected_subtitle_stream": None,
        }
    if not path.is_file():
        raise FileNotFoundError(f"Media file not found: {path}")
    normalized_mode = str(source_mode or "auto").strip().lower()
    if normalized_mode not in {"auto", "asr", "embedded_subtitle"}:
        raise ValueError(f"unsupported_source_mode:{source_mode}")
    streams = list_subtitle_streams(path)
    selected = select_subtitle_stream(
        streams,
        source_lang=source_lang,
        subtitle_track=subtitle_track,
    )
    if normalized_mode == "asr":
        selected = None
    elif normalized_mode == "embedded_subtitle" and selected is None:
        return {
            "input": str(path),
            "kind": "video",
            "source_mode": "embedded_subtitle",
            "needs_asr": False,
            "available": False,
            "code": "subtitle_track_unavailable",
            "subtitle_streams": streams,
            "selected_subtitle_stream": None,
        }
    effective_mode = "embedded_subtitle" if selected is not None else "asr"
    return {
        "input": str(path),
        "kind": "video",
        "source_mode": effective_mode,
        "needs_asr": effective_mode == "asr",
        "available": True,
        "code": "ready",
        "subtitle_streams": streams,
        "selected_subtitle_stream": selected,
    }
