from __future__ import annotations

import json
import math
import re
import subprocess
from pathlib import Path
from typing import Any

from ..utils import write_json


TEXT_SUBTITLE_CODECS = {"subrip", "ass", "ssa", "webvtt", "mov_text"}
SILENCE_START_RE = re.compile(r"silence_start:\s*([0-9.]+)")
SILENCE_END_RE = re.compile(r"silence_end:\s*([0-9.]+)\s*\|\s*silence_duration:\s*([0-9.]+)")
ASR_UPLOAD_WAV_BYTES_PER_SECOND = 16000 * 2


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


def probe_media_duration(media_path: Path) -> float:
    data = probe_audio(media_path)
    try:
        return float(data.get("format", {}).get("duration", 0.0))
    except (TypeError, ValueError):
        return 0.0


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
    if wanted_lang in {"", "auto", "detect"}:
        return sorted(
            supported,
            key=lambda stream: (not stream.get("default"), stream.get("index", 9999)),
        )[0] if supported else None
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
    copy_ok = _can_copy_audio(codec, output_audio)
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


def _select_audio_stream(audio_streams: list[dict[str, Any]], *, source_lang: str, audio_track: str = "auto") -> dict[str, Any]:
    if not audio_streams:
        raise RuntimeError("No audio stream found")
    requested = str(audio_track or "auto").strip().lower()
    if requested and requested != "auto":
        try:
            wanted = int(requested)
        except ValueError as exc:
            raise RuntimeError(f"invalid_audio_track: {audio_track}") from exc
        match = next((stream for stream in audio_streams if int(stream.get("index", -1)) == wanted), None)
        if match is None:
            raise RuntimeError(f"audio_track_not_found: {audio_track}")
        return match
    wanted_lang = _normalize_language(source_lang)
    if wanted_lang in {"", "auto", "detect"}:
        return sorted(audio_streams, key=lambda stream: (not _stream_disposition(stream).get("default", 0), stream.get("index", 9999)))[0]
    matched = [
        stream
        for stream in audio_streams
        if _normalize_language(_stream_tags(stream).get("language", "")) == wanted_lang
    ]
    if matched:
        return sorted(matched, key=lambda stream: (not _stream_disposition(stream).get("default", 0), stream.get("index", 9999)))[0]
    return sorted(audio_streams, key=lambda stream: (not _stream_disposition(stream).get("default", 0), stream.get("index", 9999)))[0]


def extract_audio_for_asr(
    video_path: Path,
    output_audio: Path,
    *,
    source_lang: str,
    audio_track: str = "auto",
) -> dict:
    probe = probe_audio(video_path)
    streams = probe.get("streams", [])
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    selected = _select_audio_stream(audio_streams, source_lang=source_lang, audio_track=audio_track)
    stream_index = int(selected.get("index", -1))
    codec = str(selected.get("codec_name") or "")
    copy_ok = _can_copy_audio(codec, output_audio)
    tags = _stream_tags(selected)
    output_audio.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-i", str(video_path), "-map", f"0:{stream_index}", "-vn"]
    if copy_ok:
        cmd += ["-c:a", "copy"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "128k"]
    cmd.append(str(output_audio))
    _run(cmd)
    duration = float(probe.get("format", {}).get("duration", 0.0))
    try:
        duration = float(selected.get("duration") or duration)
    except (TypeError, ValueError):
        pass
    return {
        "audio_codec": codec,
        "copy_mode": copy_ok,
        "duration_seconds": duration,
        "audio_stream_index": stream_index,
        "audio_stream_language": tags.get("language", ""),
        "audio_stream_title": tags.get("title", ""),
        "audio_track": audio_track,
    }


def _can_copy_audio(codec: str, output_audio: Path) -> bool:
    normalized = codec.strip().lower()
    suffix = output_audio.suffix.lower()
    if normalized == "aac":
        return suffix in {".aac", ".m4a", ".mp4"}
    if normalized == "mp3":
        return suffix == ".mp3"
    return False


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


