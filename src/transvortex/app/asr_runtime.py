from __future__ import annotations

import hashlib
import ipaddress
import importlib.metadata
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..utils import read_json, utc_now_iso, write_json
from .credentials import resolve_credential
from .models import AsrProviderConfig


ASR_RUNTIME_STATE_VERSION = 1
ASR_STORAGE_CONFIG_VERSION = 1
WHISPER_HOST_PROTOCOL_VERSION = 1
APP_DATA_ROOT_ENV = "TRANSVORTEX_HOME"
CATALOG_OVERRIDE_ENV = "TRANSVORTEX_ASR_CATALOG"
ASR_STORAGE_CONFIG_NAME = "asr_storage.json"
ASR_MIN_FREE_SPACE_RESERVE = 256 * 1024 * 1024
ASR_MODEL_SEARCH_MAX_DEPTH = 6
ASR_MODEL_SEARCH_MAX_DIRECTORIES = 4096
ASR_MODEL_SEARCH_MAX_RESULTS = 32


@dataclass(frozen=True)
class AsrRuntimePaths:
    app_data_root: Path
    config_root: Path
    storage_root: Path
    storage_config_file: Path
    storage_config_error: str
    components_root: Path
    models_root: Path
    downloads_root: Path
    state_file: Path
    operations_root: Path


def asr_runtime_paths(
    root_dir: Path,
    *,
    app_data_root: Path | None = None,
    storage_root: Path | None = None,
) -> AsrRuntimePaths:
    root = Path(root_dir).expanduser().resolve()
    explicit = os.environ.get(APP_DATA_ROOT_ENV, "").strip()
    if app_data_root is not None:
        app_root = Path(app_data_root).expanduser().resolve()
    elif explicit:
        app_root = Path(explicit).expanduser().resolve()
    elif root.name.lower() == "config":
        app_root = root.parent
    else:
        app_root = root
    config_root = root if root.name.lower() == "config" else app_root / "Config"
    if root == app_root:
        config_root = root
    storage_config_file = config_root / ASR_STORAGE_CONFIG_NAME
    resolved_storage_root, storage_config_error = _resolve_asr_storage_root(
        storage_config_file,
        default_root=app_root,
        explicit_root=storage_root,
    )
    return AsrRuntimePaths(
        app_data_root=app_root,
        config_root=config_root,
        storage_root=resolved_storage_root,
        storage_config_file=storage_config_file,
        storage_config_error=storage_config_error,
        components_root=resolved_storage_root / "Components",
        models_root=resolved_storage_root / "Models" / "faster-whisper",
        downloads_root=resolved_storage_root / "Downloads" / "ASR",
        state_file=config_root / "asr_runtime_state.json",
        operations_root=resolved_storage_root / "Downloads" / "ASR" / "operations",
    )


def _resolve_asr_storage_root(
    config_file: Path,
    *,
    default_root: Path,
    explicit_root: Path | None,
) -> tuple[Path, str]:
    if explicit_root is not None:
        return Path(explicit_root).expanduser().resolve(), ""
    if not config_file.is_file():
        return default_root, ""
    try:
        payload = read_json(config_file)
        if not isinstance(payload, dict) or int(payload.get("schema_version") or 0) != ASR_STORAGE_CONFIG_VERSION:
            raise ValueError("unsupported schema")
        raw = str(payload.get("storage_root") or "").strip()
        candidate = Path(raw).expanduser()
        if not raw or not candidate.is_absolute():
            raise ValueError("storage_root must be absolute")
        return candidate.resolve(), ""
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        return default_root, f"Invalid ASR storage setting: {exc}"


