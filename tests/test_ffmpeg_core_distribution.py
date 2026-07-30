from __future__ import annotations

import hashlib
import json
import re
import zipfile
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
R1_PIN_PATH = ROOT / "requirements" / "ffmpeg-core-runtime.json"
CORE_PIN_PATH = ROOT / "requirements" / "ffmpeg-core-runtime-r2.json"
CURRENT_PIN_PATH = ROOT / "requirements" / "ffmpeg-runtime.json"
BUILD_BASE_PIN_PATH = ROOT / "requirements" / "ffmpeg-btbn-build-base.json"


def _json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_license_complete_core_pin_is_immutable_and_the_default_is_adopted() -> None:
    pin = _json(CORE_PIN_PATH)
    current = _json(CURRENT_PIN_PATH)
    build_base = _json(BUILD_BASE_PIN_PATH)
    binary = pin["binary"]
    source = pin["corresponding_source"]
    integration = pin["integration"]

    assert pin["status"] == "candidate"
    assert pin["adopted"] is False
    assert pin["platform"] == "windows-x64"
    assert pin["variant"] == "transvortex-core-shared"
    assert pin["license"] == "LGPL-3.0-or-later"
    assert pin["ffmpeg_commit"] == current["ffmpeg_commit"]
    assert binary["btbn_build_commit"] == build_base["binary"]["build_commit"]
    assert binary["build_provider"] == "TransVortex"
    assert binary["archive_layout"] == "transvortex-core-v2"
    assert binary["builder_image"].startswith(
        "ghcr.io/btbn/ffmpeg-builds/base-win64@sha256:"
    )
    assert re.fullmatch(r"[0-9a-f]{40}", binary["build_commit"])
    assert re.fullmatch(r"[0-9a-f]{64}", binary["sha256"])
    assert int(binary["size"]) > 1
    assert binary["sha256"] != "0" * 64

    release_base = (
        f"https://github.com/{source['repository']}/releases/download/"
        f"{source['release_tag']}"
    )
    assert binary["url"] == f"{release_base}/{binary['asset_name']}"
    assert source["url"] == f"{release_base}/{source['asset_name']}"
    assert re.fullmatch(r"[0-9a-f]{64}", source["sha256"])
    assert int(source["size"]) > 1
    assert source["sha256"] != "0" * 64

    assert source["scope"] == (
        "complete-core-build-inputs-no-optional-external-libraries"
    )
    assert source["build_input_scope_complete"] is True
    assert source["external_library_sources_required"] == []
    assert source["external_library_sources_included"] is True
    assert source["optional_external_media_source_scope_complete"] is True
    assert source["license_review_complete"] is True
    assert source["public_distribution_ready"] is False
    assert set(source["public_distribution_blockers"]) == {
        "candidate_assets_not_published",
        "default_release_pin_not_adopted",
        "clean_windows_installer_acceptance_pending",
        "clean_windows_real_media_acceptance_pending",
    }
    assert source["archive_builder"] == {
        "powershell_version": "7.6.4",
        "source_notice_line_endings": "lf",
        "manifest_line_endings": "crlf",
        "zip_compression": "optimal",
        "entry_timestamp": "1980-01-01T00:00:00Z",
    }

    assert integration["candidate_pin"] == "requirements/ffmpeg-core-runtime-r2.json"
    assert integration["current_release_pin"] == "requirements/ffmpeg-runtime.json"
    assert integration["replaces_current_release"] is False
    assert integration["portable_enabled"] is False
    assert integration["installer_enabled"] is False
    assert current["status"] == "active"
    assert current["adopted"] is True
    assert current["variant"] == "transvortex-core-shared"
    assert current["binary"]["sha256"] == binary["sha256"]
    assert current["corresponding_source"]["sha256"] == source["sha256"]
    assert current["corresponding_source"]["assets_published"] is True
    assert current["corresponding_source"]["license_review_complete"] is True
    assert set(current["corresponding_source"]["public_distribution_blockers"]) == {
        "clean_windows_installer_acceptance_pending",
        "clean_windows_real_media_acceptance_pending",
    }
    assert current["integration"] == {
        "candidate_pin": "requirements/ffmpeg-core-runtime-r2.json",
        "previous_runtime_pin": "requirements/ffmpeg-core-runtime.json",
        "current_release_pin": "requirements/ffmpeg-runtime.json",
        "replaces_current_release": True,
        "portable_enabled": True,
        "installer_enabled": True,
    }