def _effective_window_seconds(*, mode: str, window_seconds: int, max_window_seconds: int) -> float:
    if mode == "silence":
        return max(float(max_window_seconds), 0.1)
    return max(float(window_seconds), 0.1)


def _choose_silence_cut(
    silence_ranges: list[dict[str, float]],
    *,
    start: float,
    hard_end: float,
    duration_seconds: float,
    min_window_seconds: float,
    cut_padding_seconds: float,
) -> float:
    if hard_end >= duration_seconds:
        return duration_seconds
    eligible = []
    for item in silence_ranges:
        silence_start = float(item.get("start", 0.0))
        silence_end = float(item.get("end", 0.0))
        if math.isinf(silence_end):
            silence_end = duration_seconds
        midpoint = (silence_start + silence_end) / 2.0
        if start + min_window_seconds <= midpoint <= hard_end:
            eligible.append((silence_start, silence_end, midpoint))
    if not eligible:
        return hard_end
    silence_start, silence_end, midpoint = eligible[-1]
    return max(start + min_window_seconds, min(midpoint + max(cut_padding_seconds, 0.0), hard_end))


def _build_silence_windows(
    *,
    duration_seconds: float,
    silence_ranges: list[dict[str, float]],
    max_window_seconds: int,
    min_window_seconds: int,
    overlap_seconds: int,
    cut_padding_seconds: float,
) -> list[tuple[float, float]]:
    windows: list[tuple[float, float]] = []
    start = 0.0
    max_window = max(float(max_window_seconds), 0.1)
    min_window = max(0.1, min(float(min_window_seconds), max_window))
    overlap = max(float(overlap_seconds), 0.0)
    while start < duration_seconds - 0.05:
        hard_end = min(start + max_window, duration_seconds)
        end = _choose_silence_cut(
            silence_ranges,
            start=start,
            hard_end=hard_end,
            duration_seconds=duration_seconds,
            min_window_seconds=min_window,
            cut_padding_seconds=cut_padding_seconds,
        )
        if end <= start:
            end = min(start + max_window, duration_seconds)
        windows.append((start, end))
        if end >= duration_seconds:
            break
        start = max(end - overlap, start + 0.1)
    return windows or [(0.0, max(duration_seconds, 0.1))]


def _build_fixed_windows(
    *,
    duration_seconds: float,
    window_seconds: float,
    overlap_seconds: int,
) -> list[tuple[float, float]]:
    effective_window = max(float(window_seconds), 0.1)
    effective_overlap = max(0, min(int(overlap_seconds), int(effective_window) - 1))
    step = effective_window - effective_overlap
    windows = []
    count = max(1, int(math.ceil(max(duration_seconds, 0.1) / step)))
    for idx in range(count):
        start = idx * step
        if start >= duration_seconds:
            break
        windows.append((start, min(start + effective_window, max(duration_seconds, 0.1))))
    return windows


