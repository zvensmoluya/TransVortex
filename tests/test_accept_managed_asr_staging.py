from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest


def _load_helper() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts" / "accept_managed_asr_staging.py"
    spec = importlib.util.spec_from_file_location("accept_managed_asr_staging", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


HELPER = _load_helper()


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


@pytest.fixture
def acceptance_fixture(tmp_path: Path) -> dict[str, Any]:
    session_root = tmp_path / "managed-session"
    local_app_data = session_root / "LocalAppData"
    app_data_root = local_app_data / "TransVortex"
    catalog_path = session_root / "catalog" / "asr_components.json"
    build_manifest = tmp_path / "build" / "asr_components_build.json"
    source_catalog = tmp_path / "source" / "asr_components.json"
    stage_report = session_root / "stage_report.json"
    marker = session_root / HELPER.STAGING_MARKER_NAME
    pipeline_seed = tmp_path / "seeds" / "pipeline.yaml"
    providers_seed = tmp_path / "seeds" / "providers.yaml"
    output_report = session_root / "managed_asr_acceptance.json"
    model_content = b"trusted-managed-model"
    model_sha256 = _sha256(model_content)

    catalog = {
        "schema_version": 1,
        "runtime": {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "protocol_version": 1,
            "artifact": {
                "published": True,
                "url": "https://local-staging.invalid/runtime.zip",
                "asset_name": "runtime.zip",
                "size": 10,
                "sha256": "a" * 64,
            },
        },
        "accelerators": [
            {
                "id": HELPER.ACCELERATOR_ID,
                "version": "12.4",
                "artifact": {
                "published": True,
                "url": "https://local-staging.invalid/accelerator.zip",
                "asset_name": "accelerator.zip",
                "size": 11,
                    "sha256": "b" * 64,
                },
            }
        ],
        "models": [
            {
                "id": "small",
                "repository": "example/model",
                "revision": "pinned-revision",
                "files": [
                    {
                        "path": "model.bin",
                        "size": len(model_content),
                        "sha256": model_sha256,
                    }
                ],
            }
        ],
    }
    _write_json(catalog_path, catalog)
    _write_json(source_catalog, {**catalog, "runtime": {**catalog["runtime"], "artifact": {"published": False}}})
    component_snapshot = [
        {
            "kind": "runtime",
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "asset_name": "runtime.zip",
            "size": 10,
            "sha256": "a" * 64,
            "url": "https://local-staging.invalid/runtime.zip",
        },
        {
            "kind": "accelerator",
            "id": HELPER.ACCELERATOR_ID,
            "version": "12.4",
            "asset_name": "accelerator.zip",
            "size": 11,
            "sha256": "b" * 64,
            "url": "https://local-staging.invalid/accelerator.zip",
        },
    ]
    _write_json(
        build_manifest,
        {
            "schema_version": 1,
            "release_tag": "asr-components-v1.0.0",
            "assets": [
                {key: row[key] for key in ("kind", "id", "version", "asset_name", "size", "sha256")}
                for row in component_snapshot
            ],
        },
    )
    _write_json(
        marker,
        {
            "schema_version": 1,
            "owner": HELPER.STAGING_OWNER,
            "session_root": str(session_root.resolve()),
        },
    )
    pipeline_seed.parent.mkdir(parents=True, exist_ok=True)
    pipeline_seed.write_text(
        """config_schema_version: 2
asr: {engine: faster_whisper_large_v3}
asr_engines:
  - id: faster_whisper_large_v3
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
""",
        encoding="utf-8",
    )
    providers_seed.write_text("providers: []\n", encoding="utf-8")
    _write_json(
        stage_report,
        {
            "schema_version": 1,
            "ok": True,
            "plan_only": False,
            "side_effects_applied": True,
            "generated_at": "2026-07-18T00:00:00+00:00",
            "session": {
                "root": str(session_root.resolve()),
                "ownership_marker": str(marker.resolve()),
                "report_path": str(stage_report.resolve()),
            },
            "environment": {
                "LOCALAPPDATA": str(local_app_data.resolve()),
                "TRANSVORTEX_ASR_CATALOG": str(catalog_path.resolve()),
            },
            "catalog": {
                "source_path": str(source_catalog.resolve()),
                "staged_path": str(catalog_path.resolve()),
                "schema_version": 1,
            },
            "build_manifest": {
                "path": str(build_manifest.resolve()),
                "schema_version": 1,
                "release_tag": "asr-components-v1.0.0",
            },
            "components": component_snapshot,
            "model": {
                "id": "small",
                "repository": "example/model",
                "revision": "pinned-revision",
                "files": [
                    {
                        "path": "model.bin",
                        "size": len(model_content),
                        "sha256": model_sha256,
                    }
                ],
            },
        },
    )
    return {
        "session_root": session_root,
        "app_data_root": app_data_root,
        "stage_report": stage_report,
        "pipeline_seed": pipeline_seed,
        "providers_seed": providers_seed,
        "output_report": output_report,
        "catalog": catalog,
        "model_content": model_content,
    }


class _FakeDesktopApi:
    def __init__(self, *, root_dir: Path, providers_file: Path) -> None:
        self.root_dir = Path(root_dir)
        self.app_data_root = self.root_dir.parent
        self.providers_file = Path(providers_file)

    def dispatch(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "asr.component.install":
            kind = str(params["kind"])
            item_id = str(params.get("item_id") or "managed:faster-whisper")
            self._materialize(kind)
            return {
                "id": f"op-{kind}",
                "kind": kind,
                "item_id": item_id,
                "state": "completed",
                "bytes_done": 1,
                "bytes_total": 1,
            }
        if method == "asr.hardware.probe":
            return {"ok": True, "cuda": {"available": True, "compute_types": ["int8_float16"]}}
        if method == "asr.status":
            return {
                "provider": "faster_whisper_large_v3",
                "kind": "local_worker",
                "protocol": "faster_whisper",
                "model": "small",
                "readiness": {"can_run": True, "state": "ready", "code": "ready"},
            }
        if method == "asr.provider.test":
            return {
                "ok": True,
                "code": "ready",
                "provider": params["provider"],
                "protocol": "faster_whisper",
                "row_count": 0,
                "transport": {
                    "transport": "stdio_jsonl",
                    "runtime_source": "managed",
                    "device": "cuda",
                    "compute_type": "int8_float16",
                },
            }
        raise AssertionError(f"Unexpected API method: {method}")

    def _materialize(self, kind: str) -> None:
        if kind == "runtime":
            _write_json(
                self.app_data_root / "Components" / "faster-whisper" / "1.0.0" / "component.json",
                {"id": "managed:faster-whisper", "version": "1.0.0", "protocol_version": 1},
            )
        elif kind == "accelerator":
            _write_json(
                self.app_data_root
                / "Components"
                / "accelerators"
                / HELPER.ACCELERATOR_ID
                / "12.4"
                / "component.json",
                {"id": HELPER.ACCELERATOR_ID, "version": "12.4"},
            )
        elif kind == "model":
            model_root = (
                self.app_data_root
                / "Models"
                / "faster-whisper"
                / "small"
                / "pinned-revision"
            )
            _write_json(
                model_root / "model.json",
                {"id": "small", "revision": "pinned-revision", "repository": "example/model"},
            )
            (model_root / "model.bin").write_bytes(b"trusted-managed-model")
        else:
            raise AssertionError(f"Unexpected component kind: {kind}")


def _run(acceptance_fixture: dict[str, Any], **overrides: Any) -> dict[str, Any]:
    arguments = {
        "stage_report_path": acceptance_fixture["stage_report"],
        "pipeline_seed": acceptance_fixture["pipeline_seed"],
        "providers_seed": acceptance_fixture["providers_seed"],
        "output_report": acceptance_fixture["output_report"],
        "api_factory": _FakeDesktopApi,
        "poll_interval_seconds": 0.0,
    }
    arguments.update(overrides)
    return HELPER.run_acceptance(**arguments)


def test_plan_only_is_side_effect_free(acceptance_fixture: dict[str, Any]) -> None:
    report = _run(acceptance_fixture, plan_only=True)

    assert report["ok"] is True
    assert report["plan_only"] is True
    assert report["side_effects_applied"] is False
    assert not acceptance_fixture["output_report"].exists()
    assert not (acceptance_fixture["app_data_root"] / "Config").exists()


def test_acceptance_installs_components_and_records_model_hashes(
    acceptance_fixture: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", r"D:\unrelated-home")
    monkeypatch.setenv("LOCALAPPDATA", r"D:\normal-local-app-data")
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", r"D:\normal-catalog.json")

    report = _run(acceptance_fixture)

    assert report["ok"] is True
    assert [row["state"] for row in report["operations"]] == [
        "completed",
        "completed",
        "completed",
    ]
    assert report["asr_status"]["readiness"]["can_run"] is True
    assert report["provider_test"]["transport"]["runtime_source"] == "managed"
    assert report["provider_test"]["model_load_verified"] is True
    assert report["model"]["files"][0]["catalog_match"] is True
    assert json.loads(acceptance_fixture["output_report"].read_text(encoding="utf-8"))["ok"] is True
    assert os.environ["TRANSVORTEX_HOME"] == r"D:\unrelated-home"
    assert os.environ["LOCALAPPDATA"] == r"D:\normal-local-app-data"
    assert os.environ["TRANSVORTEX_ASR_CATALOG"] == r"D:\normal-catalog.json"


def test_rejects_output_outside_owned_session(acceptance_fixture: dict[str, Any], tmp_path: Path) -> None:
    outside = tmp_path / "outside.json"

    with pytest.raises(ValueError, match="owned staging session"):
        _run(acceptance_fixture, output_report=outside, plan_only=True)

    assert not outside.exists()


def test_rejects_invalid_ownership_marker(acceptance_fixture: dict[str, Any]) -> None:
    marker = acceptance_fixture["session_root"] / HELPER.STAGING_MARKER_NAME
    payload = json.loads(marker.read_text(encoding="utf-8"))
    payload["owner"] = "Unrelated.Tool"
    _write_json(marker, payload)

    with pytest.raises(ValueError, match="ownership marker"):
        _run(acceptance_fixture, plan_only=True)


def test_rejects_staged_catalog_mutation(acceptance_fixture: dict[str, Any]) -> None:
    catalog_path = acceptance_fixture["session_root"] / "catalog" / "asr_components.json"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    catalog["runtime"]["version"] = "tampered"
    _write_json(catalog_path, catalog)

    with pytest.raises(ValueError, match="differ"):
        _run(acceptance_fixture)


def test_rejects_report_inside_managed_evidence_tree(acceptance_fixture: dict[str, Any]) -> None:
    output = acceptance_fixture["app_data_root"] / "Config" / "pipeline.yaml"

    with pytest.raises(ValueError, match="session root or its reports"):
        _run(acceptance_fixture, output_report=output, plan_only=True)
