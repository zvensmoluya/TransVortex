from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE_PIN_PATH = ROOT / "requirements" / "ffmpeg-core-runtime.json"
CURRENT_PIN_PATH = ROOT / "requirements" / "ffmpeg-runtime.json"


def _json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_core_distribution_pin_is_immutable_but_not_adopted() -> None:
    pin = _json(CORE_PIN_PATH)
    current = _json(CURRENT_PIN_PATH)
    binary = pin["binary"]
    source = pin["corresponding_source"]
    integration = pin["integration"]

    assert pin["status"] == "candidate"
    assert pin["adopted"] is False
    assert pin["platform"] == "windows-x64"
    assert pin["variant"] == "transvortex-core-shared"
    assert pin["license"] == "LGPL-3.0-or-later"
    assert pin["ffmpeg_commit"] == current["ffmpeg_commit"]
    assert binary["btbn_build_commit"] == current["binary"]["build_commit"]
    assert binary["build_provider"] == "TransVortex"
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
    assert source["license_review_complete"] is False
    assert source["public_distribution_ready"] is False
    assert set(source["public_distribution_blockers"]) == {
        "candidate_assets_not_published",
        "portable_installer_not_integrated",
        "clean_windows_real_media_acceptance_pending",
        "license_review_pending",
    }
    assert source["archive_builder"] == {
        "powershell_version": "7.6.4",
        "source_notice_line_endings": "lf",
        "manifest_line_endings": "crlf",
        "zip_compression": "optimal",
        "entry_timestamp": "1980-01-01T00:00:00Z",
    }

    assert integration == {
        "current_release_pin": "requirements/ffmpeg-runtime.json",
        "replaces_current_release": False,
        "portable_enabled": False,
        "installer_enabled": False,
    }
    assert current["variant"] == "win64-lgpl-shared-8.1"


@pytest.mark.release_asset
def test_core_distribution_pins_exact_build_controls() -> None:
    source = _json(CORE_PIN_PATH)["corresponding_source"]
    controls = source["build_control_files"]

    assert {item["path"] for item in controls} == {
        "requirements/ffmpeg-runtime.json",
        "requirements/ffmpeg-core-prototype.json",
        "scripts/ffmpeg_core_prototype.Dockerfile",
        "scripts/build_ffmpeg_core_prototype.ps1",
        "scripts/build_ffmpeg_runtime.ps1",
        "scripts/verify_ffmpeg_core_runtime.py",
    }
    for control in controls:
        path = ROOT / control["path"]
        assert path.is_file()
        assert path.stat().st_size == control["size"]
        assert _sha256(path) == control["sha256"]


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
