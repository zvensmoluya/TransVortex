from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping


try:
    from transvortex.app.desktop_api import DesktopApi
except ModuleNotFoundError:
    # Keep the helper runnable from a source checkout without requiring a global
    # PYTHONPATH. Packaged runtimes resolve the installed package before this path.
    _SOURCE_ROOT = Path(__file__).resolve().parents[1] / "src"
    if not _SOURCE_ROOT.is_dir():
        raise
    sys.path.insert(0, str(_SOURCE_ROOT))
    from transvortex.app.desktop_api import DesktopApi


SCHEMA_VERSION = 1
ACCEPTANCE_ID = "TransVortex.ManagedAsrStagingAcceptance"
STAGING_OWNER = "TransVortex.ManagedAsrE2EStaging"
STAGING_MARKER_NAME = ".transvortex-managed-asr-e2e-session.json"
ACCELERATOR_ID = "nvidia-cuda12"
TERMINAL_OPERATION_STATES = {"completed", "failed", "cancelled"}


@dataclass(frozen=True)
class AcceptanceInputs:
    stage_report_path: Path
    stage_report: dict[str, Any]
    session_root: Path
    local_app_data: Path
    app_data_root: Path
    config_root: Path
    catalog_path: Path
    build_manifest_path: Path
    pipeline_seed: Path
    providers_seed: Path
    output_report: Path
    model_id: str


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _same_path(left: Path, right: Path) -> bool:
    return os.path.normcase(str(left.resolve())) == os.path.normcase(str(right.resolve()))


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def _is_link_or_junction(path: Path) -> bool:
    if path.is_symlink():
        return True
    is_junction = getattr(os.path, "isjunction", None)
    return bool(is_junction and is_junction(path))


def _assert_unlinked_path_within(path: Path, root: Path, description: str) -> None:
    lexical = Path(os.path.abspath(os.fspath(path.expanduser())))
    lexical_root = Path(os.path.abspath(os.fspath(root.expanduser())))
    resolved = lexical.resolve()
    resolved_root = lexical_root.resolve()
    if not _is_within(resolved, resolved_root):
        raise ValueError(f"{description} must remain inside the owned staging session")
    current = lexical
    while True:
        if _is_link_or_junction(current):
            raise ValueError(f"{description} traverses a link or junction: {current}")
        if os.path.normcase(str(current)) == os.path.normcase(str(lexical_root)):
            break
        parent = current.parent
        if parent == current:
            raise ValueError(f"{description} escapes the owned staging session")
        current = parent


def _require_mapping(payload: Mapping[str, Any], key: str, context: str) -> dict[str, Any]:
    value = payload.get(key)
    if not isinstance(value, dict):
        raise ValueError(f"{context}.{key} must be an object")
    return value


def _require_text(payload: Mapping[str, Any], key: str, context: str) -> str:
    value = str(payload.get(key) or "").strip()
    if not value:
        raise ValueError(f"{context}.{key} must be a non-empty string")
    return value


def _read_json_object(path: Path, description: str) -> dict[str, Any]:
    resolved = path.expanduser().resolve()
    if not resolved.is_file() or _is_link_or_junction(resolved):
        raise FileNotFoundError(f"{description} must be a regular file: {resolved}")
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{description} is not valid UTF-8 JSON: {resolved}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{description} must contain one JSON object: {resolved}")
    return payload


def _regular_file(path: Path, description: str) -> Path:
    lexical = Path(os.path.abspath(os.fspath(path.expanduser())))
    if _is_link_or_junction(lexical):
        raise FileNotFoundError(f"{description} must be a regular file: {lexical}")
    resolved = lexical.resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"{description} must be a regular file: {resolved}")
    return resolved


def _file_evidence(path: Path) -> dict[str, Any]:
    resolved = _regular_file(path, "Evidence file")
    return {
        "path": str(resolved),
        "size": resolved.stat().st_size,
        "sha256": _sha256(resolved),
    }


