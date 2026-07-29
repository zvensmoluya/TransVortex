from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path
from typing import Any, Sequence


EXTERNAL_ENABLE_FLAGS = {
    "--enable-amf",
    "--enable-cuda-llvm",
    "--enable-ffnvcodec",
    "--enable-fontconfig",
    "--enable-gmp",
    "--enable-iconv",
    "--enable-lv2",
    "--enable-lzma",
    "--enable-openal",
    "--enable-opencl",
    "--enable-schannel",
    "--enable-sdl2",
    "--enable-vaapi",
    "--enable-vulkan",
    "--enable-zlib",
}
WINDOWS_SYSTEM_DLLS = {
    "advapi32.dll",
    "avicap32.dll",
    "bcrypt.dll",
    "crypt32.dll",
    "gdi32.dll",
    "kernel32.dll",
    "mf.dll",
    "mfplat.dll",
    "mfreadwrite.dll",
    "msvcrt.dll",
    "ole32.dll",
    "oleaut32.dll",
    "secur32.dll",
    "shell32.dll",
    "shlwapi.dll",
    "ucrtbase.dll",
    "user32.dll",
    "version.dll",
    "winmm.dll",
    "ws2_32.dll",
}


class VerificationError(RuntimeError):
    pass


def _binary(runtime_root: Path, name: str) -> Path:
    path = runtime_root / "bin" / f"{name}.exe"
    if not path.is_file():
        raise VerificationError(f"Missing runtime executable: {path}")
    return path