def split_audio_for_asr(
    audio_path: Path,
    segments_dir: Path,
    *,
    mode: str,
    window_seconds: int,
    max_window_seconds: int = 60,
    min_window_seconds: int = 12,
    overlap_seconds: int,
    short_audio_seconds: int,
    max_upload_mb: float = 24.0,
    duration_seconds: float,
    silence_noise_db: float = -35.0,
    silence_min_seconds: float = 0.25,
    silence_cut_padding_seconds: float = 0.15,
    validate_duration: bool = True,
    source_start_seconds: float = 0.0,
) -> list[dict]:
    normalized_mode = mode.strip().lower()
    if normalized_mode not in {"auto", "fixed", "none", "silence"}:
        normalized_mode = "silence"
    max_upload_seconds = _estimated_asr_upload_seconds(max_upload_mb)
    hard_window_seconds = min(
        _effective_window_seconds(mode=normalized_mode, window_seconds=window_seconds, max_window_seconds=max_window_seconds),
        max_upload_seconds,
    )
    if normalized_mode == "none":
        windows = [(0.0, max(duration_seconds, 0.1))]
        effective_overlap = 0
    elif normalized_mode == "silence":
        silence_ranges = detect_audio_silence(
            audio_path,
            noise_db=silence_noise_db,
            min_silence_seconds=silence_min_seconds,
        )
        if source_start_seconds:
            source_end = source_start_seconds + float(duration_seconds)
            adjusted_ranges = []
            for item in silence_ranges:
                silence_start = max(float(item.get("start", 0.0)), source_start_seconds)
                silence_end = float(item.get("end", 0.0))
                if math.isinf(silence_end):
                    silence_end = source_end
                silence_end = min(silence_end, source_end)
                if silence_end > silence_start:
                    adjusted_ranges.append(
                        {
                            "start": silence_start - source_start_seconds,
                            "end": silence_end - source_start_seconds,
                            "duration": silence_end - silence_start,
                        }
                    )
            silence_ranges = adjusted_ranges
        windows = _build_silence_windows(
            duration_seconds=float(duration_seconds),
            silence_ranges=silence_ranges,
            max_window_seconds=int(hard_window_seconds),
            min_window_seconds=min_window_seconds,
            overlap_seconds=overlap_seconds,
            cut_padding_seconds=silence_cut_padding_seconds,
        )
        effective_overlap = max(0, int(overlap_seconds))
    elif normalized_mode == "auto" and duration_seconds <= max(short_audio_seconds, 0):
        windows = [(0.0, max(duration_seconds, 0.1))]
        effective_overlap = 0
    else:
        windows = _build_fixed_windows(
            duration_seconds=float(duration_seconds),
            window_seconds=min(float(window_seconds), max_upload_seconds),
            overlap_seconds=overlap_seconds,
        )
        effective_overlap = max(0, min(int(overlap_seconds), int(max(float(window_seconds), 0.1)) - 1))
    segments_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for idx, (start, end) in enumerate(windows):
        length = max(end - start, 0.1)
        absolute_start = source_start_seconds + start
        out_file = segments_dir / f"part_{idx:05d}.wav"
        cmd = [
            "ffmpeg",
            "-y",
            "-ss",
            f"{absolute_start:.3f}",
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
        if validate_duration:
            actual_duration = probe_media_duration(out_file)
            if abs(actual_duration - length) > max(0.25, min(length * 0.05, 2.0)):
                raise RuntimeError(
                    f"asr_chunk_duration_mismatch: segment={idx} expected={length:.3f} actual={actual_duration:.3f}"
                )
        trusted_start, trusted_end = _trusted_region_for_window(
            start=float(absolute_start),
            duration=float(length),
            duration_seconds=float(source_start_seconds + duration_seconds),
            overlap_seconds=effective_overlap,
            has_previous=idx > 0,
            has_next=idx < len(windows) - 1,
        )
        manifest.append(
            {
                "segment_index": idx,
                "start": float(absolute_start),
                "duration": float(length),
                "trusted_start": trusted_start,
                "trusted_end": trusted_end,
                "path": str(out_file),
                "source_audio_path": str(audio_path),
            }
        )
    write_json(segments_dir / "manifest.json", manifest)
    return manifest


def _estimated_asr_upload_seconds(max_upload_mb: float) -> float:
    limit_bytes = max(float(max_upload_mb), 0.1) * 1024 * 1024
    # We upload ASR windows as 16 kHz mono pcm_s16le WAV; keep a small header margin.
    return max((limit_bytes - 4096) / ASR_UPLOAD_WAV_BYTES_PER_SECOND, 0.1)


def detect_audio_silence(
    audio_path: Path,
    *,
    noise_db: float,
    min_silence_seconds: float,
) -> list[dict[str, float]]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(audio_path),
        "-af",
        f"silencedetect=noise={noise_db:g}dB:d={max(min_silence_seconds, 0.0):g}",
        "-f",
        "null",
        "-",
    ]
    result = subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    return _parse_silencedetect_output(result.stderr + "\n" + result.stdout)


