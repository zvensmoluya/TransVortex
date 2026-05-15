from __future__ import annotations

import json
import math
import subprocess
from pathlib import Path
from typing import Any

from ..utils import write_json


TEXT_SUBTITLE_CODECS = {"subrip", "ass", "ssa", "webvtt", "mov_text"}


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def probe_audio(video_path: Path) -> dict:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        str(video_path),
    ]
    result = _run(cmd)
    return json.loads(result.stdout)


def _stream_tags(stream: dict[str, Any]) -> dict[str, str]:
    tags = stream.get("tags") or {}
    if not isinstance(tags, dict):
        return {}
    return {str(key).lower(): str(value) for key, value in tags.items()}


def _stream_disposition(stream: dict[str, Any]) -> dict[str, int]:
    disposition = stream.get("disposition") or {}
    if not isinstance(disposition, dict):
        return {}
    out: dict[str, int] = {}
    for key, value in disposition.items():
        try:
            out[str(key).lower()] = int(value)
        except (TypeError, ValueError):
            out[str(key).lower()] = 0
    return out


def list_subtitle_streams(video_path: Path) -> list[dict]:
    probe = probe_audio(video_path)
    streams = []
    for stream in probe.get("streams", []):
        if stream.get("codec_type") != "subtitle":
            continue
        tags = _stream_tags(stream)
        disposition = _stream_disposition(stream)
        codec = str(stream.get("codec_name") or "")
        streams.append(
            {
                "index": int(stream.get("index", -1)),
                "codec_name": codec,
                "language": tags.get("language", ""),
                "title": tags.get("title", ""),
                "default": bool(disposition.get("default", 0)),
                "forced": bool(disposition.get("forced", 0)),
                "supported": codec in TEXT_SUBTITLE_CODECS,
            }
        )
    return streams


def _normalize_language(value: str | None) -> str:
    raw = (value or "").strip().lower().replace("_", "-")
    aliases = {
        "jpn": "ja",
        "jp": "ja",
        "japanese": "ja",
        "eng": "en",
        "english": "en",
        "chi": "zh",
        "zho": "zh",
        "chs": "zh",
        "cht": "zh",
        "cn": "zh",
        "zh-cn": "zh",
        "zh-hans": "zh",
        "zh-tw": "zh",
        "zh-hant": "zh",
    }
    return aliases.get(raw, raw.split("-", 1)[0])


def select_subtitle_stream(
    streams: list[dict],
    *,
    source_lang: str,
    subtitle_track: str = "auto",
) -> dict | None:
    supported = [stream for stream in streams if stream.get("supported")]
    if subtitle_track and subtitle_track != "auto":
        try:
            wanted = int(subtitle_track)
        except ValueError:
            return None
        return next((stream for stream in supported if int(stream.get("index", -1)) == wanted), None)
    wanted_lang = _normalize_language(source_lang)
    matched = [
        stream
        for stream in supported
        if _normalize_language(str(stream.get("language", ""))) == wanted_lang
    ]
    if not matched:
        return None
    return sorted(matched, key=lambda stream: (not stream.get("default"), stream.get("index", 9999)))[0]


def extract_subtitle_stream(video_path: Path, output_srt: Path, *, stream_index: int) -> None:
    output_srt.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(video_path),
        "-map",
        f"0:{stream_index}",
        "-c:s",
        "srt",
        str(output_srt),
    ]
    _run(cmd)


def extract_audio(video_path: Path, output_audio: Path) -> dict:
    probe = probe_audio(video_path)
    streams = probe.get("streams", [])
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    if not audio_streams:
        raise RuntimeError(f"No audio stream found in {video_path}")
    codec = audio_streams[0].get("codec_name", "")
    copy_ok = codec in {"aac", "mp3"}
    output_audio.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-i", str(video_path), "-vn"]
    if copy_ok:
        cmd += ["-c:a", "copy"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "128k"]
    cmd.append(str(output_audio))
    _run(cmd)
    return {
        "audio_codec": codec,
        "copy_mode": copy_ok,
        "duration_seconds": float(probe.get("format", {}).get("duration", 0.0)),
    }