def _run(
    executable: Path,
    args: Sequence[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(executable), *args],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and result.returncode != 0:
        raise VerificationError(
            f"Command failed ({result.returncode}): {executable.name} {' '.join(args)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def _write_audio_fixture(path: Path) -> None:
    sample_rate = 48_000
    duration_seconds = 3.0
    frame_count = int(sample_rate * duration_seconds)
    amplitude = 11_000
    frames = bytearray()
    for index in range(frame_count):
        timestamp = index / sample_rate
        if timestamp < 0.5 or timestamp >= 2.5:
            sample = 0
        else:
            sample = int(amplitude * math.sin(2 * math.pi * 440 * timestamp))
        frames.extend(int(sample).to_bytes(2, byteorder="little", signed=True))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(frames)


def _write_subtitle_fixtures(root: Path) -> dict[str, Path]:
    srt = root / "sample.srt"
    srt.write_text(
        "1\n00:00:00,600 --> 00:00:01,600\nTransVortex subtitle\n",
        encoding="utf-8",
    )
    ass_text = """[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.60,0:00:01.60,Default,,0,0,0,,TransVortex subtitle
"""
    ass = root / "sample.ass"
    ass.write_text(ass_text, encoding="utf-8")
    ssa = root / "sample.ssa"
    ssa.write_text(
        """[Script Info]
ScriptType: v4.00

[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,1,2,0,2,10,10,10,0,1

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:00.60,0:00:01.60,Default,,0,0,0,,TransVortex subtitle
""",
        encoding="utf-8",
    )
    webvtt = root / "sample.vtt"
    webvtt.write_text(
        "WEBVTT\n\n00:00:00.600 --> 00:00:01.600\nTransVortex subtitle\n",
        encoding="utf-8",
    )
    return {"subrip": srt, "ass": ass, "ssa": ssa, "webvtt": webvtt}


def _generate_audio_fixtures(
    generator: Path,
    source_wav: Path,
    root: Path,
) -> dict[str, Path]:
    fixtures: dict[str, tuple[str, list[str]]] = {
        "mp3": ("sample.mp3", ["-c:a", "libmp3lame", "-q:a", "4"]),
        "m4a": ("sample.m4a", ["-c:a", "aac", "-b:a", "128k"]),
        "flac": ("sample.flac", ["-c:a", "flac"]),
        "aac": ("sample.aac", ["-c:a", "aac", "-f", "adts"]),
        "ogg": ("sample.ogg", ["-c:a", "libvorbis", "-q:a", "4"]),
        "opus": ("sample.opus", ["-c:a", "libopus", "-b:a", "96k"]),
        "ac3": ("sample-ac3.mka", ["-c:a", "ac3", "-b:a", "192k"]),
        "eac3": ("sample-eac3.mka", ["-c:a", "eac3", "-b:a", "192k"]),
    }
    generated = {"wav": source_wav}
    for key, (name, codec_args) in fixtures.items():
        destination = root / name
        _run(
            generator,
            [
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(source_wav),
                *codec_args,
                str(destination),
            ],
        )
        generated[key] = destination
    return generated


def _generate_subtitle_containers(
    generator: Path,
    source_wav: Path,
    subtitles: dict[str, Path],
    root: Path,
) -> dict[str, Path]:
    mkv = root / "embedded-subrip.mkv"
    _run(
        generator,
        [
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=160x90:rate=15",
            "-i",
            str(source_wav),
            "-i",
            str(subtitles["subrip"]),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-map",
            "2:s:0",
            "-c:v",
            "libopenh264",
            "-b:v",
            "240k",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "flac",
            "-c:s",
            "srt",
            "-t",
            "3",
            "-metadata:s:a:0",
            "language=eng",
            "-metadata:s:s:0",
            "language=eng",
            str(mkv),
        ],
    )
    mp4 = root / "embedded-mov-text.mp4"
    _run(
        generator,
        [
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=160x90:rate=15",
            "-i",
            str(source_wav),
            "-i",
            str(subtitles["subrip"]),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-map",
            "2:s:0",
            "-c:v",
            "libopenh264",
            "-b:v",
            "240k",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-c:s",
            "mov_text",
            "-t",
            "3",
            "-metadata:s:s:0",
            "language=eng",
            str(mp4),
        ],
    )
    return {"subrip": mkv, "mov_text": mp4}


def _probe(ffprobe: Path, media_path: Path) -> dict[str, Any]:
    result = _run(
        ffprobe,
        [
            "-v",
            "error",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(media_path),
        ],
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise VerificationError(f"ffprobe returned invalid JSON for {media_path}") from exc


def _assert_pcm_wav(path: Path) -> dict[str, int]:
    with wave.open(str(path), "rb") as source:
        details = {
            "channels": source.getnchannels(),
            "sample_width": source.getsampwidth(),
            "sample_rate": source.getframerate(),
            "frames": source.getnframes(),
        }
    expected = {"channels": 1, "sample_width": 2, "sample_rate": 16_000}
    for key, value in expected.items():
        if details[key] != value:
            raise VerificationError(
                f"Unexpected WAV {key}: expected={value} actual={details[key]} path={path}"
            )
    return details


def _configuration_flags(version_output: str) -> list[str]:
    configuration = next(
        (line for line in version_output.splitlines() if line.startswith("configuration:")),
        "",
    )
    if not configuration:
        raise VerificationError("ffmpeg -version did not report its configuration")
    return configuration.removeprefix("configuration:").strip().split()


def _verify_build_policy(ffmpeg: Path) -> dict[str, Any]:
    version = _run(ffmpeg, ["-hide_banner", "-version"]).stdout
    license_output = _run(ffmpeg, ["-hide_banner", "-L"]).stdout
    flags = _configuration_flags(version)
    required_flags = {
        "--enable-version3",
        "--enable-shared",
        "--disable-static",
        "--disable-autodetect",
        "--disable-gpl",
        "--disable-nonfree",
    }
    missing = sorted(required_flags - set(flags))
    if missing:
        raise VerificationError(f"Core build is missing required configure flags: {missing}")
    forbidden_pruning = {
        "--disable-all",
        "--disable-everything",
        "--disable-decoders",
        "--disable-demuxers",
        "--disable-encoders",
        "--disable-filters",
        "--disable-muxers",
        "--disable-parsers",
        "--disable-protocols",
    }
    found_pruning = sorted(forbidden_pruning.intersection(flags))
    if found_pruning:
        raise VerificationError(f"Core build applies extreme component pruning: {found_pruning}")
    external_flags = sorted(
        flag
        for flag in flags
        if flag.startswith("--enable-lib") or flag in EXTERNAL_ENABLE_FLAGS
    )
    if external_flags:
        raise VerificationError(f"Core build enables external libraries: {external_flags}")
    if "GNU Lesser General Public License" not in license_output:
        raise VerificationError("Core build did not report the expected LGPL license")
    return {
        "version_line": version.splitlines()[0],
        "configure_flags": flags,
        "external_enable_flags": external_flags,
        "license": "LGPL",
    }


def _verify_named_capabilities(ffmpeg: Path, spec: dict[str, Any]) -> dict[str, list[str]]:
    checks = {
        "filters": ("-filters", spec["compatibility"]["required_filters"]),
        "encoders": ("-encoders", spec["compatibility"]["required_encoders"]),
    }
    verified: dict[str, list[str]] = {}
    for kind, (argument, names) in checks.items():
        output = _run(ffmpeg, ["-hide_banner", argument]).stdout
        missing = [name for name in names if not re.search(rf"\b{re.escape(name)}\b", output)]
        if missing:
            raise VerificationError(f"Core build is missing required {kind}: {missing}")
        verified[kind] = list(names)
    return verified


def _verify_pe_imports(runtime_root: Path) -> dict[str, list[str]]:
    imports_path = runtime_root / "build-info" / "pe-imports.txt"
    if not imports_path.is_file():
        raise VerificationError(f"Missing PE import report: {imports_path}")
    imports = sorted(
        {
            line.removeprefix("DLL Name:").strip()
            for line in imports_path.read_text(encoding="utf-8").splitlines()
            if line.startswith("DLL Name:")
        },
        key=str.casefold,
    )
    bundled_names = {
        path.name.casefold() for path in (runtime_root / "bin").glob("*.dll")
    }
    bundled: list[str] = []
    windows_system: list[str] = []
    unexpected_external: list[str] = []
    for name in imports:
        normalized = name.casefold()
        if normalized in bundled_names:
            bundled.append(name)
        elif normalized.startswith("api-ms-win-") or normalized in WINDOWS_SYSTEM_DLLS:
            windows_system.append(name)
        else:
            unexpected_external.append(name)
    if unexpected_external:
        raise VerificationError(
            "Core build imports unexpected external DLLs: "
            f"{unexpected_external}"
        )
    return {
        "bundled_ffmpeg": bundled,
        "windows_system": windows_system,
        "unexpected_external": unexpected_external,
    }


def verify_runtime(
    runtime_root: Path,
    fixture_generator_root: Path,
    spec: dict[str, Any],
) -> dict[str, Any]:
    runtime_root = runtime_root.resolve()
    fixture_generator_root = fixture_generator_root.resolve()
    ffmpeg = _binary(runtime_root, "ffmpeg")
    ffprobe = _binary(runtime_root, "ffprobe")
    generator = _binary(fixture_generator_root, "ffmpeg")
    policy = _verify_build_policy(ffmpeg)
    capabilities = _verify_named_capabilities(ffmpeg, spec)
    pe_imports = _verify_pe_imports(runtime_root)

    with tempfile.TemporaryDirectory(prefix="transvortex-ffmpeg-core-") as raw_temp:
        work_root = Path(raw_temp)
        source_wav = work_root / "source.wav"
        _write_audio_fixture(source_wav)
        audio_fixtures = _generate_audio_fixtures(generator, source_wav, work_root)
        subtitle_fixtures = _write_subtitle_fixtures(work_root)
        subtitle_containers = _generate_subtitle_containers(
            generator,
            source_wav,
            subtitle_fixtures,
            work_root,
        )

        audio_results: dict[str, Any] = {}
        for name, fixture in audio_fixtures.items():
            probe = _probe(ffprobe, fixture)
            audio_streams = [
                stream for stream in probe.get("streams", []) if stream.get("codec_type") == "audio"
            ]
            if not audio_streams:
                raise VerificationError(f"No audio stream found in fixture: {fixture}")
            output_wav = work_root / f"decoded-{name}.wav"
            _run(
                ffmpeg,
                [
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    str(fixture),
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-c:a",
                    "pcm_s16le",
                    str(output_wav),
                ],
            )
            audio_results[name] = {
                "codec": str(audio_streams[0].get("codec_name") or ""),
                "decoded_wav": _assert_pcm_wav(output_wav),
            }

        copied_mp3 = work_root / "copied.mp3"
        _run(
            ffmpeg,
            ["-y", "-i", str(audio_fixtures["mp3"]), "-vn", "-c:a", "copy", str(copied_mp3)],
        )
        copied_m4a = work_root / "copied.m4a"
        _run(
            ffmpeg,
            ["-y", "-i", str(audio_fixtures["m4a"]), "-vn", "-c:a", "copy", str(copied_m4a)],
        )

        silence = _run(
            ffmpeg,
            [
                "-hide_banner",
                "-nostats",
                "-i",
                str(source_wav),
                "-af",
                "silencedetect=noise=-35dB:d=0.2",
                "-f",
                "null",
                "-",
            ],
        )
        silence_text = silence.stdout + "\n" + silence.stderr
        if "silence_start:" not in silence_text or "silence_end:" not in silence_text:
            raise VerificationError("silencedetect did not report the expected silence boundaries")

        container_results: dict[str, Any] = {}
        for name, container in subtitle_containers.items():
            probe = _probe(ffprobe, container)
            streams = probe.get("streams", [])
            audio_stream = next(
                (stream for stream in streams if stream.get("codec_type") == "audio"),
                None,
            )
            subtitle_stream = next(
                (stream for stream in streams if stream.get("codec_type") == "subtitle"),
                None,
            )
            video_stream = next(
                (stream for stream in streams if stream.get("codec_type") == "video"),
                None,
            )
            if audio_stream is None or subtitle_stream is None or video_stream is None:
                raise VerificationError(f"Container fixture is missing expected streams: {container}")
            extracted_audio = work_root / f"extracted-{name}.m4a"
            _run(
                ffmpeg,
                [
                    "-y",
                    "-i",
                    str(container),
                    "-map",
                    f"0:{audio_stream['index']}",
                    "-vn",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "128k",
                    str(extracted_audio),
                ],
            )
            extracted_subtitle = work_root / f"extracted-{name}.srt"
            _run(
                ffmpeg,
                [
                    "-y",
                    "-i",
                    str(container),
                    "-map",
                    f"0:{subtitle_stream['index']}",
                    "-c:s",
                    "srt",
                    str(extracted_subtitle),
                ],
            )
            if "TransVortex subtitle" not in extracted_subtitle.read_text(
                encoding="utf-8-sig"
            ):
                raise VerificationError(f"Extracted subtitle content is invalid: {container}")
            container_results[name] = {
                "video_codec": video_stream.get("codec_name"),
                "audio_codec": audio_stream.get("codec_name"),
                "subtitle_codec": subtitle_stream.get("codec_name"),
            }

        direct_subtitle_results: dict[str, bool] = {}
        for name, source in subtitle_fixtures.items():
            output = work_root / f"converted-{name}.srt"
            _run(
                ffmpeg,
                ["-y", "-i", str(source), "-c:s", "srt", str(output)],
            )
            direct_subtitle_results[name] = "TransVortex subtitle" in output.read_text(
                encoding="utf-8-sig"
            )
            if not direct_subtitle_results[name]:
                raise VerificationError(f"Subtitle conversion failed for {name}")

    runtime_files = sorted(path for path in runtime_root.rglob("*") if path.is_file())
    return {
        "ok": True,
        "runtime_root": str(runtime_root),
        "fixture_generator_root": str(fixture_generator_root),
        "runtime_file_count": len(runtime_files),
        "runtime_bytes": sum(path.stat().st_size for path in runtime_files),
        "policy": policy,
        "capabilities": capabilities,
        "pe_imports": pe_imports,
        "audio_fixtures": audio_results,
        "container_fixtures": container_results,
        "direct_subtitle_fixtures": direct_subtitle_results,
        "required_operations": list(spec["compatibility"]["required_operations"]),
    }


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify the TransVortex FFmpeg core prototype")
    parser.add_argument("--runtime-root", required=True, type=Path)
    parser.add_argument("--fixture-generator-root", required=True, type=Path)
    parser.add_argument(
        "--spec",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "requirements"
        / "ffmpeg-core-prototype.json",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    try:
        report = verify_runtime(args.runtime_root, args.fixture_generator_root, spec)
    except (OSError, VerificationError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"FFmpeg core prototype verified: {report['runtime_root']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
