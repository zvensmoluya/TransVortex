from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "requirements" / "ffmpeg-runtime.json"


def _pin() -> dict[str, object]:
    return json.loads(PIN_PATH.read_text(encoding="utf-8"))


def _pinned_powershell() -> str | None:
    candidates: list[str] = []
    discovered = shutil.which("pwsh")
    if discovered:
        candidates.append(discovered)
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            candidates.append(
                str(
                    Path(local_app_data)
                    / "Programs"
                    / "PowerShell"
                    / "7.6.4"
                    / "pwsh.exe"
                )
            )

    checked: set[str] = set()
    for candidate in candidates:
        resolved = str(Path(candidate).resolve())
        if resolved in checked or not Path(resolved).is_file():
            continue
        checked.add(resolved)
        version = subprocess.run(
            [
                resolved,
                "-NoProfile",
                "-Command",
                "Write-Output \"$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)\"",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if version.returncode == 0 and version.stdout.strip() == "Core 7.6.4":
            return resolved
    return None


def test_ffmpeg_distribution_pin_is_immutable_and_traceable() -> None:
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
    assert source["archive_builder"] == {
        "powershell_version": "7.6.4",
        "source_notice_line_endings": "lf",
        "manifest_line_endings": "crlf",
        "zip_compression": "optimal",
        "entry_timestamp": "1980-01-01T00:00:00Z",
    }
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
    assert "Get-RelativeArchivePath" in source_builder
    assert "[System.IO.Path]::GetRelativePath" not in source_builder
    assert "ffmpeg-source-traceability-bundle" in source_builder
    assert "external_library_sources_included" in source_builder
    assert "-Url ([string]$binary.url)" in source_builder
    assert "does not match the immutable pin" in source_builder
    assert "source_asset_pin_verified" in source_builder
    assert "requires PowerShell $requiredPowerShellVersion exactly" in source_builder
    assert 'requirements\\ffmpeg-runtime.json' in publisher
    assert "--clobber" not in publisher
    assert "-Force is intentionally unsupported" in publisher
    assert "server-reported digest" in publisher
    assert "Reproducible TransVortex core binary archive" in publisher
    assert "Complete technical build-input set" in publisher
    assert "external_library_sources_required" in packager
    assert "complete the recorded license review" in packager
    assert "public_distribution_source_ready" in packager
    assert "packagedCorrespondingSourceReady" in installer_builder
    assert "ffmpeg_corresponding_source_sha256" in installer_builder


def test_source_bundle_runs_on_pinned_powershell_and_enforces_output_pin(
    tmp_path: Path,
) -> None:
    powershell = _pinned_powershell()
    if powershell is None:
        pytest.skip("Pinned PowerShell 7.6.4 is not available")

    binary_archive = tmp_path / "binary.zip"
    ffmpeg_archive = tmp_path / "ffmpeg-source.tar.gz"
    build_scripts_archive = tmp_path / "build-scripts.tar.gz"
    binary_archive.write_bytes(b"pinned-binary")
    ffmpeg_archive.write_bytes(b"pinned-ffmpeg-source")
    build_scripts_archive.write_bytes(b"pinned-build-scripts")

    def asset(path: Path, url: str) -> dict[str, object]:
        content = path.read_bytes()
        return {
            "asset_name": path.name,
            "url": url,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    repository = "example/transvortex-assets"
    release_tag = "ffmpeg-runtime-test"
    release_base = f"https://github.com/{repository}/releases/download/{release_tag}"
    source_asset_name = "transvortex-ffmpeg-test-corresponding-source.zip"
    pin: dict[str, object] = {
        "schema_version": 1,
        "id": "transvortex-ffmpeg-runtime",
        "platform": "windows-x64",
        "version": "8.1.2-test",
        "ffmpeg_commit": "1" * 40,
        "variant": "win64-lgpl-shared-8.1",
        "license": "LGPL-3.0-or-later",
        "binary": {
            "build_provider": "example/builds",
            "build_tag": "test-build",
            "build_commit": "2" * 40,
            "asset_name": binary_archive.name,
            "url": f"{release_base}/{binary_archive.name}",
            "upstream_url": "https://example.invalid/upstream/binary.zip",
            "size": binary_archive.stat().st_size,
            "sha256": hashlib.sha256(binary_archive.read_bytes()).hexdigest(),
        },
        "corresponding_source": {
            "scope": "ffmpeg-core-and-build-scripts",
            "external_library_sources_included": False,
            "public_distribution_ready": False,
            "archive_builder": {
                "powershell_version": "7.6.4",
                "source_notice_line_endings": "lf",
                "manifest_line_endings": "crlf",
                "zip_compression": "optimal",
                "entry_timestamp": "1980-01-01T00:00:00Z",
            },
            "repository": repository,
            "release_tag": release_tag,
            "asset_name": source_asset_name,
            "url": f"{release_base}/{source_asset_name}",
            "size": 1,
            "sha256": "0" * 64,
            "ffmpeg_archive": asset(
                ffmpeg_archive,
                "https://example.invalid/upstream/ffmpeg-source.tar.gz",
            ),
            "build_scripts_archive": asset(
                build_scripts_archive,
                "https://example.invalid/upstream/build-scripts.tar.gz",
            ),
        },
    }
    pin_path = tmp_path / "ffmpeg-runtime.json"

    def write_pin() -> None:
        pin_path.write_text(json.dumps(pin, indent=2), encoding="utf-8")

    def run_builder(output_root: Path, *, force: bool = False) -> subprocess.CompletedProcess[str]:
        command = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "scripts" / "build_ffmpeg_source_bundle.ps1"),
            "-PinFile",
            str(pin_path),
            "-OutputRoot",
            str(output_root),
            "-BinaryArchivePath",
            str(binary_archive),
            "-FfmpegSourceArchivePath",
            str(ffmpeg_archive),
            "-BuildScriptsArchivePath",
            str(build_scripts_archive),
            "-Json",
        ]
        if force:
            command.append("-Force")
        return subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    write_pin()
    first_output = tmp_path / "first-output"
    first = run_builder(first_output)
    assert first.returncode != 0
    unpinned_asset = first_output / f"{source_asset_name}.unpinned"
    assert unpinned_asset.is_file(), first.stdout + first.stderr

    source_pin = pin["corresponding_source"]
    assert isinstance(source_pin, dict)
    source_pin["size"] = unpinned_asset.stat().st_size
    source_pin["sha256"] = hashlib.sha256(unpinned_asset.read_bytes()).hexdigest()
    write_pin()

    second = run_builder(first_output, force=True)
    assert second.returncode == 0, second.stdout + second.stderr
    first_asset = first_output / source_asset_name
    assert first_asset.stat().st_size == source_pin["size"]
    assert hashlib.sha256(first_asset.read_bytes()).hexdigest() == source_pin["sha256"]

    second_output = tmp_path / "second-output"
    third = run_builder(second_output)
    assert third.returncode == 0, third.stdout + third.stderr
    second_asset = second_output / source_asset_name
    assert first_asset.read_bytes() == second_asset.read_bytes()