def required_asr_disk_bytes(download_size: int) -> int:
    normalized = max(int(download_size), 0)
    if normalized == 0:
        return 0
    return normalized + max(ASR_MIN_FREE_SPACE_RESERVE, normalized // 10)


def load_asr_catalog() -> dict[str, Any]:
    override = os.environ.get(CATALOG_OVERRIDE_ENV, "").strip()
    path = (
        Path(override).expanduser().resolve()
        if override
        else Path(__file__).resolve().parents[1] / "resources" / "asr_components.json"
    )
    payload = read_json(path)
    if not isinstance(payload, dict) or int(payload.get("schema_version", 0)) != 1:
        raise RuntimeError("invalid_asr_component_catalog")
    return payload


def load_asr_runtime_state(paths: AsrRuntimePaths) -> dict[str, Any]:
    if not paths.state_file.exists():
        return _empty_runtime_state()
    try:
        payload = read_json(paths.state_file)
    except (OSError, ValueError, json.JSONDecodeError):
        return _empty_runtime_state()
    if not isinstance(payload, dict):
        return _empty_runtime_state()
    payload.setdefault("schema_version", ASR_RUNTIME_STATE_VERSION)
    for key in ("environments", "models", "provider_tests"):
        if not isinstance(payload.get(key), dict):
            payload[key] = {}
    return payload


def save_asr_runtime_state(paths: AsrRuntimePaths, state: dict[str, Any]) -> None:
    payload = dict(state)
    payload["schema_version"] = ASR_RUNTIME_STATE_VERSION
    write_json(paths.state_file, payload)


def _empty_runtime_state() -> dict[str, Any]:
    return {
        "schema_version": ASR_RUNTIME_STATE_VERSION,
        "environments": {},
        "models": {},
        "provider_tests": {},
    }


def asr_runtime_snapshot(
    root_dir: Path,
    *,
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    catalog = load_asr_catalog()
    state = load_asr_runtime_state(paths)
    runtime = dict(catalog.get("runtime") or {})
    runtime["installed"] = _managed_runtime_marker(paths, catalog) is not None
    accelerator_rows = []
    for raw in catalog.get("accelerators") or []:
        if not isinstance(raw, dict):
            continue
        row = dict(raw)
        row["installed"] = _accelerator_marker(paths, row) is not None
        accelerator_rows.append(row)
    model_rows = []
    for raw in catalog.get("models") or []:
        if not isinstance(raw, dict):
            continue
        row = dict(raw)
        path = managed_model_path(paths, row)
        row["installed"] = _model_install_valid(path, row)
        row["path"] = str(path) if row["installed"] else ""
        row["size"] = sum(int(item.get("size", 0)) for item in row.get("files") or [] if isinstance(item, dict))
        model_rows.append(row)
    operations = _operation_rows(paths)
    return {
        "paths": {
            "app_data_root": str(paths.app_data_root),
            "storage_root": str(paths.storage_root),
            "components_root": str(paths.components_root),
            "models_root": str(paths.models_root),
            "downloads_root": str(paths.downloads_root),
        },
        "storage": asr_storage_status(paths, operations=operations),
        "runtime": runtime,
        "accelerators": accelerator_rows,
        "models": model_rows,
        "registered_models": sorted(
            [dict(value, id=key) for key, value in (state.get("models") or {}).items() if isinstance(value, dict)],
            key=lambda item: str(item.get("model_path") or "").lower(),
        ),
        "environments": sorted(
            [dict(value, id=key) for key, value in (state.get("environments") or {}).items() if isinstance(value, dict)],
            key=lambda item: str(item.get("python_executable") or "").lower(),
        ),
        "operations": operations,
    }


def asr_storage_status(
    paths: AsrRuntimePaths,
    *,
    operations: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    rows = operations if operations is not None else _operation_rows(paths)
    active = any(str(row.get("state") or "") in {"queued", "running", "cancelling"} for row in rows)
    content_blocker = asr_storage_content_blocker(paths)
    config_error = paths.storage_config_error
    change_blocker = (
        "storage_config_invalid"
        if config_error
        else "active_operation"
        if active
        else content_blocker
    )
    disk_root = _nearest_existing_directory(paths.storage_root)
    total_bytes = 0
    free_bytes = 0
    space_known = False
    writable = False
    disk_error = ""
    try:
        usage = shutil.disk_usage(disk_root)
        total_bytes = int(usage.total)
        free_bytes = int(usage.free)
        space_known = True
        writable = os.access(disk_root, os.W_OK)
    except OSError as exc:
        disk_error = str(exc)
    return {
        "root": str(paths.storage_root),
        "default_root": str(paths.app_data_root),
        "customized": paths.storage_root != paths.app_data_root,
        "total_bytes": total_bytes,
        "free_bytes": free_bytes,
        "reserve_bytes": ASR_MIN_FREE_SPACE_RESERVE,
        "space_known": space_known,
        "writable": writable,
        "can_change": not active and not bool(content_blocker),
        "change_blocker": change_blocker,
        "config_error": config_error,
        "disk_error": disk_error,
    }


def asr_storage_content_blocker(paths: AsrRuntimePaths) -> str:
    if _tree_has_data(paths.components_root) or _tree_has_data(paths.models_root):
        return "managed_resources_present"
    downloads = paths.downloads_root
    if downloads.is_dir():
        try:
            for child in downloads.iterdir():
                if child.name == "operations":
                    continue
                if _tree_has_data(child):
                    return "partial_downloads_present"
        except OSError:
            return "storage_unreadable"
    return ""


def _tree_has_data(path: Path) -> bool:
    if path.is_file() or path.is_symlink():
        return True
    if not path.is_dir():
        return False
    try:
        for _root, directories, files in os.walk(path, followlinks=False):
            if files:
                return True
            if any((Path(_root) / name).is_symlink() for name in directories):
                return True
    except OSError:
        return True
    return False


def _nearest_existing_directory(path: Path) -> Path:
    candidate = path
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate if candidate.is_dir() else candidate.parent


def asr_provider_readiness(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    if provider.kind == "local_inprocess":
        return _inprocess_readiness(provider)
    if provider.kind == "local_worker":
        return _worker_readiness(provider, root_dir=root_dir, app_data_root=app_data_root)
    if provider.kind == "local_server":
        return _local_server_readiness(provider, root_dir=root_dir, app_data_root=app_data_root)
    if provider.kind == "remote":
        return _remote_readiness(provider, root_dir=root_dir)
    return _readiness("unavailable", "unsupported_provider", False, "choose_provider")


def asr_provider_network_scope(provider: AsrProviderConfig) -> str:
    """Classify an ASR endpoint without DNS or network access."""

    try:
        parsed = urllib.parse.urlsplit(str(provider.base_url or ""))
        if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
            return "invalid"
        hostname = parsed.hostname.lower().rstrip(".")
        if hostname == "localhost":
            return "loopback"
        try:
            return "loopback" if ipaddress.ip_address(hostname).is_loopback else "remote"
        except ValueError:
            return "remote"
    except (TypeError, ValueError):
        return "invalid"


def asr_provider_endpoint_policy_code(provider: AsrProviderConfig) -> str:
    """Reject credential-bearing or misclassified ASR service routes."""

    try:
        parsed = urllib.parse.urlsplit(str(provider.base_url or ""))
        if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            return "unsafe_provider_endpoint"
        if provider.kind == "remote" and parsed.scheme.lower() != "https":
            return "remote_endpoint_requires_https"
        if provider.kind == "local_server":
            if parsed.scheme.lower() not in {"http", "https"}:
                return "unsafe_provider_endpoint"
            if asr_provider_network_scope(provider) != "loopback":
                return "local_service_endpoint_not_loopback"
        endpoint = urllib.parse.urlsplit(str(provider.endpoint or ""))
        if endpoint.scheme or endpoint.netloc or endpoint.query or endpoint.fragment:
            return "unsafe_provider_endpoint"
        return ""
    except (TypeError, ValueError):
        return "unsafe_provider_endpoint"


def _inprocess_readiness(provider: AsrProviderConfig) -> dict[str, Any]:
    if importlib.util.find_spec("faster_whisper") is None:
        return _readiness("needs_action", "runtime_missing", False, "install_runtime")
    try:
        version = importlib.metadata.version("faster-whisper")
    except importlib.metadata.PackageNotFoundError:
        version = ""
    return _readiness("ready", "ready", True, "", details={"runtime_source": "inprocess", "version": version})


def _worker_readiness(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    app_data_root: Path | None,
) -> dict[str, Any]:
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    catalog = load_asr_catalog()
    if provider.runtime.source == "managed":
        marker = _managed_runtime_marker(paths, catalog)
        if marker is None:
            if _active_operation(paths, "runtime", str((catalog.get("runtime") or {}).get("id") or "")):
                return _readiness("checking", "runtime_installing", False, "cancel_install")
            artifact = (catalog.get("runtime") or {}).get("artifact") or {}
            code = "runtime_missing" if artifact.get("published") else "runtime_unpublished"
            return _readiness("needs_action", code, False, "install_runtime")
        if provider.local.model_source == "external":
            raw_model_path = str(provider.local.model_path or "").strip()
            if not raw_model_path:
                return _readiness("needs_action", "model_path_missing", False, "choose_model")
            try:
                model_path = Path(raw_model_path).expanduser().resolve()
            except OSError:
                return _readiness("unavailable", "model_path_unavailable", False, "choose_model")
            if not model_path.is_dir():
                return _readiness("unavailable", "model_path_unavailable", False, "choose_model")
            record = _registered_model_record(paths, model_path)
            probe = record.get("probe") if isinstance(record, dict) else None
            if not isinstance(probe, dict) or probe.get("ok") is not True:
                return _readiness("needs_action", "model_unverified", False, "validate_model")
            if str(record.get("model_id") or "") != provider.model:
                return _readiness("unavailable", "model_mismatch", False, "validate_model")
            current_signature = _external_model_signature(model_path)
            if not current_signature or str(record.get("signature") or "") != current_signature:
                return _readiness("needs_action", "model_changed", False, "validate_model")
        else:
            model = model_catalog_entry(catalog, provider.model)
            if model is None:
                return _readiness("unavailable", "unsupported_model", False, "choose_model")
            model_path = managed_model_path(paths, model)
            if not _model_install_valid(model_path, model):
                if _active_operation(paths, "model", provider.model):
                    return _readiness("checking", "model_installing", False, "cancel_install")
                return _readiness("needs_action", "model_missing", False, "install_model")
        accelerator = _accelerator_marker_by_id(paths, catalog, "nvidia-cuda12")
        if provider.local.device == "cuda" or (provider.local.device == "auto" and accelerator is not None):
            if accelerator is None:
                if _active_operation(paths, "accelerator", "nvidia-cuda12"):
                    return _readiness("checking", "accelerator_installing", False, "cancel_install")
                return _readiness("needs_action", "device_unavailable", False, "install_accelerator")
            hardware = accelerator.get("hardware_probe") if isinstance(accelerator.get("hardware_probe"), dict) else {}
            if not hardware:
                return _readiness("needs_action", "hardware_untested", False, "test_hardware")
            cuda = hardware.get("cuda") if isinstance(hardware.get("cuda"), dict) else {}
            if hardware.get("ok") is not True or cuda.get("available") is not True:
                return _readiness(
                    "unavailable",
                    "hardware_incompatible",
                    False,
                    "choose_device",
                    details={"hardware_probe": hardware},
                )
            requested_compute = str(provider.local.compute_type or "auto")
            supported = {str(item) for item in cuda.get("compute_types") or []}
            if requested_compute != "auto" and requested_compute not in supported:
                return _readiness(
                    "unavailable",
                    "compute_type_incompatible",
                    False,
                    "choose_compute_type",
                    details={"supported_compute_types": sorted(supported)},
                )
        return _readiness(
            "ready",
            "ready",
            True,
            "",
            details={
                "runtime_source": "managed",
                "runtime_version": str(marker.get("version") or ""),
                "model_source": provider.local.model_source,
                "model": provider.model,
                "model_path": str(model_path),
            },
        )

    state = load_asr_runtime_state(paths)
    environment = (state.get("environments") or {}).get(provider.runtime.id)
    if not isinstance(environment, dict):
        return _readiness("needs_action", "environment_missing", False, "choose_environment")
    executable = Path(str(environment.get("python_executable") or ""))
    probe = environment.get("probe") if isinstance(environment.get("probe"), dict) else {}
    if not executable.is_file() or probe.get("ok") is not True:
        return _readiness("unavailable", "environment_unavailable", False, "choose_environment")
    if int(probe.get("protocol_version") or 0) != WHISPER_HOST_PROTOCOL_VERSION:
        return _readiness("unavailable", "environment_protocol_incompatible", False, "choose_environment")
    if provider.local.device == "cuda":
        cuda = probe.get("cuda") if isinstance(probe.get("cuda"), dict) else {}
        if cuda.get("available") is not True:
            return _readiness(
                "unavailable",
                "hardware_incompatible",
                False,
                "choose_device",
                details={"cuda": cuda},
            )
        requested_compute = str(provider.local.compute_type or "auto")
        supported = {str(item) for item in cuda.get("compute_types") or []}
        if requested_compute != "auto" and requested_compute not in supported:
            return _readiness(
                "unavailable",
                "compute_type_incompatible",
                False,
                "choose_compute_type",
                details={"supported_compute_types": sorted(supported)},
            )
    model_path = _external_model_path(environment, provider.model)
    if model_path is None:
        managed = model_catalog_entry(catalog, provider.model)
        candidate = managed_model_path(paths, managed) if managed is not None else None
        if candidate is None or not _model_install_valid(candidate, managed or {}):
            return _readiness("needs_action", "model_missing", False, "install_model")
        model_path = candidate
    return _readiness(
        "ready",
        "ready",
        True,
        "",
        details={
            "runtime_source": "external",
            "runtime_id": provider.runtime.id,
            "python_executable": str(executable),
            "model_path": str(model_path),
        },
    )


def _local_server_readiness(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    app_data_root: Path | None,
) -> dict[str, Any]:
    policy_code = asr_provider_endpoint_policy_code(provider)
    if policy_code:
        return _readiness("unavailable", policy_code, False, "choose_provider")
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    state = load_asr_runtime_state(paths)
    fingerprint = provider_test_fingerprint(provider)
    test = (state.get("provider_tests") or {}).get(fingerprint)
    if not isinstance(test, dict):
        return _readiness("needs_action", "connection_untested", False, "test_connection")
    credential_fingerprint = provider_credential_fingerprint(provider, root_dir=root_dir)
    if provider.auth.type != "none" and not credential_fingerprint:
        return _readiness("needs_action", "credential_missing", False, "set_credential")
    if str(test.get("credential_fingerprint") or "") != credential_fingerprint:
        return _readiness("needs_action", "connection_untested", False, "test_connection")
    if test.get("ok") is not True:
        return _readiness("unavailable", "service_unreachable", False, "test_connection", details=test)
    return _readiness("ready", "ready", True, "", checked_at=str(test.get("checked_at") or ""))


def _remote_readiness(provider: AsrProviderConfig, *, root_dir: Path) -> dict[str, Any]:
    policy_code = asr_provider_endpoint_policy_code(provider)
    if policy_code:
        return _readiness("unavailable", policy_code, False, "choose_provider")
    if provider.auth.type != "bearer":
        return _readiness("unavailable", "unsupported_auth", False, "set_credential")
    credential = resolve_credential(
        env_key=provider.env_key,
        credential_id=provider.credential_id,
        provider_name=provider.name,
        root_dir=root_dir,
    )
    if not credential.found:
        return _readiness("needs_action", "credential_missing", False, "set_credential")
    return _readiness("ready", "ready", True, "", details={"credential_source": credential.source})


def _readiness(
    state: str,
    code: str,
    can_run: bool,
    primary_action: str,
    *,
    checked_at: str = "",
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "state": state,
        "code": code,
        "can_run": can_run,
        "primary_action": primary_action,
        "checked_at": checked_at,
        "details": details or {},
    }


def provider_test_fingerprint(provider: AsrProviderConfig) -> str:
    raw = json.dumps(
        {
            "fingerprint_version": 2,
            "name": provider.name,
            "kind": provider.kind,
            "protocol": provider.protocol,
            "base_url": provider.base_url,
            "endpoint": provider.endpoint,
            "model": provider.model,
            "auth": {
                "type": provider.auth.type,
                "env_key": provider.auth.env_key,
                "credential_id": provider.auth.credential_id,
            },
            "runtime": {
                "source": provider.runtime.source,
                "id": provider.runtime.id,
            },
            "local": {
                "model_source": provider.local.model_source,
                "model_path": provider.local.model_path,
                "device": provider.local.device,
                "compute_type": provider.local.compute_type,
            },
            "network": {
                "mode": provider.network.mode,
                "proxy_port": provider.network.proxy_port,
            },
            "http2": provider.http2,
            "request": {
                "response_format": provider.request.response_format,
                "temperature": provider.request.temperature,
                "timestamp_granularities": provider.request.timestamp_granularities,
                "include": provider.request.include,
                "extra_form_fields": provider.request.extra_form_fields,
                "array_format": provider.request.array_format,
                "send_response_format": provider.request.send_response_format,
                "send_temperature": provider.request.send_temperature,
                "send_timestamp_granularities": provider.request.send_timestamp_granularities,
                "send_language": provider.request.send_language,
                "send_prompt": provider.request.send_prompt,
                "language_field": provider.request.language_field,
                "prompt_field": provider.request.prompt_field,
            },
            "execution": {
                "timeout_seconds": provider.execution.timeout_seconds,
                "retry": provider.execution.retry,
            },
        },
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def provider_credential_fingerprint(provider: AsrProviderConfig, *, root_dir: Path) -> str:
    if provider.auth.type == "none":
        return "none"
    credential = resolve_credential(
        env_key=provider.env_key,
        credential_id=provider.credential_id,
        provider_name=provider.name,
        root_dir=root_dir,
    )
    if not credential.found:
        return ""
    raw = f"{provider.name}\0{credential.key}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def record_provider_test(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    ok: bool,
    code: str,
    details: dict[str, Any] | None = None,
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    state = load_asr_runtime_state(paths)
    result = {
        "ok": bool(ok),
        "code": code,
        "checked_at": utc_now_iso(),
        "credential_fingerprint": provider_credential_fingerprint(provider, root_dir=root_dir),
        "details": details or {},
    }
    tests = state.setdefault("provider_tests", {})
    tests[provider_test_fingerprint(provider)] = result
    save_asr_runtime_state(paths, state)
    return result


def discover_python_environments() -> list[dict[str, Any]]:
    candidates: dict[str, dict[str, Any]] = {}
    _add_path_candidates(candidates)
    _add_py_launcher_candidates(candidates)
    _add_conda_candidates(candidates)
    return sorted(candidates.values(), key=lambda item: (str(item["source"]), str(item["python_executable"]).lower()))


def _add_path_candidates(candidates: dict[str, dict[str, Any]]) -> None:
    names = ("python.exe", "python") if os.name == "nt" else ("python3", "python")
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        for name in names:
            _add_environment_candidate(candidates, Path(directory) / name, "path")


def _add_py_launcher_candidates(candidates: dict[str, dict[str, Any]]) -> None:
    launcher = shutil.which("py")
    if not launcher:
        return
    result = _run_discovery_command([launcher, "-0p"])
    for raw in result.splitlines():
        text = raw.strip()
        if not text:
            continue
        path_text = text.split(maxsplit=1)[-1].strip().lstrip("*").strip()
        _add_environment_candidate(candidates, Path(path_text), "python_launcher")


def _add_conda_candidates(candidates: dict[str, dict[str, Any]]) -> None:
    conda = shutil.which("conda")
    if not conda:
        return
    raw = _run_discovery_command([conda, "env", "list", "--json"])
    try:
        payload = json.loads(raw)
    except (TypeError, ValueError):
        return
    for env_path in payload.get("envs") or []:
        name = "python.exe" if os.name == "nt" else "bin/python"
        _add_environment_candidate(candidates, Path(str(env_path)) / name, "conda")


def _run_discovery_command(command: list[str]) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout


def _add_environment_candidate(
    candidates: dict[str, dict[str, Any]],
    executable: Path,
    source: str,
) -> None:
    try:
        resolved = executable.expanduser().resolve()
    except OSError:
        return
    if not resolved.is_file():
        return
    key = os.path.normcase(str(resolved))
    current = candidates.get(key)
    if current is None:
        candidates[key] = {
            "id": _environment_id(resolved),
            "python_executable": str(resolved),
            "source": source,
        }
    elif source not in str(current.get("source") or "").split(","):
        current["source"] = f"{current['source']},{source}"


def _environment_id(executable: Path) -> str:
    digest = hashlib.sha256(os.path.normcase(str(executable)).encode("utf-8")).hexdigest()[:16]
    return f"external:{digest}"


def save_external_environment(
    *,
    root_dir: Path,
    python_executable: Path,
    probe: dict[str, Any],
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    executable = Path(python_executable).expanduser().resolve()
    if not executable.is_file():
        raise FileNotFoundError(f"Python executable not found: {executable}")
    if probe.get("ok") is not True:
        raise RuntimeError("external_asr_environment_probe_failed")
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    state = load_asr_runtime_state(paths)
    environment_id = _environment_id(executable)
    record = {
        "python_executable": str(executable),
        "source": "selected",
        "probe": probe,
        "model_paths": dict(probe.get("model_paths") or {}),
        "updated_at": utc_now_iso(),
    }
    state.setdefault("environments", {})[environment_id] = record
    save_asr_runtime_state(paths, state)
    return dict(record, id=environment_id)


def probe_managed_model(
    *,
    root_dir: Path,
    model_path: Path,
    device: str = "auto",
    compute_type: str = "auto",
    timeout_seconds: float = 120.0,
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    catalog = load_asr_catalog()
    try:
        resolved_model = Path(model_path).expanduser().resolve()
    except OSError as exc:
        return {
            "ok": False,
            "code": "model_path_unavailable",
            "message": str(exc),
        }
    if not resolved_model.is_dir():
        return {
            "ok": False,
            "code": "model_path_unavailable",
            "message": f"Model directory not found: {resolved_model}",
        }
    try:
        identity = _external_model_identity(resolved_model, catalog)
        initial_signature = _external_model_signature(resolved_model)
    except OSError as exc:
        return {
            "ok": False,
            "code": "model_path_unavailable",
            "message": str(exc),
            "model_path": str(resolved_model),
        }
    if identity is None:
        return {
            "ok": False,
            "code": "unsupported_model_directory",
            "message": "The directory does not contain a readable CTranslate2 config.json and model.bin.",
        }
    model_id = str(identity["model_id"])
    if not initial_signature:
        return {
            "ok": False,
            "code": "model_path_unavailable",
            "message": "The model directory cannot be read.",
            "model_id": model_id,
            "model_path": str(resolved_model),
        }
    marker = _managed_runtime_marker(paths, catalog)
    if marker is None:
        artifact = (catalog.get("runtime") or {}).get("artifact") or {}
        code = "runtime_missing" if artifact.get("published") else "runtime_unpublished"
        return {
            "ok": False,
            "code": code,
            "message": "The managed Whisper runtime must be installed before validating a model.",
            "model_id": model_id,
            "model_path": str(resolved_model),
        }
    runtime_root = paths.components_root / "faster-whisper" / str(marker.get("version") or "")
    executable = runtime_root / str(marker.get("python") or "python.exe")
    accelerator_root = _managed_accelerator_root(paths, catalog, "nvidia-cuda12")
    probe = probe_python_environment(
        executable,
        model_id=model_id,
        model_path=resolved_model,
        device=device,
        compute_type=compute_type,
        accelerator_root=accelerator_root,
        timeout_seconds=timeout_seconds,
    )
    if probe.get("ok") is not True:
        return {
            "ok": False,
            "code": str(probe.get("code") or "model_probe_failed"),
            "message": str(probe.get("message") or "Model validation failed"),
            "model_id": model_id,
            "model_path": str(resolved_model),
            "probe": probe,
        }
    final_signature = _external_model_signature(resolved_model)
    if not final_signature or final_signature != initial_signature:
        return {
            "ok": False,
            "code": "model_changed",
            "message": "The model directory changed while it was being validated.",
            "model_id": model_id,
            "model_path": str(resolved_model),
        }
    record = _save_registered_model(
        paths,
        model_id=model_id,
        model_path=resolved_model,
        probe=probe,
        signature=final_signature,
        identity=identity,
    )
    return {"ok": True, "code": "ready", "model": record, "probe": probe}


def discover_external_models(
    search_root: Path,
    *,
    max_depth: int = ASR_MODEL_SEARCH_MAX_DEPTH,
    max_directories: int = ASR_MODEL_SEARCH_MAX_DIRECTORIES,
    max_results: int = ASR_MODEL_SEARCH_MAX_RESULTS,
) -> dict[str, Any]:
    """Find plausible local CTranslate2 Whisper directories below a user-selected folder."""

    try:
        resolved_root = Path(search_root).expanduser().resolve()
    except OSError as exc:
        return {
            "ok": False,
            "code": "model_search_root_unavailable",
            "message": str(exc),
            "candidates": [],
        }
    if not resolved_root.is_dir():
        return {
            "ok": False,
            "code": "model_search_root_unavailable",
            "message": f"Model search folder not found: {resolved_root}",
            "root": str(resolved_root),
            "candidates": [],
        }

    catalog = load_asr_catalog()
    pending: list[tuple[Path, int]] = [(resolved_root, 0)]
    cursor = 0
    scanned = 0
    candidates: list[dict[str, Any]] = []
    truncated = False
    while cursor < len(pending):
        if scanned >= max(max_directories, 1):
            truncated = True
            break
        directory, depth = pending[cursor]
        cursor += 1
        scanned += 1
        identity = _external_model_identity(directory, catalog)
        if identity is not None:
            try:
                model_bytes = int((directory / "model.bin").stat().st_size)
            except OSError:
                model_bytes = 0
            relative = (
                "."
                if directory == resolved_root
                else str(directory.relative_to(resolved_root))
            )
            candidates.append(
                {
                    **identity,
                    "path": str(directory),
                    "relative_path": relative,
                    "folder_name": directory.name,
                    "model_bytes": model_bytes,
                }
            )
            if len(candidates) >= max(max_results, 1):
                truncated = cursor < len(pending)
                break
            # Model payload directories are leaves for discovery purposes.
            continue
        if depth >= max(max_depth, 0):
            continue
        try:
            children = sorted(
                (
                    child
                    for child in directory.iterdir()
                    if not child.is_symlink() and child.is_dir()
                ),
                key=lambda child: child.name.lower(),
            )
        except OSError:
            continue
        pending.extend((child, depth + 1) for child in children)

    return {
        "ok": True,
        "code": "ready",
        "root": str(resolved_root),
        "candidates": candidates,
        "scanned_directories": scanned,
        "max_depth": max(max_depth, 0),
        "truncated": truncated,
    }


def probe_python_environment(
    python_executable: Path,
    *,
    model_id: str = "",
    model_path: Path | None = None,
    device: str = "auto",
    compute_type: str = "auto",
    accelerator_root: Path | None = None,
    timeout_seconds: float = 120.0,
) -> dict[str, Any]:
    executable = Path(python_executable).expanduser().resolve()
    if not executable.is_file():
        return {"ok": False, "code": "environment_missing", "message": f"Python executable not found: {executable}"}
    command = [str(executable), "-B", "-u", str(whisper_host_script()), "--probe"]
    if model_path is not None:
        command.extend(["--model-path", str(Path(model_path).expanduser().resolve())])
    command.extend(["--device", device, "--compute-type", compute_type])
    if accelerator_root is not None:
        command.extend(["--accelerator-root", str(Path(accelerator_root).expanduser().resolve())])
    creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
            check=False,
            creationflags=creationflags,
            env={
                **os.environ,
                "PYTHONIOENCODING": "utf-8",
                "PYTHONUTF8": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
            },
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "code": "environment_probe_failed", "message": str(exc)}
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if not lines:
        return {
            "ok": False,
            "code": "environment_probe_failed",
            "message": completed.stderr.strip() or f"Probe exited with code {completed.returncode}",
        }
    try:
        payload = json.loads(lines[-1])
    except ValueError:
        return {"ok": False, "code": "environment_probe_invalid_json", "message": lines[-1]}
    if not isinstance(payload, dict):
        return {"ok": False, "code": "environment_probe_invalid_payload", "message": "Probe returned invalid data"}
    payload["python_executable"] = str(executable)
    if model_id and model_path is not None and payload.get("ok") is True:
        payload["model_paths"] = {model_id: str(Path(model_path).expanduser().resolve())}
    return payload


def _external_model_identity(
    model_path: Path,
    catalog: dict[str, Any],
) -> dict[str, Any] | None:
    config_path = model_path / "config.json"
    model_bin = model_path / "model.bin"
    if not config_path.is_file() or not model_bin.is_file():
        return None
    try:
        config = read_json(config_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(config, dict):
        return None
    config_hash = _file_sha256(config_path)
    for model in catalog.get("models") or []:
        if not isinstance(model, dict):
            continue
        expected = next(
            (
                str(item.get("sha256") or "")
                for item in model.get("files") or []
                if isinstance(item, dict) and item.get("path") == "config.json"
            ),
            "",
        )
        if expected and expected == config_hash:
            model_id = str(model.get("id") or "")
            return {
                "model_id": model_id,
                "catalog_model_id": model_id,
                "display_name": str(model.get("display_name") or model_id),
                "catalog_config_match": True,
                "config_sha256": config_hash,
                "model_format": "ctranslate2",
            }
    return {
        "model_id": f"custom-{config_hash[:12]}",
        "catalog_model_id": "",
        "display_name": "Custom faster-whisper model",
        "catalog_config_match": False,
        "config_sha256": config_hash,
        "model_format": "ctranslate2",
    }


def _detect_external_model_id(model_path: Path, catalog: dict[str, Any]) -> str:
    identity = _external_model_identity(model_path, catalog)
    return str(identity.get("model_id") or "") if identity is not None else ""


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _external_model_key(model_path: Path) -> str:
    normalized = os.path.normcase(str(model_path.expanduser().resolve()))
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _external_model_signature(model_path: Path) -> str:
    rows = []
    for name in (
        "config.json",
        "model.bin",
        "preprocessor_config.json",
        "tokenizer.json",
        "vocabulary.json",
        "vocabulary.txt",
    ):
        path = model_path / name
        try:
            if not path.is_file():
                continue
            stat = path.stat()
        except OSError:
            return ""
        rows.append((name, stat.st_size, stat.st_mtime_ns))
    if not rows:
        return ""
    raw = json.dumps(rows, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _registered_model_record(paths: AsrRuntimePaths, model_path: Path) -> dict[str, Any] | None:
    state = load_asr_runtime_state(paths)
    models = state.get("models")
    if not isinstance(models, dict):
        return None
    record = models.get(_external_model_key(model_path))
    return record if isinstance(record, dict) else None


def _save_registered_model(
    paths: AsrRuntimePaths,
    *,
    model_id: str,
    model_path: Path,
    probe: dict[str, Any],
    signature: str,
    identity: dict[str, Any] | None = None,
) -> dict[str, Any]:
    resolved = model_path.expanduser().resolve()
    record = {
        "model_id": model_id,
        "model_path": str(resolved),
        "display_name": str((identity or {}).get("display_name") or model_id),
        "catalog_model_id": str((identity or {}).get("catalog_model_id") or ""),
        "catalog_config_match": (identity or {}).get("catalog_config_match") is True,
        "model_format": str((identity or {}).get("model_format") or "ctranslate2"),
        "config_sha256": str((identity or {}).get("config_sha256") or ""),
        "signature": signature,
        "probe": probe,
        "updated_at": utc_now_iso(),
    }
    paths.state_file.parent.mkdir(parents=True, exist_ok=True)
    state = load_asr_runtime_state(paths)
    key = _external_model_key(resolved)
    state.setdefault("models", {})[key] = record
    save_asr_runtime_state(paths, state)
    return dict(record, id=key)


def model_catalog_entry(catalog: dict[str, Any], model_id: str) -> dict[str, Any] | None:
    return next(
        (item for item in catalog.get("models") or [] if isinstance(item, dict) and item.get("id") == model_id),
        None,
    )


def managed_model_path(paths: AsrRuntimePaths, model: dict[str, Any]) -> Path:
    model_id = str(model.get("id") or "unknown")
    revision = str(model.get("revision") or "unknown")
    return paths.models_root / model_id / revision


def _model_install_valid(path: Path, model: dict[str, Any]) -> bool:
    marker = path / "model.json"
    if not marker.is_file():
        return False
    try:
        payload = read_json(marker)
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    if payload.get("id") != model.get("id") or payload.get("revision") != model.get("revision"):
        return False
    return all((path / str(item.get("path") or "")).is_file() for item in model.get("files") or [] if isinstance(item, dict))


def _managed_runtime_marker(paths: AsrRuntimePaths, catalog: dict[str, Any]) -> dict[str, Any] | None:
    runtime = catalog.get("runtime") if isinstance(catalog.get("runtime"), dict) else {}
    marker_path = paths.components_root / "faster-whisper" / str(runtime.get("version") or "") / "component.json"
    if not marker_path.is_file():
        return None
    try:
        marker = read_json(marker_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if marker.get("id") != runtime.get("id") or marker.get("version") != runtime.get("version"):
        return None
    if int(marker.get("protocol_version") or 0) != WHISPER_HOST_PROTOCOL_VERSION:
        return None
    python_path = marker_path.parent / str(marker.get("python") or "python.exe")
    return marker if python_path.is_file() else None


def _accelerator_marker(paths: AsrRuntimePaths, accelerator: dict[str, Any]) -> dict[str, Any] | None:
    marker_path = (
        paths.components_root
        / "accelerators"
        / str(accelerator.get("id") or "")
        / str(accelerator.get("version") or "")
        / "component.json"
    )
    if not marker_path.is_file():
        return None
    try:
        marker = read_json(marker_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if marker.get("id") != accelerator.get("id") or marker.get("version") != accelerator.get("version"):
        return None
    return marker


def _accelerator_marker_by_id(
    paths: AsrRuntimePaths,
    catalog: dict[str, Any],
    accelerator_id: str,
) -> dict[str, Any] | None:
    accelerator = next(
        (item for item in catalog.get("accelerators") or [] if isinstance(item, dict) and item.get("id") == accelerator_id),
        None,
    )
    return _accelerator_marker(paths, accelerator) if accelerator is not None else None


def _managed_accelerator_root(
    paths: AsrRuntimePaths,
    catalog: dict[str, Any],
    accelerator_id: str,
) -> Path | None:
    accelerator = next(
        (
            item
            for item in catalog.get("accelerators") or []
            if isinstance(item, dict) and item.get("id") == accelerator_id
        ),
        None,
    )
    if accelerator is None or _accelerator_marker(paths, accelerator) is None:
        return None
    return (
        paths.components_root
        / "accelerators"
        / accelerator_id
        / str(accelerator.get("version") or "")
    )


def _external_model_path(environment: dict[str, Any], model_id: str) -> Path | None:
    raw = (environment.get("model_paths") or {}).get(model_id)
    if not raw:
        return None
    path = Path(str(raw)).expanduser()
    return path.resolve() if path.is_dir() else None


def resolve_whisper_runtime(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    app_data_root: Path | None = None,
) -> dict[str, Any]:
    readiness = asr_provider_readiness(provider, root_dir=root_dir, app_data_root=app_data_root)
    if readiness.get("can_run") is not True:
        raise RuntimeError(f"asr_not_ready:{readiness.get('code')}")
    paths = asr_runtime_paths(root_dir, app_data_root=app_data_root)
    catalog = load_asr_catalog()
    if provider.runtime.source == "managed":
        marker = _managed_runtime_marker(paths, catalog) or {}
        component_root = paths.components_root / "faster-whisper" / str(marker.get("version") or "")
        python_executable = component_root / str(marker.get("python") or "python.exe")
        if provider.local.model_source == "external":
            model_path = Path(provider.local.model_path).expanduser().resolve()
        else:
            model = model_catalog_entry(catalog, provider.model) or {}
            model_path = managed_model_path(paths, model)
        accelerator = _accelerator_marker_by_id(paths, catalog, "nvidia-cuda12")
        return {
            "python_executable": str(python_executable),
            "model_path": str(model_path),
            "accelerator_root": str(accelerator.get("root") or "") if accelerator else "",
            "runtime_source": "managed",
        }
    state = load_asr_runtime_state(paths)
    environment = (state.get("environments") or {}).get(provider.runtime.id) or {}
    probe = environment.get("probe") if isinstance(environment.get("probe"), dict) else {}
    cuda = probe.get("cuda") if isinstance(probe.get("cuda"), dict) else {}
    model_path = _external_model_path(environment, provider.model)
    if model_path is None:
        model_path = managed_model_path(paths, model_catalog_entry(catalog, provider.model) or {})
    return {
        "python_executable": str(environment.get("python_executable") or ""),
        "model_path": str(model_path),
        "accelerator_root": "",
        "cuda_available": cuda.get("available") is True,
        "runtime_source": "external",
    }


def whisper_host_script() -> Path:
    return Path(__file__).resolve().parents[1] / "core" / "whisper_host.py"


def _operation_rows(paths: AsrRuntimePaths) -> list[dict[str, Any]]:
    if not paths.operations_root.is_dir():
        return []
    rows: list[dict[str, Any]] = []
    for path in paths.operations_root.glob("*.json"):
        try:
            payload = read_json(path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict):
            rows.append(payload)
    return sorted(rows, key=lambda row: str(row.get("created_at") or ""), reverse=True)


def _active_operation(paths: AsrRuntimePaths, kind: str, item_id: str) -> dict[str, Any] | None:
    return next(
        (
            row
            for row in _operation_rows(paths)
            if row.get("kind") == kind
            and row.get("item_id") == item_id
            and row.get("state") in {"queued", "running", "cancelling"}
        ),
        None,
    )