def _parse_silencedetect_output(output: str) -> list[dict[str, float]]:
    ranges: list[dict[str, float]] = []
    active_start: float | None = None
    for line in output.splitlines():
        start_match = SILENCE_START_RE.search(line)
        if start_match:
            active_start = float(start_match.group(1))
            continue
        end_match = SILENCE_END_RE.search(line)
        if end_match:
            end = float(end_match.group(1))
            duration = float(end_match.group(2))
            start = active_start if active_start is not None else max(end - duration, 0.0)
            ranges.append({"start": start, "end": end, "duration": duration})
            active_start = None
    if active_start is not None:
        ranges.append({"start": active_start, "end": math.inf, "duration": math.inf})
    return ranges


def prepare_cloud_asr_audio_upload(
    audio_path: Path,
    output_path: Path,
    *,
    duration_seconds: float,
    enabled: bool,
    backend: str,
    noise_db: float,
    min_silence_seconds: float,
    keep_preroll_seconds: float,
    trim_trailing: bool,
    keep_postroll_seconds: float,
    min_upload_seconds: float,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "enabled": bool(enabled),
        "backend": backend,
        "source_path": str(audio_path),
        "upload_path": str(audio_path),
        "duration_seconds": float(duration_seconds),
        "silence_ranges": [],
        "leading_silence_seconds": 0.0,
        "trailing_silence_seconds": 0.0,
        "trim_start_seconds": 0.0,
        "trim_end_seconds": float(duration_seconds),
        "skipped": False,
        "reason": "",
    }
    if not enabled:
        metadata["reason"] = "disabled"
        return metadata
    if backend != "ffmpeg_silencedetect":
        raise RuntimeError(f"unsupported_asr_preprocess_backend: {backend}")
    duration = max(float(duration_seconds), 0.0)
    if duration <= 0:
        metadata["skipped"] = True
        metadata["reason"] = "empty_audio"
        return metadata

    ranges = detect_audio_silence(audio_path, noise_db=noise_db, min_silence_seconds=min_silence_seconds)
    finite_ranges = []
    for item in ranges:
        start = float(item["start"])
        end = duration if math.isinf(float(item["end"])) else min(float(item["end"]), duration)
        if end <= start:
            continue
        finite_ranges.append({"start": start, "end": end, "duration": end - start})
    metadata["silence_ranges"] = finite_ranges

    leading_silence = 0.0
    trailing_silence = 0.0
    for item in finite_ranges:
        if item["start"] <= 0.001:
            leading_silence = max(leading_silence, float(item["end"]))
    if trim_trailing:
        for item in finite_ranges:
            if item["end"] >= duration - 0.001:
                trailing_silence = max(trailing_silence, duration - float(item["start"]))

    trim_start = max(leading_silence - max(keep_preroll_seconds, 0.0), 0.0) if leading_silence else 0.0
    trim_end = duration
    if trailing_silence:
        trim_end = min(duration, duration - trailing_silence + max(keep_postroll_seconds, 0.0))
    if trim_end - trim_start < max(min_upload_seconds, 0.0):
        if leading_silence >= duration - 0.001:
            metadata["skipped"] = True
            metadata["reason"] = "all_silence"
            metadata["leading_silence_seconds"] = leading_silence
            metadata["trailing_silence_seconds"] = trailing_silence
            metadata["trim_start_seconds"] = trim_start
            metadata["trim_end_seconds"] = trim_end
            return metadata
        trim_start = 0.0
        trim_end = duration

    metadata["leading_silence_seconds"] = leading_silence
    metadata["trailing_silence_seconds"] = trailing_silence
    metadata["trim_start_seconds"] = trim_start
    metadata["trim_end_seconds"] = trim_end
    if trim_start <= 0.001 and trim_end >= duration - 0.001:
        metadata["reason"] = "no_trim"
        return metadata

    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-ss",
        f"{trim_start:.3f}",
        "-i",
        str(audio_path),
        "-t",
        f"{max(trim_end - trim_start, 0.1):.3f}",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(output_path),
    ]
    _run(cmd)
    metadata["upload_path"] = str(output_path)
    metadata["reason"] = "trimmed"
    return metadata
