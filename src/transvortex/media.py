from __future__ import annotations

import json
import math
import subprocess
from pathlib import Path

from .utils import write_json


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def probe_audio(video_path: Path) -> dict:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_name,codec_type",
        "-show_entries",
        "format=duration",
        "-of",
        "json",
        str(video_path),
    ]
    result = _run(cmd)
    return json.loads(result.stdout)


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
