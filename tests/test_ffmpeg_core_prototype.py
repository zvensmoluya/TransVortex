from __future__ import annotations

import json
import wave
from pathlib import Path

from transvortex.app.media_inspect import AUDIO_EXTENSIONS
from transvortex.core.media import TEXT_SUBTITLE_CODECS

from scripts.verify_ffmpeg_core_runtime import _write_audio_fixture


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "requirements" / "ffmpeg-core-prototype.json"
PIN_PATH = ROOT / "requirements" / "ffmpeg-runtime.json"


def _json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_core_prototype_is_balanced_and_tracks_the_current_source_pin() -> None:
    spec = _json(SPEC_PATH)
    pin = _json(PIN_PATH)
    policy = spec["policy"]
    flags = set(spec["configure_flags"])

    assert spec["status"] == "evaluation"
    assert spec["platform"] == "windows-x64"
    assert spec["license"] == "LGPL-3.0-or-later"
    assert spec["ffmpeg_commit"] == pin["ffmpeg_commit"]
    assert spec["btbn_build_commit"] == pin["binary"]["build_commit"]
    assert spec["builder_image"].startswith(
        "ghcr.io/btbn/ffmpeg-builds/base-win64@sha256:"
    )
    assert len(spec["builder_image"].rsplit(":", 1)[1]) == 64
    assert policy == {
        "preserve_ffmpeg_builtin_components": True,
        "extreme_component_pruning": False,
        "external_library_allowlist": [],
        "replace_current_release": False,
    }
    assert {
        "--enable-version3",
        "--enable-shared",
        "--disable-static",
        "--disable-autodetect",
        "--disable-gpl",
        "--disable-nonfree",
    }.issubset(flags)
    assert not any(flag.startswith("--enable-lib") for flag in flags)
    assert not flags.intersection(
        {
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
    )


def test_core_compatibility_contract_matches_product_media_types() -> None:
    compatibility = _json(SPEC_PATH)["compatibility"]

    assert set(compatibility["audio_extensions"]) == AUDIO_EXTENSIONS
    assert set(compatibility["text_subtitle_codecs"]) == TEXT_SUBTITLE_CODECS
    assert {"aac", "mp3", "pcm_s16le", "flac", "opus", "vorbis"}.issubset(
        compatibility["audio_codecs"]
    )
    assert compatibility["required_filters"] == ["silencedetect"]
    assert set(compatibility["required_encoders"]) == {"aac", "pcm_s16le", "srt"}


def test_core_build_is_reproducible_and_cannot_publish_or_replace_release() -> None:
    dockerfile = (ROOT / "scripts" / "ffmpeg_core_prototype.Dockerfile").read_text(
        encoding="utf-8"
    )
    builder = (ROOT / "scripts" / "build_ffmpeg_core_prototype.ps1").read_text(
        encoding="utf-8"
    )

    assert "FROM ${BUILDER_IMAGE} AS build" in dockerfile
    assert f"ARG BUILDER_IMAGE={_json(SPEC_PATH)['builder_image']}" in dockerfile
    assert "COPY ffmpeg-source.tar.gz" in dockerfile
    assert "--no-insert-timestamp" in dockerfile
    assert "SOURCE_DATE_EPOCH" in dockerfile
    assert "requirements\\ffmpeg-core-prototype.json" in builder
    assert "requirements\\ffmpeg-runtime.json" in builder
    assert "verify_ffmpeg_core_runtime.py" in builder
    assert "compatibility.runtime_root = $outputFullPath" in builder
    assert "Extreme component pruning is intentionally unsupported" in builder
    assert 'optional_external_media_source_scope_complete = $true' in builder
    assert 'public_distribution_ready = $false' in builder
    assert 'replaces_current_release = $false' in builder
    assert "publish_ffmpeg_distribution.ps1" not in builder
    assert "package_flutter_release.ps1" not in builder


def test_compatibility_audio_fixture_contains_expected_silence(tmp_path: Path) -> None:
    fixture = tmp_path / "source.wav"
    _write_audio_fixture(fixture)

    with wave.open(str(fixture), "rb") as source:
        assert source.getnchannels() == 1
        assert source.getsampwidth() == 2
        assert source.getframerate() == 48_000
        frames = source.readframes(source.getnframes())

    first_half_second = frames[: 48_000 * 2 // 2]
    middle = frames[48_000 * 2 : 48_000 * 2 * 2]
    last_half_second = frames[-(48_000 * 2 // 2) :]
    assert set(first_half_second) == {0}
    assert any(middle)
    assert set(last_half_second) == {0}