def test_r1_pin_remains_an_unchanged_historical_snapshot() -> None:
    r1 = _json(R1_PIN_PATH)

    assert r1["status"] == "candidate"
    assert r1["adopted"] is False
    assert r1["binary"]["archive_layout"] == "transvortex-core-v1"
    assert r1["corresponding_source"]["release_tag"].endswith("-r1")
    assert r1["corresponding_source"]["license_review_complete"] is False
    assert "license_review_pending" in r1["corresponding_source"][
        "public_distribution_blockers"
    ]


@pytest.mark.release_asset
def test_core_distribution_pins_exact_build_controls() -> None:
    pin = _json(CORE_PIN_PATH)
    source = pin["corresponding_source"]
    controls = source["build_control_files"]

    assert {item["path"] for item in controls} == {
        "requirements/ffmpeg-btbn-build-base.json",
        "requirements/ffmpeg-core-prototype.json",
        "scripts/ffmpeg_core_prototype.Dockerfile",
        "scripts/build_ffmpeg_core_prototype.ps1",
        "scripts/build_ffmpeg_runtime.ps1",
        "scripts/verify_ffmpeg_core_runtime.py",
        "docs/FFMPEG_DISTRIBUTION_COMPLIANCE.md",
    }
    source_asset = (
        ROOT
        / "dist"
        / "ffmpeg-core-distribution"
        / f"{pin['version']}-r2"
        / source["asset_name"]
    )
    if not source_asset.is_file():
        pytest.skip("Pinned FFmpeg corresponding-source asset is not available locally")
    with zipfile.ZipFile(source_asset) as archive:
        names = set(archive.namelist())
        assert "licenses/FFmpeg-LICENSE.txt" in names
        assert "licenses/FFmpeg-GPLv3.txt" in names
        assert "LICENSE_REVIEW.md" in names
        assert "SOURCE_CHANGES.txt" in names
        assert b"None." in archive.read("SOURCE_CHANGES.txt")
        for control in controls:
            content = archive.read(f"build-control/{control['path']}")
            assert len(content) == control["size"]
            assert hashlib.sha256(content).hexdigest() == control["sha256"]


def test_core_distribution_builder_enforces_deterministic_candidate_assets() -> None:
    builder = (
        ROOT / "scripts" / "build_ffmpeg_core_distribution.ps1"
    ).read_text(encoding="utf-8")

    assert "requirements\\ffmpeg-core-runtime.json" in builder
    assert "New-DeterministicZip" in builder
    assert "Get-RelativeArchivePath" in builder
    assert "1980, 1, 1, 0, 0, 0" in builder
    assert "PowerShell 7.6.4 exactly" in builder
    assert "BootstrapPin" in builder
    assert "do not match the immutable candidate pin" in builder
    assert 'component = "ffmpeg-core-candidate"' in builder
    assert 'component = "ffmpeg-core-corresponding-source"' in builder
    assert 'component = "transvortex-ffmpeg-distribution"' in builder
    assert 'distribution_kind = "transvortex-core"' in builder
    assert "public_distribution_source_ready" in builder
    assert "FFmpeg-GPLv3.txt" in builder
    assert "SOURCE_CHANGES.txt" in builder
    assert "FFMPEG_DISTRIBUTION_COMPLIANCE.md" in builder
    assert "unexpected_external" in builder
    assert 'public_distribution_ready = $false' in builder
    assert 'replaces_current_release = $false' in builder
    assert "publish_ffmpeg_distribution.ps1" not in builder
    assert "package_flutter_release.ps1" not in builder

    runtime_manifest_block = builder.split("$runtimeManifest =", 1)[1].split(
        "Write-Utf8NoBom", 1
    )[0]
    assert "generated_at" not in runtime_manifest_block
    assert "runtime_root" not in runtime_manifest_block
    assert "fixture_generator_root" not in runtime_manifest_block


def test_standard_runtime_builder_supports_the_core_archive_contract() -> None:
    builder = (ROOT / "scripts" / "build_ffmpeg_runtime.ps1").read_text(
        encoding="utf-8"
    )

    assert '"transvortex-core-v1"' in builder
    assert '"transvortex-core-v2"' in builder
    assert 'component -ne "ffmpeg-core-candidate"' in builder
    assert "coreArchiveManifest.files.PSObject.Properties" in builder
    assert "coreArchiveManifest.archive_layout" in builder
    assert "core executable version lines do not match" in builder
    assert "complete technical build-input set" in builder
    assert 'Join-Path $payloadRoot "build-info"' in builder
    assert 'Join-Path $payloadRoot "ffmpeg_compatibility.json"' in builder
    assert 'Join-Path $payloadRoot "licenses\\FFmpeg-GPLv3.txt"' in builder
    assert "archive_layout = $archiveLayout" in builder
