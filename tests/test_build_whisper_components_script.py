from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest


pytestmark = pytest.mark.skipif(os.name != "nt", reason="Windows PowerShell delivery script")


def _powershell() -> str:
    executable = shutil.which("powershell")
    assert executable is not None
    return executable


def _write_catalog(repo: Path) -> None:
    path = repo / "src" / "transvortex" / "resources" / "asr_components.json"
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "runtime": {
                    "id": "managed:faster-whisper",
                    "version": "1.0.0",
                    "faster_whisper_version": "1.2.1",
                    "ctranslate2_version": "4.8.1",
                    "artifact": {
                        "release_tag": "asr-components-v1.0.0",
                        "asset_name": "runtime.zip",
                    },
                },
                "accelerators": [],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def _copy_script(fake_repo: Path) -> Path:
    source = Path(__file__).resolve().parents[1] / "scripts" / "build_whisper_components.ps1"
    target = fake_repo / "scripts" / source.name
    target.parent.mkdir(parents=True)
    shutil.copy2(source, target)
    return target


def _run(script: Path, output_root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            _powershell(),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            "-OutputRoot",
            str(output_root),
            "-RuntimeOnly",
            "-Force",
        ],
        cwd=script.parents[1],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def test_force_rejects_repository_root_without_deleting_it(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    sentinel = repo / "keep.txt"
    sentinel.write_text("keep", encoding="utf-8")
    script = _copy_script(repo)
    _write_catalog(repo)

    completed = _run(script, repo)

    assert completed.returncode != 0
    assert "repository root" in completed.stderr
    assert sentinel.read_text(encoding="utf-8") == "keep"


def test_force_rejects_unowned_existing_output(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    script = _copy_script(repo)
    _write_catalog(repo)
    output = tmp_path / "unowned-output"
    output.mkdir()
    sentinel = output / "keep.txt"
    sentinel.write_text("keep", encoding="utf-8")

    completed = _run(script, output)

    assert completed.returncode != 0
    assert "unowned OutputRoot" in completed.stderr
    assert sentinel.read_text(encoding="utf-8") == "keep"