def _optional_file_evidence(path: Path) -> dict[str, Any]:
    if not path.is_file() or _is_link_or_junction(path):
        return {"path": str(path.resolve()), "exists": False}
    return {**_file_evidence(path), "exists": True}


def _load_inputs(
    *,
    stage_report_path: Path,
    pipeline_seed: Path,
    providers_seed: Path,
    output_report: Path,
    plan_only: bool,
) -> AcceptanceInputs:
    stage_input = stage_report_path.expanduser()
    stage_path = _regular_file(stage_input, "Staging report")
    stage = _read_json_object(stage_path, "Staging report")
    if int(stage.get("schema_version") or 0) != SCHEMA_VERSION:
        raise ValueError("Staging report schema_version must be 1")
    if stage.get("ok") is not True:
        raise ValueError("Staging report does not describe a successful staging plan")

    session = _require_mapping(stage, "session", "stage")
    environment = _require_mapping(stage, "environment", "stage")
    catalog = _require_mapping(stage, "catalog", "stage")
    build_manifest = _require_mapping(stage, "build_manifest", "stage")
    model = _require_mapping(stage, "model", "stage")

    session_root_input = Path(
        _require_text(session, "root", "stage.session")
    ).expanduser()
    session_root = session_root_input.resolve()
    _assert_unlinked_path_within(stage_input, session_root_input, "Staging report")
    declared_report = Path(
        _require_text(session, "report_path", "stage.session")
    ).expanduser().resolve()
    if not _same_path(stage_path, declared_report):
        raise ValueError("Staging report path does not match stage.session.report_path")
    if not _is_within(stage_path, session_root):
        raise ValueError("Staging report must remain inside its owned session root")
    marker_input = session_root_input / STAGING_MARKER_NAME
    _assert_unlinked_path_within(marker_input, session_root_input, "Staging ownership marker")
    marker_path = marker_input.resolve()
    declared_marker = Path(
        _require_text(session, "ownership_marker", "stage.session")
    ).expanduser().resolve()
    if not _same_path(marker_path, declared_marker):
        raise ValueError("Staging ownership marker path is inconsistent")
    marker = _read_json_object(marker_input, "Staging ownership marker")
    if (
        int(marker.get("schema_version") or 0) != SCHEMA_VERSION
        or marker.get("owner") != STAGING_OWNER
        or not _same_path(
            Path(str(marker.get("session_root") or "")).expanduser(),
            session_root,
        )
    ):
        raise ValueError("Staging ownership marker is invalid or relocated")

    local_app_data_input = Path(
        _require_text(environment, "LOCALAPPDATA", "stage.environment")
    ).expanduser()
    _assert_unlinked_path_within(
        local_app_data_input,
        session_root_input,
        "Isolated LOCALAPPDATA",
    )
    local_app_data = local_app_data_input.resolve()
    expected_local_app_data = (session_root / "LocalAppData").resolve()
    if not _same_path(local_app_data, expected_local_app_data):
        raise ValueError("stage.environment.LOCALAPPDATA is outside the staging session")
    catalog_input = Path(
        _require_text(environment, "TRANSVORTEX_ASR_CATALOG", "stage.environment")
    ).expanduser()
    _assert_unlinked_path_within(catalog_input, session_root_input, "Staged ASR catalog")
    catalog_path = catalog_input.resolve()
    declared_catalog = Path(
        _require_text(catalog, "staged_path", "stage.catalog")
    ).expanduser().resolve()
    if not _same_path(catalog_path, declared_catalog) or not _is_within(catalog_path, session_root):
        raise ValueError("Staged ASR catalog path is inconsistent or outside the session")

    build_path = Path(
        _require_text(build_manifest, "path", "stage.build_manifest")
    ).expanduser().resolve()
    model_id = _require_text(model, "id", "stage.model")
    if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in model_id):
        raise ValueError(f"Unsafe staged model id: {model_id}")

    if not plan_only:
        if stage.get("plan_only") is True or stage.get("side_effects_applied") is not True:
            raise ValueError("Run the staging script without -PlanOnly before machine acceptance")
        if not session_root.is_dir() or _is_link_or_junction(session_root_input):
            raise FileNotFoundError(f"Owned staging session is unavailable: {session_root}")
        _regular_file(catalog_input, "Staged ASR catalog")
        _regular_file(build_path, "ASR build manifest")

    pipeline_path = _regular_file(pipeline_seed, "Pipeline seed")
    providers_path = _regular_file(providers_seed, "Providers seed")
    output_input = output_report.expanduser()
    _assert_unlinked_path_within(output_input, session_root_input, "Output report")
    output_path = output_input.resolve()
    if output_path.exists() and _is_link_or_junction(output_path):
        raise ValueError(f"Output report must not be a link or junction: {output_path}")
    if output_path.exists() and not output_path.is_file():
        raise ValueError(f"Output report path is not a file: {output_path}")
    for source in (
        stage_path,
        marker_path,
        pipeline_path,
        providers_path,
        catalog_path,
        build_path,
    ):
        if _same_path(output_path, source):
            raise ValueError(f"Output report must not overwrite an input file: {source}")

    app_data_root = (local_app_data / "TransVortex").resolve()
    config_root = (app_data_root / "Config").resolve()
    if not _is_within(config_root, session_root):
        raise ValueError("Isolated Config directory escapes the staging session")
    output_parent = output_path.parent.resolve()
    reports_root = (session_root / "reports").resolve()
    if not _same_path(output_parent, session_root) and not _is_within(output_parent, reports_root):
        raise ValueError("Output report must be in the staging session root or its reports directory")

    return AcceptanceInputs(
        stage_report_path=stage_path,
        stage_report=stage,
        session_root=session_root,
        local_app_data=local_app_data,
        app_data_root=app_data_root,
        config_root=config_root,
        catalog_path=catalog_path,
        build_manifest_path=build_path,
        pipeline_seed=pipeline_path,
        providers_seed=providers_path,
        output_report=output_path,
        model_id=model_id,
    )