def split_audio_with_overlap(
    audio_path: Path,
    segments_dir: Path,
    *,
    chunk_seconds: int,
    overlap_seconds: int,
    duration_seconds: float,
) -> list[dict]:
    if chunk_seconds <= overlap_seconds:
        raise ValueError("chunk_seconds must be > overlap_seconds")
    step = chunk_seconds - overlap_seconds
    count = max(1, int(math.ceil(max(duration_seconds, 0.1) / step)))
    segments_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for idx in range(count):
        start = idx * step
        if start >= duration_seconds:
            break
        length = min(chunk_seconds, max(duration_seconds - start, 0.1))
        out_file = segments_dir / f"part_{idx:05d}.wav"
        cmd = [
            "ffmpeg",
            "-y",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(audio_path),
            "-t",
            f"{length:.3f}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(out_file),
        ]
        _run(cmd)
        manifest.append(
            {
                "segment_index": idx,
                "start": start,
                "duration": length,
                "path": str(out_file),
            }
        )
    write_json(segments_dir / "manifest.json", manifest)
    return manifest


def _trusted_region_for_window(
    *,
    start: float,
    duration: float,
    duration_seconds: float,
    overlap_seconds: int,
    has_previous: bool,
    has_next: bool,
) -> tuple[float, float]:
    half_overlap = max(overlap_seconds, 0) / 2.0
    trusted_start = start + half_overlap if has_previous else start
    trusted_end = start + duration - half_overlap if has_next else start + duration
    trusted_start = max(start, min(trusted_start, duration_seconds))
    trusted_end = max(trusted_start, min(trusted_end, duration_seconds))
    return trusted_start, trusted_end


def split_audio_for_asr(
    audio_path: Path,
    segments_dir: Path,
    *,
    mode: str,
    window_seconds: int,
    overlap_seconds: int,
    short_audio_seconds: int,
    duration_seconds: float,
) -> list[dict]:
    normalized_mode = mode.strip().lower()
    if normalized_mode not in {"auto", "fixed", "none"}:
        normalized_mode = "auto"
    if normalized_mode == "none" or duration_seconds <= max(short_audio_seconds, 0):
        effective_window = max(duration_seconds, 0.1)
        effective_overlap = 0
    else:
        effective_window = max(float(window_seconds), 0.1)
        effective_overlap = max(0, min(int(overlap_seconds), int(effective_window) - 1))
    if normalized_mode == "fixed":
        effective_window = max(float(window_seconds), 0.1)
        effective_overlap = max(0, min(int(overlap_seconds), int(effective_window) - 1))
    step = effective_window - effective_overlap
    count = max(1, int(math.ceil(max(duration_seconds, 0.1) / step)))
    segments_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    starts = []
    for idx in range(count):
        start = idx * step
        if start >= duration_seconds:
            break
        starts.append(start)
    for idx, start in enumerate(starts):
        length = min(effective_window, max(duration_seconds - start, 0.1))
        out_file = segments_dir / f"part_{idx:05d}.wav"
        cmd = [
            "ffmpeg",
            "-y",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(audio_path),
            "-t",
            f"{length:.3f}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(out_file),
        ]
        _run(cmd)
        trusted_start, trusted_end = _trusted_region_for_window(
            start=float(start),
            duration=float(length),
            duration_seconds=float(duration_seconds),
            overlap_seconds=effective_overlap,
            has_previous=idx > 0,
            has_next=idx < len(starts) - 1,
        )
        manifest.append(
            {
                "segment_index": idx,
                "start": float(start),
                "duration": float(length),
                "trusted_start": trusted_start,
                "trusted_end": trusted_end,
                "path": str(out_file),
            }
        )
    write_json(segments_dir / "manifest.json", manifest)
    return manifest
