from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest


POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


@dataclass(frozen=True)
class StagingFixture:
    script: Path
    manifest: Path
    model_root: Path
    catalog: Path
    runtime_asset: Path
    accelerator_asset: Path
    model_files: dict[str, bytes]


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _isolated_powershell_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in tuple(environment):
        if key.casefold() == "psmodulepath":
            environment.pop(key)
    return environment


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


@pytest.fixture
def staging_fixture(tmp_path: Path) -> StagingFixture:
    source_script = Path(__file__).resolve().parents[1] / "scripts" / "stage_managed_asr_e2e.ps1"
    fake_repo = tmp_path / "repo"
    script = fake_repo / "scripts" / source_script.name
    script.parent.mkdir(parents=True)
    shutil.copy2(source_script, script)

    build_root = fake_repo / "dist" / "asr-components" / "1.0.0"
    build_root.mkdir(parents=True)
    runtime_asset = build_root / "runtime.zip"
    accelerator_asset = build_root / "accelerator.zip"
    runtime_content = b"fake-runtime-zip"
    accelerator_content = b"fake-accelerator-zip"
    runtime_asset.write_bytes(runtime_content)
    accelerator_asset.write_bytes(accelerator_content)

    model_root = fake_repo / "model-source"
    model_files = {
        "config.json": b'{"model":"small"}',
        "nested/model.bin": b"fake-pinned-model",
    }
    for relative_path, content in model_files.items():
        target = model_root.joinpath(*relative_path.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    catalog = fake_repo / "src" / "transvortex" / "resources" / "asr_components.json"
    _write_json(
        catalog,
        {
            "schema_version": 1,
            "runtime": {
                "id": "managed:faster-whisper",
                "version": "1.0.0",
                "artifact": {
                    "published": False,
                    "release_tag": "asr-components-v1.0.0",
                    "asset_name": runtime_asset.name,
                    "url": "https://example.invalid/runtime.zip",
                    "size": 0,
                    "sha256": "",
                },
            },
            "accelerators": [
                {
                    "id": "nvidia-cuda12",
                    "version": "12.4",
                    "artifact": {
                        "published": False,
                        "release_tag": "asr-components-v1.0.0",
                        "asset_name": accelerator_asset.name,
                        "url": "https://example.invalid/accelerator.zip",
                        "size": 0,
                        "sha256": "",
                    },
                }
            ],
            "models": [
                {
                    "id": "small",
                    "repository": "example/faster-whisper-small",
                    "revision": "pinned-revision",
                    "files": [
                        {
                            "path": relative_path,
                            "size": len(content),
                            "sha256": _sha256(content),
                        }
                        for relative_path, content in model_files.items()
                    ],
                }
            ],
        },
    )

    manifest = build_root / "asr_components_build.json"
    _write_json(
        manifest,
        {
            "schema_version": 1,
            "release_tag": "asr-components-v1.0.0",
            "assets": [
                {
                    "kind": "runtime",
                    "id": "managed:faster-whisper",
                    "version": "1.0.0",
                    "path": runtime_asset.name,
                    "asset_name": runtime_asset.name,
                    "size": len(runtime_content),
                    "sha256": _sha256(runtime_content),
                },
                {
                    "kind": "accelerator",
                    "id": "nvidia-cuda12",
                    "version": "12.4",
                    "path": accelerator_asset.name,
                    "asset_name": accelerator_asset.name,
                    "size": len(accelerator_content),
                    "sha256": _sha256(accelerator_content),
                },
            ],
        },
    )
    return StagingFixture(
        script=script,
        manifest=manifest,
        model_root=model_root,
        catalog=catalog,
        runtime_asset=runtime_asset,
        accelerator_asset=accelerator_asset,
        model_files=model_files,
    )


def _run_staging(
    fixture: StagingFixture,
    session_root: Path,
    *extra_arguments: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    if POWERSHELL is None:
        pytest.skip("PowerShell is required for the managed ASR staging script test")
    command = [
        POWERSHELL,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(fixture.script),
        "-BuildManifest",
        str(fixture.manifest),
        "-ModelId",
        "small",
        "-ModelPath",
        str(fixture.model_root),
        "-SessionRoot",
        str(session_root),
        *extra_arguments,
        "-Json",
    ]
    return subprocess.run(
        command,
        cwd=fixture.script.parents[1],
        env=_isolated_powershell_environment(),
        check=check,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def test_plan_only_validates_all_inputs_without_side_effects(
    staging_fixture: StagingFixture,
    tmp_path: Path,
) -> None:
    session_root = tmp_path / "plan-session"

    completed = _run_staging(staging_fixture, session_root, "-PlanOnly")
    report = json.loads(completed.stdout)

    assert report["ok"] is True
    assert report["plan_only"] is True
    assert report["side_effects_applied"] is False
    assert report["session"]["disposition"] == "create"
    assert report["environment"]["LOCALAPPDATA"] == str(session_root / "LocalAppData")
    assert report["environment"]["TRANSVORTEX_ASR_CATALOG"] == str(
        session_root / "catalog" / "asr_components.json"
    )
    assert not session_root.exists()


def test_stages_verified_components_model_and_catalog_copy(
    staging_fixture: StagingFixture,
    tmp_path: Path,
) -> None:
    session_root = tmp_path / "stage-session"
    source_catalog_before = staging_fixture.catalog.read_bytes()

    completed = _run_staging(staging_fixture, session_root)
    report = json.loads(completed.stdout)

    assert report["side_effects_applied"] is True
    assert Path(report["session"]["ownership_marker"]).is_file()
    assert Path(report["session"]["report_path"]).is_file()
    assert staging_fixture.catalog.read_bytes() == source_catalog_before

    staged_catalog = json.loads(Path(report["catalog"]["staged_path"]).read_text(encoding="utf-8"))
    assert staged_catalog["runtime"]["artifact"] == {
        **staged_catalog["runtime"]["artifact"],
        "published": True,
        "size": staging_fixture.runtime_asset.stat().st_size,
        "sha256": _sha256(staging_fixture.runtime_asset.read_bytes()),
        "url": "https://local-staging.invalid/runtime.zip",
    }
    assert staged_catalog["accelerators"][0]["artifact"]["published"] is True
    assert staged_catalog["accelerators"][0]["artifact"]["url"] == (
        "https://local-staging.invalid/accelerator.zip"
    )

    for component in report["components"]:
        destination = Path(component["destination_part"])
        assert destination.is_file()
        assert destination.read_bytes() == Path(component["source_path"]).read_bytes()
        assert destination.name == f'{component["asset_name"]}.part'

    assert report["model"]["revision"] == "pinned-revision"
    for model_file in report["model"]["files"]:
        destination = Path(model_file["destination_part"])
        assert destination.is_file()
        assert destination.read_bytes() == staging_fixture.model_files[model_file["path"]]
        assert destination.name.endswith(".part")


def test_force_only_replaces_owned_session(
    staging_fixture: StagingFixture,
    tmp_path: Path,
) -> None:
    unsafe_root = tmp_path / "unsafe-session"
    unsafe_root.mkdir()
    unsafe_sentinel = unsafe_root / "unrelated.txt"
    unsafe_sentinel.write_text("keep", encoding="utf-8")

    rejected = _run_staging(staging_fixture, unsafe_root, "-Force", check=False)

    assert rejected.returncode != 0
    assert unsafe_sentinel.read_text(encoding="utf-8") == "keep"

    owned_root = tmp_path / "owned-session"
    _run_staging(staging_fixture, owned_root)
    stale_file = owned_root / "stale.txt"
    stale_file.write_text("remove on explicit replacement", encoding="utf-8")

    without_force = _run_staging(staging_fixture, owned_root, check=False)
    assert without_force.returncode != 0
    assert stale_file.is_file()

    replaced = _run_staging(staging_fixture, owned_root, "-Force")
    assert json.loads(replaced.stdout)["session"]["disposition"] == "replace_owned"
    assert not stale_file.exists()


def test_rejects_asset_hash_mismatch_before_creating_session(
    staging_fixture: StagingFixture,
    tmp_path: Path,
) -> None:
    session_root = tmp_path / "hash-mismatch-session"
    staging_fixture.runtime_asset.write_bytes(b"tampered")

    completed = _run_staging(staging_fixture, session_root, check=False)

    assert completed.returncode != 0
    assert not session_root.exists()


def test_rejects_malformed_catalog_size(staging_fixture: StagingFixture, tmp_path: Path) -> None:
    catalog = json.loads(staging_fixture.catalog.read_text(encoding="utf-8"))
    catalog["runtime"]["artifact"]["size"] = "not-a-number"
    _write_json(staging_fixture.catalog, catalog)
    session_root = tmp_path / "malformed-size-session"

    completed = _run_staging(staging_fixture, session_root, "-PlanOnly", check=False)

    assert completed.returncode != 0
    assert "malformed size" in completed.stderr
    assert not session_root.exists()


def test_force_rejects_inputs_inside_owned_session(
    staging_fixture: StagingFixture,
    tmp_path: Path,
) -> None:
    owned_root = tmp_path / "owned-session-with-input"
    _run_staging(staging_fixture, owned_root)
    nested_asset = owned_root / "input" / staging_fixture.runtime_asset.name
    nested_asset.parent.mkdir(parents=True)
    shutil.copy2(staging_fixture.runtime_asset, nested_asset)
    manifest = json.loads(staging_fixture.manifest.read_text(encoding="utf-8"))
    manifest["assets"][0]["path"] = str(nested_asset)
    _write_json(staging_fixture.manifest, manifest)

    completed = _run_staging(staging_fixture, owned_root, "-Force", check=False)

    assert completed.returncode != 0
    assert "input source is inside SessionRoot" in completed.stderr
    assert nested_asset.is_file()