def _assert_safe_config_path(inputs: AcceptanceInputs) -> None:
    for path in (inputs.local_app_data, inputs.app_data_root, inputs.config_root):
        if path.exists() and _is_link_or_junction(path):
            raise ValueError(f"Refusing linked or junctioned staging directory: {path}")
        if path.exists() and not path.is_dir():
            raise ValueError(f"Staging directory path is not a directory: {path}")


def _copy_file_atomic(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and _is_link_or_junction(destination):
        raise ValueError(f"Refusing linked seed destination: {destination}")
    temporary_name = ""
    try:
        with source.open("rb") as source_handle, tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as destination_handle:
            temporary_name = destination_handle.name
            shutil.copyfileobj(source_handle, destination_handle, length=1024 * 1024)
            destination_handle.flush()
            os.fsync(destination_handle.fileno())
        os.replace(temporary_name, destination)
        temporary_name = ""
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


@contextmanager
def _isolated_environment(inputs: AcceptanceInputs) -> Iterator[None]:
    keys = ("LOCALAPPDATA", "TRANSVORTEX_ASR_CATALOG", "TRANSVORTEX_HOME")
    previous = {key: os.environ.get(key) for key in keys}
    os.environ["LOCALAPPDATA"] = str(inputs.local_app_data)
    os.environ["TRANSVORTEX_ASR_CATALOG"] = str(inputs.catalog_path)
    os.environ.pop("TRANSVORTEX_HOME", None)
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _operation_summary(operation: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: operation.get(key)
        for key in (
            "id",
            "kind",
            "item_id",
            "state",
            "bytes_done",
            "bytes_total",
            "error_code",
            "created_at",
            "updated_at",
        )
        if key in operation
    }


def _install_component(
    api: Any,
    *,
    kind: str,
    item_id: str,
    timeout_seconds: float,
    poll_interval_seconds: float,
    sleep: Callable[[float], None],
    monotonic: Callable[[], float],
) -> dict[str, Any]:
    params = {"kind": kind}
    if item_id:
        params["item_id"] = item_id
    operation = api.dispatch("asr.component.install", params)
    if not isinstance(operation, dict):
        raise RuntimeError(f"ASR {kind} install did not return an operation object")
    operation_id = str(operation.get("id") or "").strip()
    if not operation_id:
        raise RuntimeError(f"ASR {kind} install did not return an operation id")

    deadline = monotonic() + timeout_seconds
    while str(operation.get("state") or "").lower() not in TERMINAL_OPERATION_STATES:
        remaining = deadline - monotonic()
        if remaining <= 0:
            try:
                api.dispatch("asr.operation.cancel", {"operation_id": operation_id})
            except Exception:
                pass
            raise TimeoutError(f"Timed out waiting for ASR {kind} install: {item_id or 'runtime'}")
        sleep(min(max(poll_interval_seconds, 0.0), remaining))
        operation = api.dispatch("asr.operation.get", {"operation_id": operation_id})
        if not isinstance(operation, dict):
            raise RuntimeError(f"ASR {kind} operation poll returned an invalid payload")

    if str(operation.get("state") or "").lower() != "completed":
        code = str(operation.get("error_code") or "install_failed")
        raise RuntimeError(f"ASR {kind} install did not complete: {code}")
    return _operation_summary(operation)


def _catalog_entries(catalog: Mapping[str, Any], model_id: str) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    if int(catalog.get("schema_version") or 0) != SCHEMA_VERSION:
        raise ValueError("Staged ASR catalog schema_version must be 1")
    runtime = catalog.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError("Staged ASR catalog is missing runtime")
    accelerator = next(
        (
            row
            for row in catalog.get("accelerators") or []
            if isinstance(row, dict) and row.get("id") == ACCELERATOR_ID
        ),
        None,
    )
    if not isinstance(accelerator, dict):
        raise ValueError(f"Staged ASR catalog is missing accelerator {ACCELERATOR_ID}")
    model = next(
        (
            row
            for row in catalog.get("models") or []
            if isinstance(row, dict) and row.get("id") == model_id
        ),
        None,
    )
    if not isinstance(model, dict):
        raise ValueError(f"Staged ASR catalog is missing model {model_id}")
    return runtime, accelerator, model


def _required_digest(value: Any, context: str) -> str:
    digest = str(value or "").strip().lower()
    if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        raise ValueError(f"{context} must contain a SHA-256 digest")
    return digest


def _validate_stage_snapshot(
    inputs: AcceptanceInputs,
    catalog: Mapping[str, Any],
    build_manifest: Mapping[str, Any],
) -> None:
    staged_components = inputs.stage_report.get("components")
    if not isinstance(staged_components, list) or not staged_components:
        raise ValueError("Staging report is missing its component snapshot")
    manifest_assets = build_manifest.get("assets")
    if not isinstance(manifest_assets, list) or len(manifest_assets) != len(staged_components):
        raise ValueError("Staging report and build manifest component snapshots differ")

    catalog_entries: list[tuple[str, dict[str, Any]]] = []
    runtime = catalog.get("runtime")
    if isinstance(runtime, dict):
        catalog_entries.append(("runtime", runtime))
    catalog_entries.extend(
        ("accelerator", row)
        for row in catalog.get("accelerators") or []
        if isinstance(row, dict)
    )
    if len(catalog_entries) != len(staged_components):
        raise ValueError("Staged catalog component count changed after staging")

    def identity(row: Mapping[str, Any], context: str) -> tuple[str, str, str, str, int, str]:
        artifact = row.get("artifact") if isinstance(row.get("artifact"), dict) else row
        return (
            str(row.get("id") or "").strip(),
            str(row.get("version") or "").strip(),
            str(artifact.get("asset_name") or "").strip(),
            str(artifact.get("url") or "").strip(),
            int(artifact.get("size") or 0),
            _required_digest(artifact.get("sha256"), f"{context}.sha256"),
        )

    staged_by_key = {
        (str(row.get("kind") or ""), str(row.get("id") or "")): row
        for row in staged_components
        if isinstance(row, dict)
    }
    manifest_by_key = {
        (str(row.get("kind") or ""), str(row.get("id") or "")): row
        for row in manifest_assets
        if isinstance(row, dict)
    }
    if len(staged_by_key) != len(staged_components) or len(manifest_by_key) != len(manifest_assets):
        raise ValueError("Staging component snapshot contains duplicate or invalid identities")

    for kind, entry in catalog_entries:
        key = (kind, str(entry.get("id") or ""))
        staged = staged_by_key.get(key)
        manifest = manifest_by_key.get(key)
        if staged is None or manifest is None:
            raise ValueError(f"Staging snapshot is missing {kind} {key[1]}")
        catalog_identity = identity(entry, f"catalog.{kind}.{key[1]}")
        snapshot_identity = (
            str(staged.get("id") or "").strip(),
            str(staged.get("version") or "").strip(),
            str(staged.get("asset_name") or "").strip(),
            str(staged.get("url") or "").strip(),
            int(staged.get("size") or 0),
            _required_digest(staged.get("sha256"), f"stage.components.{key[1]}.sha256"),
        )
        manifest_identity = (
            str(manifest.get("id") or "").strip(),
            str(manifest.get("version") or "").strip(),
            str(manifest.get("asset_name") or "").strip(),
            "",
            int(manifest.get("size") or 0),
            _required_digest(manifest.get("sha256"), f"build.assets.{key[1]}.sha256"),
        )
        if catalog_identity != snapshot_identity or catalog_identity[:3] + catalog_identity[4:] != manifest_identity[:3] + manifest_identity[4:]:
            raise ValueError(f"Staged catalog, component snapshot and build manifest differ for {kind} {key[1]}")

    stage_model = inputs.stage_report.get("model")
    if not isinstance(stage_model, dict):
        raise ValueError("Staging report is missing its model snapshot")
    model_id = str(stage_model.get("id") or "")
    models = [
        row
        for row in catalog.get("models") or []
        if isinstance(row, dict) and str(row.get("id") or "") == model_id
    ]
    if len(models) != 1:
        raise ValueError(f"Staged catalog model snapshot is missing or ambiguous: {model_id}")
    catalog_model = models[0]
    for key in ("id", "repository", "revision"):
        if str(stage_model.get(key) or "") != str(catalog_model.get(key) or ""):
            raise ValueError(f"Staged catalog model field changed: {key}")
    stage_files = stage_model.get("files")
    catalog_files = catalog_model.get("files")
    if not isinstance(stage_files, list) or not isinstance(catalog_files, list) or len(stage_files) != len(catalog_files):
        raise ValueError("Staged catalog model file snapshot changed")
    def model_file_key(row: Mapping[str, Any], context: str) -> tuple[str, int, str]:
        return (
            str(row.get("path") or "").replace("\\", "/"),
            int(row.get("size") or 0),
            _required_digest(row.get("sha256"), f"{context}.sha256"),
        )
    if sorted(model_file_key(row, "stage.model.files") for row in stage_files if isinstance(row, dict)) != sorted(model_file_key(row, "catalog.models.files") for row in catalog_files if isinstance(row, dict)):
        raise ValueError("Staged catalog model file hashes changed after staging")


def _marker_evidence(
    path: Path,
    *,
    expected: Mapping[str, Any],
    identity_keys: tuple[str, ...],
) -> dict[str, Any]:
    marker = _read_json_object(path, "Installed component marker")
    identity: dict[str, Any] = {}
    for key in identity_keys:
        expected_value = expected.get(key)
        if marker.get(key) != expected_value:
            raise RuntimeError(
                f"Installed component marker mismatch for {key}: expected {expected_value!r}"
            )
        identity[key] = marker.get(key)
    for key in ("python", "protocol_version", "installed_at", "root", "repository"):
        if key in marker and key not in identity:
            identity[key] = marker[key]
    return {**_file_evidence(path), "identity": identity}


def _model_file_evidence(model_root: Path, model: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw in model.get("files") or []:
        if not isinstance(raw, dict):
            raise ValueError("Staged model catalog contains a non-object file entry")
        relative = str(raw.get("path") or "").replace("\\", "/").strip("/")
        parts = relative.split("/") if relative else []
        if not parts or any(part in {"", ".", ".."} for part in parts):
            raise ValueError(f"Unsafe staged model file path: {relative!r}")
        target_path = model_root.joinpath(*parts)
        if _is_link_or_junction(target_path):
            raise ValueError(f"Installed model file must not be a link or junction: {relative}")
        target = target_path.resolve()
        if not _is_within(target, model_root):
            raise ValueError(f"Staged model file escapes its install root: {relative}")
        evidence = _file_evidence(target)
        expected_size = int(raw.get("size") or 0)
        expected_sha256 = str(raw.get("sha256") or "").lower()
        if evidence["size"] != expected_size or evidence["sha256"] != expected_sha256:
            raise RuntimeError(f"Installed model file does not match the catalog: {relative}")
        rows.append(
            {
                "path": relative,
                "size": evidence["size"],
                "sha256": evidence["sha256"],
                "catalog_match": True,
            }
        )
    if not rows:
        raise ValueError("Staged model catalog contains no files")
    return rows


def _base_evidence(inputs: AcceptanceInputs) -> dict[str, Any]:
    stage_catalog = _require_mapping(inputs.stage_report, "catalog", "stage")
    source_catalog = Path(
        _require_text(stage_catalog, "source_path", "stage.catalog")
    ).expanduser().resolve()
    build = _require_mapping(inputs.stage_report, "build_manifest", "stage")
    python_path = Path(sys.executable).resolve()
    return {
        "stage": {
            **_file_evidence(inputs.stage_report_path),
            "session_root": str(inputs.session_root),
            "generated_at": str(inputs.stage_report.get("generated_at") or ""),
            "ownership_marker": _file_evidence(
                inputs.session_root / STAGING_MARKER_NAME
            ),
        },
        "catalog": {
            "source": _optional_file_evidence(source_catalog),
            "staged": _optional_file_evidence(inputs.catalog_path),
            "schema_version": int(stage_catalog.get("schema_version") or 0),
        },
        "build_manifest": {
            **_optional_file_evidence(inputs.build_manifest_path),
            "schema_version": int(build.get("schema_version") or 0),
            "release_tag": str(build.get("release_tag") or ""),
        },
        "python": {
            **_file_evidence(python_path),
            "version": sys.version.split()[0],
            "implementation": sys.implementation.name,
        },
        "seeds": {
            "pipeline": _file_evidence(inputs.pipeline_seed),
            "providers": _file_evidence(inputs.providers_seed),
        },
    }


def acceptance_plan(inputs: AcceptanceInputs) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "acceptance": ACCEPTANCE_ID,
        "ok": True,
        "plan_only": True,
        "side_effects_applied": False,
        "generated_at": _utc_now(),
        "evidence": _base_evidence(inputs),
        "isolated_paths": {
            "local_app_data": str(inputs.local_app_data),
            "app_data_root": str(inputs.app_data_root),
            "config_root": str(inputs.config_root),
            "catalog_override": str(inputs.catalog_path),
            "output_report": str(inputs.output_report),
        },
        "actions": [
            "copy_pipeline_seed",
            "copy_providers_seed",
            "install_runtime",
            f"install_accelerator:{ACCELERATOR_ID}",
            f"install_model:{inputs.model_id}",
            "probe_hardware",
            "assert_asr_ready",
            "load_model_and_transcribe_probe_audio",
            "hash_installed_model_files",
            "write_acceptance_report",
        ],
    }


def _write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as handle:
            temporary_name = handle.name
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        temporary_name = ""
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


def run_acceptance(
    *,
    stage_report_path: Path,
    pipeline_seed: Path,
    providers_seed: Path,
    output_report: Path,
    timeout_seconds: float = 3600.0,
    source_lang: str = "en",
    plan_only: bool = False,
    api_factory: Callable[..., Any] | None = None,
    poll_interval_seconds: float = 0.25,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be greater than zero")
    normalized_source_lang = source_lang.strip()
    if not normalized_source_lang:
        raise ValueError("source_lang must be non-empty")
    inputs = _load_inputs(
        stage_report_path=stage_report_path,
        pipeline_seed=pipeline_seed,
        providers_seed=providers_seed,
        output_report=output_report,
        plan_only=plan_only,
    )
    if plan_only:
        return acceptance_plan(inputs)

    catalog = _read_json_object(inputs.catalog_path, "Staged ASR catalog")
    build_manifest = _read_json_object(inputs.build_manifest_path, "ASR build manifest")
    _validate_stage_snapshot(inputs, catalog, build_manifest)
    runtime, accelerator, model = _catalog_entries(catalog, inputs.model_id)
    _assert_safe_config_path(inputs)
    _copy_file_atomic(inputs.pipeline_seed, inputs.config_root / "pipeline.yaml")
    _copy_file_atomic(inputs.providers_seed, inputs.config_root / "providers.yaml")

    operations: list[dict[str, Any]] = []
    with _isolated_environment(inputs):
        factory = api_factory or DesktopApi
        api = factory(
            root_dir=inputs.config_root,
            providers_file=inputs.config_root / "providers.yaml",
        )
        operations.append(
            _install_component(
                api,
                kind="runtime",
                item_id="",
                timeout_seconds=timeout_seconds,
                poll_interval_seconds=poll_interval_seconds,
                sleep=sleep,
                monotonic=monotonic,
            )
        )
        operations.append(
            _install_component(
                api,
                kind="accelerator",
                item_id=ACCELERATOR_ID,
                timeout_seconds=timeout_seconds,
                poll_interval_seconds=poll_interval_seconds,
                sleep=sleep,
                monotonic=monotonic,
            )
        )
        operations.append(
            _install_component(
                api,
                kind="model",
                item_id=inputs.model_id,
                timeout_seconds=timeout_seconds,
                poll_interval_seconds=poll_interval_seconds,
                sleep=sleep,
                monotonic=monotonic,
            )
        )

        hardware = api.dispatch("asr.hardware.probe", {})
        if not isinstance(hardware, dict) or hardware.get("ok") is not True:
            raise RuntimeError("Managed ASR hardware probe did not succeed")
        cuda = hardware.get("cuda")
        if not isinstance(cuda, dict) or cuda.get("available") is not True:
            raise RuntimeError("Managed ASR staging acceptance requires an available CUDA device")
        status = api.dispatch("asr.status", {})
        if not isinstance(status, dict):
            raise RuntimeError("ASR status returned an invalid payload")
        readiness = status.get("readiness")
        if not isinstance(readiness, dict) or any(
            (
                readiness.get("can_run") is not True,
                readiness.get("state") != "ready",
                readiness.get("code") != "ready",
            )
        ):
            raise RuntimeError("Managed ASR provider is not ready after component installation")
        provider_test = api.dispatch(
            "asr.provider.test",
            {"provider": status.get("provider"), "source_lang": normalized_source_lang},
        )
        if not isinstance(provider_test, dict) or provider_test.get("ok") is not True:
            raise RuntimeError("Managed ASR provider test did not load and exercise the model")
        transport = provider_test.get("transport")
        if not isinstance(transport, dict) or any(
            (
                transport.get("transport") != "stdio_jsonl",
                transport.get("runtime_source") != "managed",
                transport.get("device") != "cuda",
                not str(transport.get("compute_type") or "").strip(),
            )
        ):
            raise RuntimeError("Managed ASR provider test returned incomplete transport evidence")

    runtime_root = (
        inputs.app_data_root / "Components" / "faster-whisper" / _require_text(runtime, "version", "catalog.runtime")
    )
    accelerator_root = (
        inputs.app_data_root
        / "Components"
        / "accelerators"
        / ACCELERATOR_ID
        / _require_text(accelerator, "version", "catalog.accelerator")
    )
    model_root = (
        inputs.app_data_root
        / "Models"
        / "faster-whisper"
        / inputs.model_id
        / _require_text(model, "revision", "catalog.model")
    )
    markers = {
        "runtime": _marker_evidence(
            runtime_root / "component.json",
            expected=runtime,
            identity_keys=("id", "version"),
        ),
        "accelerator": _marker_evidence(
            accelerator_root / "component.json",
            expected=accelerator,
            identity_keys=("id", "version"),
        ),
        "model": _marker_evidence(
            model_root / "model.json",
            expected=model,
            identity_keys=("id", "revision"),
        ),
    }
    model_files = _model_file_evidence(model_root, model)

    provider_test_evidence = {
        key: provider_test.get(key)
        for key in ("ok", "code", "provider", "protocol", "row_count", "checked_at")
        if key in provider_test
    }
    provider_test_evidence["source_lang"] = normalized_source_lang
    provider_test_evidence["transport"] = dict(transport)
    provider_test_evidence["model_load_verified"] = True
    provider_test_evidence["verification_basis"] = "successful_stdio_jsonl_transcription_probe"

    report = {
        "schema_version": SCHEMA_VERSION,
        "acceptance": ACCEPTANCE_ID,
        "ok": True,
        "plan_only": False,
        "side_effects_applied": True,
        "generated_at": _utc_now(),
        "evidence": _base_evidence(inputs),
        "isolated_paths": {
            "local_app_data": str(inputs.local_app_data),
            "app_data_root": str(inputs.app_data_root),
            "config_root": str(inputs.config_root),
            "catalog_override": str(inputs.catalog_path),
        },
        "environment_guards": {
            "TRANSVORTEX_HOME_cleared_during_acceptance": True,
            "catalog_override_is_isolated": True,
        },
        "operations": operations,
        "hardware_probe": hardware,
        "asr_status": {
            "provider": status.get("provider"),
            "kind": status.get("kind"),
            "protocol": status.get("protocol"),
            "model": status.get("model"),
            "readiness": readiness,
        },
        "provider_test": provider_test_evidence,
        "component_markers": markers,
        "model": {
            "id": inputs.model_id,
            "revision": model.get("revision"),
            "root": str(model_root),
            "file_count": len(model_files),
            "files": model_files,
        },
    }
    _write_json_atomic(inputs.output_report, report)
    return report


def _failure_report(args: argparse.Namespace, exc: Exception) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "acceptance": ACCEPTANCE_ID,
        "ok": False,
        "plan_only": bool(args.plan_only),
        "side_effects_applied": False,
        "generated_at": _utc_now(),
        "stage_report": str(Path(args.stage_report).expanduser().resolve()),
        "error": {
            "type": type(exc).__name__,
            "message": str(exc),
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Install and machine-accept isolated managed ASR staging assets."
    )
    parser.add_argument("--stage-report", "--staging-report", dest="stage_report", required=True)
    parser.add_argument("--pipeline-seed", required=True)
    parser.add_argument("--providers-seed", required=True)
    parser.add_argument("--output-report", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument("--source-lang", default="en")
    parser.add_argument("--plan-only", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = run_acceptance(
            stage_report_path=Path(args.stage_report),
            pipeline_seed=Path(args.pipeline_seed),
            providers_seed=Path(args.providers_seed),
            output_report=Path(args.output_report),
            timeout_seconds=args.timeout_seconds,
            source_lang=args.source_lang,
            plan_only=args.plan_only,
        )
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001 - CLI emits one structured failure
        failure = _failure_report(args, exc)
        if not args.plan_only:
            try:
                safe_inputs = _load_inputs(
                    stage_report_path=Path(args.stage_report),
                    pipeline_seed=Path(args.pipeline_seed),
                    providers_seed=Path(args.providers_seed),
                    output_report=Path(args.output_report),
                    plan_only=True,
                )
                _assert_unlinked_path_within(
                    safe_inputs.output_report,
                    safe_inputs.session_root,
                    "Output report",
                )
                _write_json_atomic(safe_inputs.output_report, failure)
            except (OSError, ValueError):
                pass
        print(json.dumps(failure, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
