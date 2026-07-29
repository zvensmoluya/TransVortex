from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "requirements" / "ffmpeg-runtime.json"


def _pin() -> dict[str, object]:
    return json.loads(PIN_PATH.read_text(encoding="utf-8"))


def test_ffmpeg_distribution_pin_is_immutable_and_complete() -> None:
    pin = _pin()
    binary = pin["binary"]
    source = pin["corresponding_source"]

    assert pin["platform"] == "windows-x64"
    assert pin["variant"] == "win64-lgpl-shared-8.1"
    assert pin["license"] == "LGPL-3.0-or-later"
    assert binary["build_tag"].startswith("autobuild-")
    assert binary["build_tag"] != "latest"
    assert "/zvensmoluya/transvortex-assets/releases/download/" in binary["url"]
    assert "/BtbN/FFmpeg-Builds/releases/download/autobuild-" in binary["upstream_url"]
    assert source["repository"] == "zvensmoluya/transvortex-assets"
    assert source["scope"] == "ffmpeg-core-and-build-scripts"
    assert source["external_library_sources_included"] is False
    assert source["public_distribution_ready"] is False
    assert f"/releases/download/{source['release_tag']}/" in source["url"]
    assert int(binary["size"]) > 0
    assert int(source["size"]) > 0
    assert re.fullmatch(r"[0-9a-f]{40}", pin["ffmpeg_commit"])
    assert re.fullmatch(r"[0-9a-f]{40}", binary["build_commit"])
    assert re.fullmatch(r"[0-9a-f]{64}", binary["sha256"])
    assert re.fullmatch(r"[0-9a-f]{64}", source["sha256"])

    for archive_key in ("ffmpeg_archive", "build_scripts_archive"):
        archive = source[archive_key]
        assert int(archive["size"]) > 0
        assert re.fullmatch(r"[0-9a-f]{64}", archive["sha256"])
        assert archive["url"].startswith("https://github.com/")


def test_ffmpeg_release_scripts_share_the_pin_and_verify_public_source() -> None:
    runtime_builder = (ROOT / "scripts" / "build_ffmpeg_runtime.ps1").read_text(
        encoding="utf-8"
    )
    source_builder = (
        ROOT / "scripts" / "build_ffmpeg_source_bundle.ps1"
    ).read_text(encoding="utf-8")
    publisher = (
        ROOT / "scripts" / "publish_ffmpeg_distribution.ps1"
    ).read_text(encoding="utf-8")
    packager = (ROOT / "scripts" / "package_flutter_release.ps1").read_text(
        encoding="utf-8"
    )
    installer_builder = (
        ROOT / "scripts" / "build_windows_installer.ps1"
    ).read_text(encoding="utf-8")

    assert 'requirements\\ffmpeg-runtime.json' in runtime_builder
    assert 'requirements\\ffmpeg-runtime.json' in source_builder
    assert "LGPL-2.1-or-later" not in runtime_builder
    assert "New-DeterministicZip" in source_builder
    assert "ffmpeg-source-traceability-bundle" in source_builder
    assert "external_library_sources_included" in source_builder
    assert "Build asset changed" not in publisher
    assert "FFmpeg distribution asset changed" in publisher
    assert "public_distribution_source_ready" in packager
    assert "packagedCorrespondingSourceReady" in installer_builder
    assert "ffmpeg_corresponding_source_sha256" in installer_builder
