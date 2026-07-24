"""Machine-readable environment setup contracts for local Agents.

The setup contract is deliberately read-only.  It describes the active ASR
provider, the pinned managed assets, and the checks an Agent can perform.  It
does not install packages, invoke pip, mutate configuration, or expose
credential values.  A future ``apply`` command can consume this contract, but
for now Agents use it to plan work and ask the user for confirmation.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import platform
import re
import shutil
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any

from ..app.asr_runtime import (
    asr_provider_endpoint_policy_code,
    asr_provider_network_scope,
    asr_provider_readiness,
    asr_runtime_paths,
    asr_runtime_snapshot,
    load_asr_runtime_state,
    load_asr_catalog,
    model_catalog_entry,
    probe_python_environment,
    provider_credential_fingerprint,
    provider_test_fingerprint,
)
from ..app.config import load_app_config, resolve_providers_file
from ..app.credentials import resolve_credential
from ..app.agent_entry import cli_argv_prefix
from ..utils import read_json
from ..utils import utc_now_iso


AGENT_SETUP_SCHEMA_VERSION = 1
AGENT_SETUP_CONTRACT = "transvortex.agent_setup"
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_PROVIDER_TEST_MAX_AGE_SECONDS = 24 * 60 * 60

# These are policy names, not shell commands.  Keeping them stable lets a
# Skill/Plugin translate the contract into its own preferred workflow without
# granting the Agent permission to invent package installation commands.
ALLOWED_ACTIONS = [
    "inspect_platform",
    "inspect_gpu_and_driver",
    "inspect_existing_asr",
    "read_transvortex_catalog",
    "read_installed_component_state",
    "request_pinned_catalog_asset_download_after_confirmation",
    "verify_sha256_before_use",
    "request_user_scoped_managed_install_after_confirmation",
    "run_transvortex_readiness_probe",
    "register_user_approved_existing_asr",
    "write_config_only_after_user_confirmation",
]

FORBIDDEN_ACTIONS = [
    "global_pip_install",
    "modify_system_python",
    "use_unpinned_download_url",
    "download_or_execute_untrusted_script",
    "read_or_print_secret_values",
    "write_api_keys_to_provider_yaml",
    "change_nvidia_driver_without_user_approval",
    "delete_existing_asr_or_model_without_user_approval",
    "invent_unadvertised_apply_command",
    "probe_remote_media_without_user_confirmation",
    "guess_unadvertised_local_service_endpoint",
    "claim_success_without_transvortex_verify",
]

def _safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return default


def _safe_code(value: Any, fallback: str) -> str:
    code = str(value or "").strip().lower()
    if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", code) and not re.search(r"(?:token|secret|password|api_key)", code):
        return code
    return fallback


def _list_value(value: Any) -> list[Any]:
    """Return only real JSON arrays; malformed scalar values are not iterable."""

    return value if isinstance(value, list) else []


def _is_true(value: Any) -> bool:
    """Do not coerce hostile strings such as ``\"false\"`` to true."""

    return value is True


def _hardware_payload(raw: Any) -> dict[str, Any]:
    """Project hardware diagnostics without forwarding arbitrary stderr/details."""

    if not isinstance(raw, dict):
        return {}
    payload: dict[str, Any] = {
        "ok": _is_true(raw.get("ok")),
        "code": str(raw.get("code") or ""),
        "checked_at": str(raw.get("checked_at") or ""),
    }
    cuda = raw.get("cuda") if isinstance(raw.get("cuda"), dict) else None
    if cuda is None and any(key in raw for key in ("available", "device_count", "compute_types")):
        cuda = raw
    if cuda is not None:
        payload["cuda"] = {
            "available": _is_true(cuda.get("available")),
            "device_count": _safe_int(cuda.get("device_count")),
            "compute_types": [str(item) for item in cuda.get("compute_types") or [] if item is not None],
        }
    return payload


def _package_version() -> str:
    try:
        return importlib.metadata.version("transvortex")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def _platform_payload(paths_root: Path) -> dict[str, Any]:
    try:
        disk = shutil.disk_usage(paths_root)
        disk_payload: dict[str, Any] = {
            "free_bytes": int(disk.free),
            "total_bytes": int(disk.total),
        }
    except OSError:
        disk_payload = {"free_bytes": None, "total_bytes": None}
    return {
        "system": platform.system().lower(),
        "release": platform.release(),
        "machine": platform.machine().lower(),
        "python_version": platform.python_version(),
        "python_executable": str(Path(sys.executable).resolve()),
        "disk": disk_payload,
    }


def _artifact_payload(raw: Any) -> dict[str, Any]:
    artifact = raw if isinstance(raw, dict) else {}
    # URLs, sizes, and hashes are release metadata, not credentials.  Do not
    # copy arbitrary catalog fields into the Agent contract.
    raw_url = str(artifact.get("url") or "")
    # Catalog URLs are expected to be stable HTTPS release URLs.  Drop query
    # strings/fragments so a misconfigured signed URL can never leak a token
    # through an Agent setup report.
    safe_url = _safe_url(raw_url)
    try:
        if urllib.parse.urlsplit(raw_url).scheme.lower() != "https":
            safe_url = ""
    except (TypeError, ValueError):
        safe_url = ""
    return {
        "published": _is_true(artifact.get("published")),
        "release_tag": str(artifact.get("release_tag") or ""),
        "asset_name": str(artifact.get("asset_name") or ""),
        "url": safe_url,
        "size": _safe_int(artifact.get("size")),
        "sha256": str(artifact.get("sha256") or ""),
    }


def _safe_url(raw: Any) -> str:
    """Return endpoint metadata without query, fragment, or userinfo secrets."""

    try:
        parsed = urllib.parse.urlsplit(str(raw or ""))
        if parsed.netloc:
            hostname = parsed.hostname or ""
            if not hostname:
                return ""
            if ":" in hostname and not hostname.startswith("["):
                hostname = f"[{hostname}]"
            port = parsed.port
            netloc = f"{hostname}:{port}" if port is not None else hostname
            return urllib.parse.urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))
        return urllib.parse.urlunsplit(("", "", parsed.path, "", ""))
    except (TypeError, ValueError):
        return ""


def _safe_env_key(raw: Any) -> str:
    value = str(raw or "").strip()
    return value if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", value) else ""


def _safe_credential_id(raw: Any) -> str:
    value = str(raw or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_.:@/-]{1,128}", value):
        return ""
    if re.search(r"(?i)(?:^sk-|bearer|token=|api[_-]?key=)", value):
        return ""
    return value


def _safe_manifest_path(raw: Any) -> str:
    """Accept a relative POSIX-style model file path, never an escape path."""

    value = str(raw or "").replace("\\", "/")
    if not value or "\x00" in value or value.startswith("/") or re.match(r"^[A-Za-z]:/", value):
        return ""
    parts = PurePosixPath(value).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return ""
    return "/".join(parts)


def _is_trusted_https_url(raw: Any) -> bool:
    try:
        parsed = urllib.parse.urlsplit(str(raw or ""))
        return (
            parsed.scheme.lower() == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and not parsed.query
            and not parsed.fragment
        )
    except (TypeError, ValueError):
        return False


def _runtime_requirement(catalog: dict[str, Any]) -> dict[str, Any]:
    raw = catalog.get("runtime") if isinstance(catalog.get("runtime"), dict) else {}
    return {
        "id": str(raw.get("id") or ""),
        "version": str(raw.get("version") or ""),
        "platform": str(raw.get("platform") or ""),
        "protocol_version": _safe_int(raw.get("protocol_version")),
        "python_version": str(raw.get("python_version") or ""),
        "faster_whisper_version": str(raw.get("faster_whisper_version") or ""),
        "ctranslate2_version": str(raw.get("ctranslate2_version") or ""),
        "artifact": _artifact_payload(raw.get("artifact")),
    }


def _accelerator_requirement(catalog: dict[str, Any]) -> dict[str, Any] | None:
    for raw in _list_value(catalog.get("accelerators")):
        if not isinstance(raw, dict):
            continue
        if str(raw.get("id") or "") != "nvidia-cuda12":
            continue
        packages = raw.get("packages") if isinstance(raw.get("packages"), dict) else {}
        return {
            "id": str(raw.get("id") or ""),
            "version": str(raw.get("version") or ""),
            "platform": str(raw.get("platform") or ""),
            "packages": {str(key): str(value) for key, value in sorted(packages.items())},
            "artifact": _artifact_payload(raw.get("artifact")),
        }
    return None


def _model_requirement(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    files: list[dict[str, Any]] = []
    for item in _list_value(raw.get("files")):
        if not isinstance(item, dict):
            continue
        files.append(
            {
                "path": _safe_manifest_path(item.get("path")),
                "size": _safe_int(item.get("size")),
                "sha256": str(item.get("sha256") or ""),
            }
        )
    return {
        "id": str(raw.get("id") or ""),
        "display_name": str(raw.get("display_name") or ""),
        "repository": str(raw.get("repository") or ""),
        "revision": str(raw.get("revision") or ""),
        "files": files,
        "size": sum(_safe_int(item.get("size")) for item in files),
    }


def _provider_payload(provider: Any, *, root_dir: Path | None = None) -> dict[str, Any]:
    local = provider.local
    runtime = provider.runtime
    auth = provider.auth
    is_local_worker = provider.kind == "local_worker"
    credential_present = True
    credential_source = "not_required"
    if auth.type != "none":
        try:
            lookup = resolve_credential(
                env_key=str(auth.env_key or ""),
                credential_id=str(auth.credential_id or ""),
                provider_name=str(provider.name or ""),
                root_dir=root_dir,
            )
            credential_present = bool(lookup.found)
            credential_source = str(lookup.source or "missing")
        except Exception:  # noqa: BLE001 - metadata discovery must stay secret-free and structured
            credential_present = False
            credential_source = "unavailable"
    payload: dict[str, Any] = {
        "name": str(provider.name),
        "kind": str(provider.kind),
        "protocol": str(provider.protocol),
        "model": str(provider.model),
        "runtime_source": str(runtime.source),
        "runtime_id": str(runtime.id),
        "model_source": str(local.model_source) if is_local_worker else "",
        "model_path_configured": bool(str(local.model_path or "").strip()) if is_local_worker else False,
        "device": str(local.device) if is_local_worker else "",
        "compute_type": str(local.compute_type) if is_local_worker else "",
        "auth_type": str(auth.type),
        "env_key": _safe_env_key(auth.env_key),
        "credential_id": _safe_credential_id(auth.credential_id),
        "credential_required": auth.type != "none",
        "credential_configured": credential_present if auth.type != "none" else False,
        "credential_source": credential_source,
        "credential_metadata_valid": (
            auth.type == "none"
            or (bool(_safe_env_key(auth.env_key)) and bool(_safe_credential_id(auth.credential_id)))
        ),
    }
    # Endpoint metadata is useful when an Agent discovers an existing local
    # or remote ASR. A managed worker's default OpenAI-shaped fields are not
    # an active network route, so omit them to avoid a misleading plan.
    if provider.kind in {"local_server", "remote"}:
        payload["base_url"] = _safe_url(provider.base_url)
        payload["endpoint"] = _safe_url(provider.endpoint)
        payload["network_scope"] = asr_provider_network_scope(provider)
    return payload


def _provider_route(provider: Any) -> str | None:
    """Map an observed provider configuration to the public setup route names."""

    if isinstance(provider, dict):
        kind = str(provider.get("kind") or "")
        model_source = str(provider.get("model_source") or "")
        runtime_source = str(provider.get("runtime_source") or "")
    else:
        kind = str(getattr(provider, "kind", "") or "")
        model_source = str(getattr(getattr(provider, "local", None), "model_source", "") or "")
        runtime_source = str(getattr(getattr(provider, "runtime", None), "source", "") or "")
    if kind == "remote":
        return "remote_provider"
    if kind == "local_server":
        return "local_service"
    if kind == "local_worker":
        return "managed" if model_source == "managed" and runtime_source == "managed" else (
            "reuse_model" if model_source == "external" else "cli_external"
        )
    if kind in {"local_inprocess", "local_external"}:
        return "cli_external"
    return None


def _component_requirements(provider: Any, snapshot: dict[str, Any] | None = None) -> tuple[bool, bool, bool]:
    """Return whether this provider needs managed runtime, accelerator, model."""

    if provider is None or str(getattr(provider, "kind", "") or "") != "local_worker":
        return False, False, False
    runtime_required = str(provider.runtime.source) == "managed"
    model_required = str(provider.local.model_source) == "managed"
    accelerator_required = runtime_required and (
        str(provider.local.device) == "cuda"
        or (
            str(provider.local.device) == "auto"
            and any(
                isinstance(row, dict)
                and str(row.get("id") or "") == "nvidia-cuda12"
                and row.get("installed") is True
                for row in _list_value((snapshot or {}).get("accelerators"))
            )
        )
    )
    return runtime_required, accelerator_required, model_required


def _route_alternatives(
    provider: Any,
    blockers: list[dict[str, str]],
    *,
    current: dict[str, Any],
    requirements: dict[str, Any],
) -> list[dict[str, Any]]:
    observed = _provider_route(provider) if provider is not None else None
    candidates: list[tuple[str | None, list[str]]] = [(observed, ["active_provider_configuration"])]
    if isinstance(requirements.get("runtime"), dict):
        candidates.append(("managed", ["trusted_component_catalog"]))
    if _list_value(current.get("registered_models")):
        candidates.append(("reuse_model", ["registered_external_model"]))
    if _list_value(current.get("environment_candidates")):
        candidates.append(("cli_external", ["registered_external_environment"]))
    unique: list[tuple[str, list[str]]] = []
    for route, evidence in candidates:
        if route and not any(existing == route for existing, _ in unique):
            unique.append((route, evidence))
    blocker_codes = [str(item.get("code") or "") for item in blockers if isinstance(item, dict)]
    reasons = {
        "managed": "TransVortex supported user-scoped runtime and model path",
        "reuse_model": "Reuse a user-owned compatible model without moving it",
        "local_service": "Connect to a user-provided local ASR service",
        "remote_provider": "Use a user-selected hosted ASR provider",
        "cli_external": "Register an explicitly selected external Python environment",
    }
    result: list[dict[str, Any]] = []
    for rank, (route, evidence) in enumerate(unique, start=1):
        result.append(
            {
                "route": route,
                "rank": rank,
                "reason": reasons[route],
                "observed": route == observed,
                "availability": "observed" if route == observed else "detected_candidate",
                "evidence": evidence,
                "blocking": blocker_codes if route == observed else ["user_confirmation_required"],
            }
        )
    return result


def _plan_actions(
    *,
    provider: Any,
    requirements: dict[str, Any],
    root: Path,
    providers_file: Path,
) -> list[dict[str, Any]]:
    """Describe bounded actions without advertising an unimplemented apply command."""

    def asr_argv(*parts: str) -> list[str]:
        return [
            *cli_argv_prefix(root_dir=root),
            "asr",
            *parts,
            "--providers-file",
            str(providers_file),
            "--json",
        ]

    actions: list[dict[str, Any]] = [
        {
            "id": "discover",
            "kind": "read_only_discovery",
            "description": "Read TransVortex configuration, catalog, and installed ASR state",
            "mutating": False,
            "requires_confirmation": False,
            "requires_admin": False,
            "requires_restart": False,
            "requires_network": False,
            "may_cost_money": False,
            "command": "transvortex --root <config-root> asr setup-plan --providers-file <providers-file> --json",
            "argv": asr_argv("setup-plan"),
            "expected_outputs": ["versioned setup contract"],
            "rollback": "No changes are made",
        }
    ]
    runtime_required = isinstance(requirements.get("runtime"), dict)
    accelerator_required = isinstance(requirements.get("accelerator"), dict)
    model_required = isinstance(requirements.get("model"), dict)
    def pinned_component(requirement: Any) -> bool:
        if not isinstance(requirement, dict):
            return False
        artifact = requirement.get("artifact") if isinstance(requirement.get("artifact"), dict) else {}
        return (
            _is_true(artifact.get("published"))
            and _is_trusted_https_url(artifact.get("url"))
            and _safe_int(artifact.get("size")) > 0
            and _SHA256_RE.fullmatch(str(artifact.get("sha256") or "")) is not None
        )

    def pinned_model(requirement: Any) -> bool:
        if not isinstance(requirement, dict):
            return False
        files = _list_value(requirement.get("files"))
        return (
            bool(str(requirement.get("id") or ""))
            and bool(str(requirement.get("repository") or ""))
            and bool(str(requirement.get("revision") or ""))
            and bool(files)
            and all(
                isinstance(item, dict)
                and _safe_manifest_path(item.get("path"))
                and _safe_int(item.get("size")) > 0
                and _SHA256_RE.fullmatch(str(item.get("sha256") or "")) is not None
                for item in files
            )
        )

    if runtime_required and pinned_component(requirements.get("runtime")):
        actions.append(
            {
                "id": "install_runtime",
                "kind": "managed_component_install",
                "description": "Install the catalog-pinned Whisper runtime in the user data root",
                "mutating": True,
                "requires_confirmation": True,
                "requires_admin": False,
                "requires_restart": False,
                "requires_network": True,
                "may_cost_money": False,
                "inputs": {"requirement": requirements.get("runtime") or {}, "root": str(root)},
                "expected_outputs": ["runtime marker", "user-scoped runtime directory"],
                "rollback": "Remove only an incomplete managed operation through the advertised TransVortex operation API",
            }
        )
    if accelerator_required and pinned_component(requirements.get("accelerator")):
        actions.append(
            {
                "id": "install_accelerator",
                "kind": "managed_component_install",
                "description": "Install the catalog-pinned user-space CUDA component",
                "mutating": True,
                "requires_confirmation": True,
                "requires_admin": False,
                "requires_restart": False,
                "requires_network": True,
                "may_cost_money": False,
                "inputs": {"requirement": requirements.get("accelerator") or {}, "root": str(root)},
                "expected_outputs": ["accelerator marker", "user-scoped CUDA component directory"],
                "rollback": "Remove only the managed component through the advertised TransVortex operation API",
            }
        )
    if model_required and pinned_model(requirements.get("model")):
        actions.append(
            {
                "id": "install_model",
                "kind": "managed_model_install",
                "description": "Install the selected model revision after hash confirmation",
                "mutating": True,
                "requires_confirmation": True,
                "requires_admin": False,
                "requires_restart": False,
                "requires_network": True,
                "may_cost_money": False,
                "inputs": {"requirement": requirements.get("model") or {}, "root": str(root)},
                "expected_outputs": ["model marker", "verified model files"],
                "rollback": "Remove only the managed model through the advertised TransVortex operation API",
            }
        )
    route = _provider_route(provider)
    if route in {"local_service", "remote_provider"}:
        probe_args = ["provider-test", "--confirm-network"]
        probe_command = "transvortex --root <config-root> asr provider-test --confirm-network --providers-file <providers-file> --json"
        if route == "remote_provider":
            probe_args.extend(["--confirm-media", "--confirm-cost"])
            probe_command = "transvortex --root <config-root> asr provider-test --confirm-network --confirm-media --confirm-cost --providers-file <providers-file> --json"
        actions.append(
            {
                "id": "route_probe",
                "kind": "authorized_route_probe",
                "description": "Run the minimal ASR route probe after separate network/privacy confirmation",
                "mutating": True,
                "requires_confirmation": True,
                "requires_admin": False,
                "requires_restart": False,
                "requires_network": True,
                "may_cost_money": route == "remote_provider",
                "command": probe_command,
                "argv": asr_argv(*probe_args),
                "expected_outputs": ["provider test result with code=ready"],
                "rollback": "No TransVortex files are changed except the non-secret probe status record",
            }
        )
    actions.append(
        {
            "id": "verify",
            "kind": "strict_read_only_verification",
            "description": "Re-read readiness and managed integrity after approved actions",
            "mutating": False,
            "requires_confirmation": False,
            "requires_admin": False,
            "requires_restart": False,
            "requires_network": False,
            "may_cost_money": False,
            "command": "transvortex --root <config-root> asr setup-verify --strict --providers-file <providers-file> --json",
            "argv": asr_argv("setup-verify", "--strict"),
            "expected_outputs": ["ok=true", "all applicable checks pass"],
            "rollback": "No changes are made",
        }
    )
    return actions


def _applicable_success_conditions(provider: Any, current: dict[str, Any] | None = None) -> list[str]:
    route = _provider_route(provider) if provider is not None else None
    kind = str(provider.get("kind") or "") if isinstance(provider, dict) else str(getattr(provider, "kind", "") or "")
    conditions = ["transvortex_asr_readiness_can_run", "no_secret_value_is_written_to_the_setup_report"]
    if route == "managed":
        conditions.extend(["managed_runtime_marker_matches_catalog", "selected_model_files_match_catalog_hashes"])
        device = str(provider.get("device") or "") if isinstance(provider, dict) else str(getattr(provider.local, "device", "") or "")
        accelerator_used = device == "cuda" or (
            device == "auto"
            and any(
                isinstance(row, dict)
                and str(row.get("id") or "") == "nvidia-cuda12"
                and row.get("installed") is True
                for row in _list_value((current or {}).get("accelerators"))
            )
        )
        if accelerator_used:
            conditions.append("required_accelerator_and_cuda_probe_pass")
    elif route == "reuse_model":
        conditions.append("existing_external_asr_is_registered_and_protocol_compatible")
    elif route in {"local_service", "remote_provider"}:
        conditions.append("existing_external_asr_is_registered_and_protocol_compatible")
    elif route == "cli_external" and kind == "local_worker":
        conditions.append("existing_external_asr_is_registered_and_protocol_compatible")
    if kind == "local_worker":
        conditions.append("local_worker_protocol_and_model_probe_pass")
    return conditions


def _normalize_catalog(raw: Any) -> tuple[dict[str, Any], str]:
    """Keep malformed catalog JSON inside the structured setup contract."""

    if not isinstance(raw, dict) or _safe_int(raw.get("schema_version")) != 1:
        return {"schema_version": 1, "runtime": {}, "accelerators": [], "models": []}, "catalog_invalid"
    catalog = dict(raw)
    error = ""
    if not isinstance(catalog.get("runtime"), dict):
        catalog["runtime"] = {}
        error = "catalog_invalid"
    if not isinstance(catalog.get("accelerators"), list):
        catalog["accelerators"] = []
        error = "catalog_invalid"
    if not isinstance(catalog.get("models"), list):
        catalog["models"] = []
        error = "catalog_invalid"
    return catalog, error


def _environment_candidates(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    """Project registered environments without launching PATH/conda processes."""

    rows: list[dict[str, Any]] = []
    for raw in _list_value(snapshot.get("environments")):
        if not isinstance(raw, dict):
            continue
        probe = raw.get("probe") if isinstance(raw.get("probe"), dict) else {}
        rows.append(
            {
                "id": str(raw.get("id") or ""),
                "source": str(raw.get("source") or ""),
                "python_executable": str(raw.get("python_executable") or ""),
                "updated_at": str(raw.get("updated_at") or ""),
                "model_ids": sorted(str(key) for key in (raw.get("model_paths") or {}) if isinstance(key, str))
                if isinstance(raw.get("model_paths"), dict)
                else [],
                "probe": {
                    "ok": probe.get("ok") is True,
                    "code": str(probe.get("code") or ""),
                    "protocol_version": _safe_int(probe.get("protocol_version")),
                    "cuda": _hardware_payload(probe.get("cuda")),
                },
            }
        )
    return rows


def _readiness_payload(readiness: Any) -> dict[str, Any]:
    raw = readiness if isinstance(readiness, dict) else {}
    details = raw.get("details") if isinstance(raw.get("details"), dict) else {}
    # Keep details useful for an Agent while explicitly excluding arbitrary
    # provider/config fields.  The CLI's final redaction is an extra guard.
    allowed_detail_keys = {
        "runtime_source",
        "runtime_version",
        "runtime_id",
        "model_source",
        "model",
        "model_path",
        "python_executable",
        "supported_compute_types",
        "credential_source",
        "checked_at",
        "hardware_probe",
        "cuda",
    }
    safe_details: dict[str, Any] = {}
    for key in sorted(details):
        if key not in allowed_detail_keys:
            continue
        safe_details[key] = _hardware_payload(details[key]) if key in {"hardware_probe", "cuda"} else details[key]
    return {
        "state": str(raw.get("state") or "unavailable"),
        "code": str(raw.get("code") or "unknown"),
        "can_run": _is_true(raw.get("can_run")),
        "primary_action": str(raw.get("primary_action") or ""),
        "checked_at": str(raw.get("checked_at") or ""),
        "details": safe_details,
    }


def _provider_test_payload(provider: Any, *, root_dir: Path) -> dict[str, Any]:
    """Expose only the last route probe status, never its response details."""

    try:
        paths = asr_runtime_paths(root_dir)
        state = load_asr_runtime_state(paths)
        raw = (state.get("provider_tests") or {}).get(provider_test_fingerprint(provider))
    except Exception:  # noqa: BLE001 - probe history is optional discovery metadata
        raw = None
    if not isinstance(raw, dict):
        return {"status": "not_run", "ok": False, "code": "route_probe_required", "checked_at": ""}
    age_seconds = _provider_test_age_seconds(raw)
    raw_code = _safe_code(raw.get("code"), "route_probe_failed")
    details = raw.get("details") if isinstance(raw.get("details"), dict) else {}
    try:
        credential_matches = str(raw.get("credential_fingerprint") or "") == provider_credential_fingerprint(
            provider,
            root_dir=root_dir,
        )
    except Exception:  # noqa: BLE001 - credential values never leave the resolver
        credential_matches = False
    evidence_matches = (
        str(details.get("protocol") or "") == str(provider.protocol or "")
        and str(details.get("model") or "") == str(provider.model or "")
    )
    if raw_code == "ready" and age_seconds is None:
        raw_code = "route_probe_invalid"
    elif raw_code == "ready" and age_seconds > _PROVIDER_TEST_MAX_AGE_SECONDS:
        raw_code = "route_probe_stale"
    elif raw_code == "ready" and not evidence_matches:
        raw_code = "route_probe_evidence_mismatch"
    elif raw_code == "ready" and not credential_matches:
        raw_code = "route_probe_credential_changed"
    passed = _provider_test_success(raw) and evidence_matches and credential_matches
    transport_raw = details.get("transport") if isinstance(details.get("transport"), dict) else {}
    transport = {
        key: transport_raw[key]
        for key in (
            "transport",
            "http_version",
            "http2_requested",
            "http2_enabled",
            "streaming",
            "attempts",
            "runtime_source",
            "runtime_id",
            "device",
            "compute_type",
        )
        if key in transport_raw
    }
    return {
        "status": "pass" if passed else "fail",
        "ok": passed,
        "code": raw_code,
        "checked_at": str(raw.get("checked_at") or ""),
        "stale": age_seconds is None or age_seconds > _PROVIDER_TEST_MAX_AGE_SECONDS,
        "age_seconds": age_seconds,
        "evidence": {
            "protocol": str(details.get("protocol") or ""),
            "model": str(details.get("model") or ""),
            "row_count": _safe_int(details.get("row_count")),
            "transport": transport,
        },
    }


def _provider_test_age_seconds(raw: Any) -> int | None:
    if not isinstance(raw, dict):
        return None
    value = str(raw.get("checked_at") or "").strip()
    if not value:
        return None
    try:
        checked = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if checked.tzinfo is None:
            checked = checked.replace(tzinfo=timezone.utc)
        age = int((datetime.now(timezone.utc) - checked).total_seconds())
        if age < -300:
            return None
        return max(age, 0)
    except (TypeError, ValueError, OverflowError):
        return None


def _provider_test_success(raw: Any) -> bool:
    """A route probe is successful only when its structured result says ready."""

    return (
        isinstance(raw, dict)
        and raw.get("ok") is True
        and _safe_code(raw.get("code"), "route_probe_failed") == "ready"
        and (_provider_test_age_seconds(raw) is not None)
        and (_provider_test_age_seconds(raw) <= _PROVIDER_TEST_MAX_AGE_SECONDS)
    )


def provider_test_error_payload(
    code: str,
    *,
    provider_name: str = "",
    network_access: bool = True,
    required_confirmations: list[str] | None = None,
) -> dict[str, Any]:
    """Return one stable envelope for probe precondition failures."""

    payload: dict[str, Any] = {
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "contract": AGENT_SETUP_CONTRACT,
        "kind": "provider_test",
        "ok": False,
        "status": "needs_user" if code == "confirmation_required" else "failed",
        "code": _safe_code(code, "provider_test_failed"),
        "provider": str(provider_name or ""),
        "probe": {"status": "not_run", "ok": False, "code": _safe_code(code, "provider_test_failed"), "checked_at": ""},
        "network_access": bool(network_access),
        "requires_user_authorization": bool(network_access),
        "read_only": False,
    }
    if required_confirmations:
        payload["required_confirmations"] = [str(item) for item in required_confirmations]
    return payload


def provider_test_contract_payload(
    provider: Any,
    result: dict[str, Any],
    *,
    root_dir: Path,
) -> dict[str, Any]:
    """Project an ASR probe result without returning transport/error details."""

    probe = _provider_test_payload(provider, root_dir=root_dir)
    result_ok = result.get("ok") is True
    passed = result_ok and _provider_test_success(probe)
    result_code = _safe_code(result.get("code"), "route_probe_failed")
    if not result_ok:
        probe = {
            "status": "fail",
            "ok": False,
            "code": result_code,
            "checked_at": str(result.get("checked_at") or ""),
            "stale": False,
            "age_seconds": None,
        }
    transport_raw = result.get("transport") if isinstance(result.get("transport"), dict) else {}
    transport = {
        key: transport_raw[key]
        for key in (
            "transport",
            "http_version",
            "http2_requested",
            "http2_enabled",
            "streaming",
            "attempts",
            "runtime_source",
            "runtime_id",
            "device",
            "compute_type",
        )
        if key in transport_raw
    }
    return {
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "contract": AGENT_SETUP_CONTRACT,
        "kind": "provider_test",
        "ok": passed,
        "status": "ready" if passed else "failed",
        "code": str(probe.get("code") or result_code or "route_probe_failed"),
        "provider": _provider_payload(provider, root_dir=root_dir),
        "probe": {
            "status": str(probe.get("status") or "fail"),
            "ok": passed,
            "code": str(probe.get("code") or "route_probe_failed"),
            "checked_at": str(probe.get("checked_at") or ""),
            "stale": probe.get("stale") is True,
            "age_seconds": probe.get("age_seconds"),
            "protocol": str(getattr(provider, "protocol", "") or ""),
            "model": str(getattr(provider, "model", "") or ""),
            "row_count": _safe_int(result.get("row_count")),
            "transport": transport,
        },
        "network_access": True,
        "requires_user_authorization": True,
        "read_only": False,
        "writes": ["non-secret provider probe status"],
    }


def _snapshot_payload(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Keep runtime state useful without copying arbitrary catalog fields."""

    runtime_raw = snapshot.get("runtime") if isinstance(snapshot.get("runtime"), dict) else {}
    runtime = {
        "id": str(runtime_raw.get("id") or ""),
        "version": str(runtime_raw.get("version") or ""),
        "platform": str(runtime_raw.get("platform") or ""),
        "protocol_version": _safe_int(runtime_raw.get("protocol_version")),
        "installed": _is_true(runtime_raw.get("installed")),
        "artifact": _artifact_payload(runtime_raw.get("artifact")),
    }
    accelerators: list[dict[str, Any]] = []
    for raw in _list_value(snapshot.get("accelerators")):
        if not isinstance(raw, dict):
            continue
        packages = raw.get("packages") if isinstance(raw.get("packages"), dict) else {}
        row: dict[str, Any] = {
            "id": str(raw.get("id") or ""),
            "version": str(raw.get("version") or ""),
            "platform": str(raw.get("platform") or ""),
            "packages": {str(key): str(value) for key, value in sorted(packages.items())},
            "installed": _is_true(raw.get("installed")),
            "artifact": _artifact_payload(raw.get("artifact")),
        }
        if isinstance(raw.get("hardware_probe"), dict):
            row["hardware_probe"] = _hardware_payload(raw["hardware_probe"])
        accelerators.append(row)
    models: list[dict[str, Any]] = []
    for raw in _list_value(snapshot.get("models")):
        if not isinstance(raw, dict):
            continue
        files: list[dict[str, Any]] = []
        for item in _list_value(raw.get("files")):
            if not isinstance(item, dict):
                continue
            files.append(
                {
                    "path": str(item.get("path") or ""),
                    "size": _safe_int(item.get("size")),
                    "sha256": str(item.get("sha256") or ""),
                }
            )
        row = {
            "id": str(raw.get("id") or ""),
            "display_name": str(raw.get("display_name") or ""),
            "repository": str(raw.get("repository") or ""),
            "revision": str(raw.get("revision") or ""),
            "installed": _is_true(raw.get("installed")),
            "path": str(raw.get("path") or ""),
            "size": _safe_int(raw.get("size")),
            "files": files,
        }
        models.append(row)
    registered_models: list[dict[str, Any]] = []
    for raw in _list_value(snapshot.get("registered_models")):
        if not isinstance(raw, dict):
            continue
        probe = raw.get("probe") if isinstance(raw.get("probe"), dict) else {}
        model_probe = probe.get("model") if isinstance(probe.get("model"), dict) else {}
        transcription_probe = probe.get("transcription") if isinstance(probe.get("transcription"), dict) else {}
        registered_models.append(
            {
                "id": str(raw.get("id") or ""),
                "model_id": str(raw.get("model_id") or ""),
                "model_path": str(raw.get("model_path") or ""),
                "signature": str(raw.get("signature") or ""),
                "updated_at": str(raw.get("updated_at") or ""),
                "probe": {
                    "ok": probe.get("ok") is True,
                    "protocol_version": _safe_int(probe.get("protocol_version")),
                    "model_loaded": model_probe.get("loaded") is True,
                    "transcription_ok": transcription_probe.get("ok") is True,
                },
            }
        )
    return {
        "paths": {
            str(key): str(value)
            for key, value in (snapshot.get("paths") or {}).items()
            if key in {"app_data_root", "components_root", "models_root", "downloads_root"}
        },
        "runtime": runtime,
        "accelerators": accelerators,
        "models": models,
        "registered_models": registered_models,
    }


def _blocking_item(code: str, message: str, *, action: str = "") -> dict[str, str]:
    return {
        "code": str(code),
        "severity": "blocking",
        "message": str(message),
        "recommended_action": str(action),
    }


def _catalog_pin_blockers(
    catalog: dict[str, Any],
    selected_model: dict[str, Any] | None,
    *,
    require_runtime: bool,
    require_accelerator: bool,
    require_model: bool,
) -> list[dict[str, str]]:
    """Reject advertised assets that are not sufficiently pinned to apply."""

    blockers: list[dict[str, str]] = []
    runtime = catalog.get("runtime") if isinstance(catalog.get("runtime"), dict) else {}
    accelerator = next(
        (
            item
            for item in _list_value(catalog.get("accelerators"))
            if isinstance(item, dict) and item.get("id") == "nvidia-cuda12"
        ),
        None,
    )
    entries = []
    if require_runtime:
        entries.append(("runtime", runtime))
    if require_accelerator:
        entries.append(("accelerator", accelerator))
    for label, entry in entries:
        if not isinstance(entry, dict):
            blockers.append(
                _blocking_item(
                    f"{label}_not_cataloged",
                    f"The required ASR {label} component is not present in the trusted catalog",
                    action="repair_catalog",
                )
            )
            continue
        artifact = entry.get("artifact") if isinstance(entry.get("artifact"), dict) else {}
        if not artifact.get("published"):
            continue
        if (
            not _is_trusted_https_url(artifact.get("url"))
            or _safe_int(artifact.get("size")) <= 0
            or not _SHA256_RE.fullmatch(str(artifact.get("sha256") or ""))
        ):
            blockers.append(
                _blocking_item(
                    f"{label}_asset_not_pinned",
                    f"Published ASR {label} asset is missing a valid HTTPS URL, size, or SHA-256",
                    action="repair_catalog",
                )
            )
    if require_model and selected_model is not None:
        files = selected_model.get("files") if isinstance(selected_model.get("files"), list) else []
        if (
            not str(selected_model.get("id") or "")
            or not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", str(selected_model.get("repository") or ""))
            or not str(selected_model.get("revision") or "")
            or not re.fullmatch(r"[A-Za-z0-9._-]+", str(selected_model.get("revision") or ""))
            or not files
            or any(
                not isinstance(item, dict)
                or not str(item.get("path") or "")
                or not _safe_manifest_path(item.get("path"))
                or _safe_int(item.get("size")) <= 0
                or not _SHA256_RE.fullmatch(str(item.get("sha256") or ""))
                for item in files
            )
        ):
            blockers.append(
                _blocking_item(
                    "model_manifest_not_pinned",
                    "Selected ASR model is missing a revision or complete file hashes",
                    action="repair_catalog",
                )
            )
    if require_model and selected_model is None:
        blockers.append(
            _blocking_item(
                "model_not_cataloged",
                "The selected managed ASR model is not present in the trusted catalog",
                action="choose_model",
            )
        )
    return blockers


def _managed_blockers(provider: Any, readiness: dict[str, Any], snapshot: dict[str, Any]) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    code = str(readiness.get("code") or "")
    if code and code != "ready":
        blockers.append(
            _blocking_item(
                code,
                f"ASR readiness is {readiness.get('state', 'unavailable')}: {code}",
                action=str(readiness.get("primary_action") or ""),
            )
        )
    if provider.kind != "local_worker":
        return blockers
    if provider.runtime.source == "managed":
        runtime = snapshot.get("runtime") if isinstance(snapshot.get("runtime"), dict) else {}
        if runtime.get("installed") is not True:
            blockers.append(_blocking_item("runtime_not_installed", "Managed Whisper runtime is not installed", action="install_runtime"))
    if provider.local.model_source == "managed":
        model_id = str(provider.model or "")
        model_rows = _list_value(snapshot.get("models"))
        model_row = next((row for row in model_rows if isinstance(row, dict) and str(row.get("id") or "") == model_id), None)
        if not isinstance(model_row, dict) or model_row.get("installed") is not True:
            blockers.append(_blocking_item("model_not_installed", f"Managed model is not installed: {model_id}", action="install_model"))
    if provider.runtime.source == "managed" and provider.local.device == "cuda":
        accelerators = _list_value(snapshot.get("accelerators"))
        accelerator = next(
            (row for row in accelerators if isinstance(row, dict) and str(row.get("id") or "") == "nvidia-cuda12"),
            None,
        )
        if not isinstance(accelerator, dict) or accelerator.get("installed") is not True:
            blockers.append(_blocking_item("accelerator_not_installed", "NVIDIA CUDA user-space component is not installed", action="install_accelerator"))
    return blockers


def _load_context(root_dir: Path, providers_file: Path | None) -> dict[str, Any]:
    root = Path(root_dir).expanduser().resolve()
    resolved_providers = resolve_providers_file(root, providers_file)
    paths = asr_runtime_paths(root)
    catalog_error = ""
    try:
        catalog, catalog_error = _normalize_catalog(load_asr_catalog())
    except Exception:  # noqa: BLE001 - preserve a machine-readable plan on catalog failure
        catalog = {"schema_version": 1, "runtime": {}, "accelerators": [], "models": []}
        catalog_error = "catalog_load_failed"
    context: dict[str, Any] = {
        "root": root,
        "providers_file": resolved_providers,
        "paths": paths,
        "catalog": catalog,
        "config": None,
        "provider": None,
        "readiness": {
            "state": "unavailable",
            "code": "config_load_failed",
            "can_run": False,
            "primary_action": "repair_config",
            "checked_at": "",
            "details": {},
        },
        "config_error": "",
        "readiness_error": "",
        "catalog_error": catalog_error,
    }
    try:
        config = load_app_config(root_dir=root, providers_file=resolved_providers)
    except Exception:  # noqa: BLE001 - setup must remain machine-readable
        context["config_error"] = "config_load_failed"
        return context
    provider = config.asr_providers.get(config.pipeline.asr_provider)
    context["config"] = config
    context["provider"] = provider
    if provider is None:
        context["readiness"] = {
            "state": "unavailable",
            "code": "asr_provider_missing",
            "can_run": False,
            "primary_action": "choose_provider",
            "checked_at": "",
            "details": {},
        }
    else:
        try:
            context["readiness"] = _readiness_payload(asr_provider_readiness(provider, root_dir=root))
        except Exception:  # noqa: BLE001 - preserve a structured Agent response
            context["readiness_error"] = "readiness_probe_failed"
            context["readiness"] = {
                "state": "unavailable",
                "code": "readiness_probe_failed",
                "can_run": False,
                "primary_action": "repair_asr_configuration",
                "checked_at": "",
                "details": {},
            }
    return context


def setup_failure_payload(*, kind: str, root_dir: Path, code: str = "setup_contract_failed") -> dict[str, Any]:
    """Return a schema-compatible, secret-free CLI failure envelope."""

    blocker = _blocking_item(code, "The Agent setup contract could not be generated", action="inspect_configuration")
    readiness = {
        "state": "unavailable",
        "code": code,
        "can_run": False,
        "primary_action": "inspect_configuration",
        "checked_at": "",
        "details": {},
    }
    base: dict[str, Any] = {
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "contract": AGENT_SETUP_CONTRACT,
        "kind": kind,
        "ok": False,
        "ready": False,
        "root_dir": str(root_dir),
        "active_asr": None,
        "blocking_items": [blocker],
        "success_conditions": ["transvortex_asr_readiness_can_run", "no_secret_value_is_written_to_the_setup_report"],
        "read_only": True,
        "network_access": False,
    }
    if kind == "setup_verify":
        return {
            **base,
            "verified_at": utc_now_iso(),
            "readiness": readiness,
            "checks": [{"id": "setup_contract", "status": "fail", "code": code, "message": blocker["message"]}],
            "integrity": {
                "runtime_marker": {"status": "not_checked"},
                "accelerator_marker": {"status": "not_checked"},
                "model_files": {"status": "not_checked"},
                "hashes_not_checked": [],
            },
            "route": None,
            "plan_id": "",
        }
    plan_id = "setup-error-" + hashlib.sha256(f"{root_dir}:{code}".encode("utf-8")).hexdigest()[:12]
    return {
        **base,
        "plan_status": "blocked",
        "generated_at": utc_now_iso(),
        "product": {"name": "transvortex", "version": _package_version()},
        "platform": {"system": platform.system().lower(), "machine": platform.machine().lower(), "disk": {"free_bytes": None, "total_bytes": None}},
        "route": None,
        "observed_route": None,
        "alternatives": [],
        "plan_id": plan_id,
        "current": {"readiness": readiness, "runtime": {}, "accelerators": [], "models": [], "registered_models": [], "environment_candidates": [], "provider_test": None},
        "requirements": {"runtime": None, "accelerator": None, "model": None, "available_models": []},
        "allowed_actions": list(ALLOWED_ACTIONS),
        "forbidden_actions": list(FORBIDDEN_ACTIONS),
        "verification": {"command": "", "argv": [], "read_only": True, "network_access": False},
        "plan": {"plan_id": plan_id, "created_at": utc_now_iso(), "route": None, "actions": [], "rollback": []},
    }


def setup_plan_payload(*, root_dir: Path, providers_file: Path | None = None) -> dict[str, Any]:
    """Return a read-only, versioned setup contract for a local Agent."""

    context = _load_context(root_dir, providers_file)
    root = context["root"]
    agent_cli_prefix = cli_argv_prefix(root_dir=root)
    paths = context["paths"]
    catalog = context["catalog"]
    provider = context["provider"]
    readiness = context["readiness"]
    try:
        snapshot = asr_runtime_snapshot(root)
    except Exception:  # noqa: BLE001 - catalog/config failures stay structured
        snapshot = {
            "paths": {
                "app_data_root": str(paths.app_data_root),
                "components_root": str(paths.components_root),
                "models_root": str(paths.models_root),
                "downloads_root": str(paths.downloads_root),
            },
            "runtime": {},
            "accelerators": [],
            "models": [],
            "environment_candidates": [],
        }
    safe_snapshot = _snapshot_payload(snapshot)
    environment_error = ""
    try:
        environment_candidates = _environment_candidates(snapshot)
    except Exception:  # noqa: BLE001 - discovery must not break the contract
        environment_candidates = []
        environment_error = "environment_discovery_failed"
    runtime_required, accelerator_required, model_required = _component_requirements(provider, snapshot)
    model_id = str(provider.model) if provider is not None and model_required else ""
    selected_model = _model_requirement(model_catalog_entry(catalog, model_id)) if model_required else None
    active_asr = _provider_payload(provider, root_dir=root) if provider is not None else None
    blockers: list[dict[str, str]] = []
    if context["catalog_error"] and (runtime_required or accelerator_required or model_required):
        blockers.append(_blocking_item(context["catalog_error"], "The ASR component catalog is invalid or could not be loaded", action="repair_catalog"))
    if context["config_error"]:
        blockers.append(_blocking_item("config_load_failed", "TransVortex configuration could not be loaded", action="repair_config"))
    elif context["readiness_error"]:
        blockers.append(
            _blocking_item(
                "readiness_probe_failed",
                "The active ASR readiness probe failed",
                action="repair_asr_configuration",
            )
        )
    elif provider is None:
        blockers.append(_blocking_item("asr_provider_missing", "The active ASR provider is missing", action="choose_provider"))
    else:
        blockers.extend(_managed_blockers(provider, readiness, snapshot))
        route_policy_code = asr_provider_endpoint_policy_code(provider) if provider.kind in {"local_server", "remote"} else ""
        if route_policy_code:
            blockers.append(
                _blocking_item(
                    route_policy_code,
                    "The configured ASR endpoint violates the route URL policy",
                    action="choose_provider",
                )
            )
        if isinstance(active_asr, dict) and active_asr.get("credential_metadata_valid") is not True:
            blockers.append(
                _blocking_item(
                    "credential_metadata_invalid",
                    "Credential metadata must use a non-secret env_key and credential_id reference",
                    action="repair_config",
                )
            )
        if (
            isinstance(active_asr, dict)
            and active_asr.get("credential_required") is True
            and active_asr.get("credential_configured") is not True
            and str(readiness.get("code") or "") != "credential_missing"
        ):
            blockers.append(_blocking_item("credential_missing", "The active ASR credential reference is unresolved", action="set_credential"))
        if str(provider.kind) in {"local_server", "remote"}:
            probe = _provider_test_payload(provider, root_dir=root)
            if not _provider_test_success(probe):
                code = str(probe.get("code") or "route_probe_required")
                blockers.append(
                    _blocking_item(
                        code if code != "ready" else "route_probe_required",
                        "The configured ASR route has not passed its provider probe",
                        action="run_route_probe",
                    )
                )
    blockers.extend(
        _catalog_pin_blockers(
            catalog,
            selected_model,
            require_runtime=runtime_required,
            require_accelerator=accelerator_required,
            require_model=model_required,
        )
    )
    plan_status = "ready" if not blockers else "needs_action"
    if str(readiness.get("state")) == "unavailable" and str(readiness.get("code")) not in {
        "runtime_unpublished",
        "runtime_missing",
        "model_missing",
        "device_unavailable",
        "hardware_untested",
    }:
        plan_status = "blocked"
    requirements = {
        "runtime": _runtime_requirement(catalog) if runtime_required else None,
        "accelerator": _accelerator_requirement(catalog) if accelerator_required else None,
        "model": selected_model,
        "available_models": [
            item
            for raw in _list_value(catalog.get("models"))
            if (item := _model_requirement(raw)) is not None
        ],
    }
    current = {
        "readiness": readiness,
        "paths": safe_snapshot.get("paths", {}),
        "runtime": safe_snapshot.get("runtime", {}),
        "accelerators": safe_snapshot.get("accelerators", []),
        "models": safe_snapshot.get("models", []),
        "registered_models": safe_snapshot.get("registered_models", []),
        "environment_candidates": environment_candidates,
        "provider_test": (
            _provider_test_payload(provider, root_dir=root)
            if provider is not None and provider.kind in {"local_server", "remote"}
            else None
        ),
    }
    actions = _plan_actions(
        provider=provider,
        requirements=requirements,
        root=root,
        providers_file=context["providers_file"],
    )
    alternatives = _route_alternatives(provider, blockers, current=current, requirements=requirements)
    observed_route = _provider_route(provider) if provider is not None else None
    plan_identity = {
        "contract": AGENT_SETUP_CONTRACT,
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "root_dir": str(root),
        "active_asr": active_asr,
        "readiness": {
            "state": readiness.get("state"),
            "code": readiness.get("code"),
            "can_run": readiness.get("can_run") is True,
        },
        "requirements": requirements,
        "blocking_codes": [str(item.get("code") or "") for item in blockers],
    }
    plan_id = "setup-" + hashlib.sha256(json.dumps(plan_identity, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()[:16]
    plan = {
        "plan_id": plan_id,
        "created_at": utc_now_iso(),
        "route": None,
        "observed_route": observed_route,
        "actions": actions,
        "rollback": [
            "Do not delete or overwrite user-owned model directories",
            "Use only the advertised TransVortex operation removal/cancel capability for managed components",
        ],
    }
    return {
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "contract": AGENT_SETUP_CONTRACT,
        "kind": "setup_plan",
        "ok": True,
        "ready": plan_status == "ready",
        "read_only": True,
        "network_access": False,
        "plan_status": plan_status,
        "generated_at": utc_now_iso(),
        "product": {"name": "transvortex", "version": _package_version()},
        "platform": _platform_payload(paths.app_data_root),
        "root_dir": str(root),
        "providers_file": str(context["providers_file"]),
        "route": None,
        "observed_route": observed_route,
        "alternatives": alternatives,
        "plan_id": plan_id,
        "active_asr": active_asr,
        "current": current,
        "requirements": requirements,
        "allowed_actions": list(ALLOWED_ACTIONS),
        "forbidden_actions": list(FORBIDDEN_ACTIONS),
        "blocking_items": blockers,
        "success_conditions": _applicable_success_conditions(provider, current),
        "plan": plan,
        "agent_commands": {
            "plan": "transvortex --root <config-root> asr setup-plan --providers-file <providers-file> --json",
            "verify": "transvortex --root <config-root> asr setup-verify --strict --providers-file <providers-file> --json",
            "doctor": "transvortex --root <config-root> doctor --providers-file <providers-file> --json",
            "protocol": "transvortex --root <config-root> agent-info --json",
        },
        "agent_argv": {
            "plan": [*agent_cli_prefix, "asr", "setup-plan", "--providers-file", str(context["providers_file"]), "--json"],
            "verify": [*agent_cli_prefix, "asr", "setup-verify", "--strict", "--providers-file", str(context["providers_file"]), "--json"],
            "doctor": [*agent_cli_prefix, "doctor", "--providers-file", str(context["providers_file"]), "--json"],
            "protocol": [*agent_cli_prefix, "agent-info", "--json"],
        },
        "verification": {
            "command": "transvortex --root <config-root> asr setup-verify --strict --providers-file <providers-file> --json",
            "argv": [*agent_cli_prefix, "asr", "setup-verify", "--strict", "--providers-file", str(context["providers_file"]), "--json"],
            "read_only": True,
            "network_access": False,
            "executes_local_code": provider is not None and provider.kind == "local_worker",
        },
        "config_error": str(context["config_error"] or ""),
        "catalog_error": str(context["catalog_error"] or ""),
        "readiness_error": str(context["readiness_error"] or ""),
        "environment_error": environment_error,
    }


def _resolved_child(root: Path, relative: str) -> Path | None:
    """Resolve an installed child while rejecting path escapes and links."""

    try:
        root_expanded = root.expanduser()
        for candidate in (root_expanded, *root_expanded.parents):
            if _is_reparse_path(candidate):
                return None
        root_resolved = root_expanded.resolve()
        lexical = root_resolved / relative
        # Check the lexical path before resolving it; checking only the
        # resolved path would make a symlink appear indistinguishable from a
        # regular file.  Inspect parents as well so a linked model directory
        # cannot smuggle a file outside the managed root.
        try:
            relative_parts = lexical.relative_to(root_resolved).parts
        except ValueError:
            return None
        current = root_resolved
        for part in relative_parts:
            current = current / part
            if _is_reparse_path(current):
                return None
        child = lexical.resolve(strict=False)
    except (OSError, ValueError, RuntimeError):
        return None
    try:
        child.relative_to(root_resolved)
    except ValueError:
        return None
    if _is_reparse_path(child):
        return None
    return child


def _is_reparse_path(path: Path) -> bool:
    """Reject symlinks/junctions before integrity checks follow them."""

    try:
        if path.is_symlink():
            return True
        is_junction = getattr(path, "is_junction", None)
        if callable(is_junction) and is_junction():
            return True
        attributes = int(getattr(path.lstat(), "st_file_attributes", 0) or 0)
        return bool(attributes & 0x400)  # FILE_ATTRIBUTE_REPARSE_POINT
    except FileNotFoundError:
        return False
    except OSError:
        return True


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().lower()


def _integrity_payload(plan: dict[str, Any]) -> dict[str, Any]:
    """Check installed markers and model file hashes against the catalog."""

    current = plan.get("current") if isinstance(plan.get("current"), dict) else {}
    paths = current.get("paths") if isinstance(current.get("paths"), dict) else {}
    components_root_raw = str(paths.get("components_root") or "").strip()
    models_root_raw = str(paths.get("models_root") or "").strip()
    components_root = Path(components_root_raw) if components_root_raw else None
    models_root = Path(models_root_raw) if models_root_raw else None
    requirements = plan.get("requirements") if isinstance(plan.get("requirements"), dict) else {}
    active = plan.get("active_asr") if isinstance(plan.get("active_asr"), dict) else {}
    is_local_worker = active.get("kind") == "local_worker"
    runtime_required = is_local_worker and active.get("runtime_source") == "managed"
    model_required = is_local_worker and active.get("model_source") == "managed"
    accelerator_required = runtime_required and (
        active.get("device") == "cuda"
        or (
            active.get("device") == "auto"
            and any(
                isinstance(row, dict)
                and str(row.get("id") or "") == "nvidia-cuda12"
                and row.get("installed") is True
                for row in _list_value(current.get("accelerators"))
            )
        )
    )
    runtime_req = requirements.get("runtime") if runtime_required and isinstance(requirements.get("runtime"), dict) else {}
    accelerator_req = requirements.get("accelerator") if accelerator_required and isinstance(requirements.get("accelerator"), dict) else {}
    model_req = requirements.get("model") if model_required and isinstance(requirements.get("model"), dict) else None
    hashes_not_checked: list[str] = []

    runtime_result: dict[str, Any] = {"status": "not_checked", "reason": "not_installed"}
    runtime_version = str(runtime_req.get("version") or "")
    runtime_marker_path = (
        _resolved_child(components_root, f"faster-whisper/{runtime_version}/component.json")
        if components_root is not None and runtime_version
        else None
    )
    if runtime_marker_path is not None and runtime_marker_path.is_file():
        try:
            marker = read_json(runtime_marker_path)
        except (OSError, ValueError, json.JSONDecodeError):
            marker = None
        python_name = str(marker.get("python") or "python.exe") if isinstance(marker, dict) else "python.exe"
        python_path = _resolved_child(runtime_marker_path.parent, python_name)
        marker_ok = (
            isinstance(marker, dict)
            and marker.get("id") == runtime_req.get("id")
            and marker.get("version") == runtime_req.get("version")
            and _safe_int(marker.get("protocol_version")) == _safe_int(runtime_req.get("protocol_version"))
            and (
                not str((runtime_req.get("artifact") or {}).get("sha256") or "")
                or str(marker.get("artifact_sha256") or "").lower()
                == str((runtime_req.get("artifact") or {}).get("sha256") or "").lower()
            )
            and python_path is not None
            and python_path.is_file()
        )
        runtime_result = {
            "status": "pass" if marker_ok else "fail",
            "marker": str(runtime_marker_path),
            "marker_matches_catalog": bool(marker_ok),
            "archive_hash_checked": bool(str((runtime_req.get("artifact") or {}).get("sha256") or "")),
            "archive_hash_source": "install_time_manifest" if str((runtime_req.get("artifact") or {}).get("sha256") or "") else "not_available",
        }
    if runtime_required and not str((runtime_req.get("artifact") or {}).get("sha256") or ""):
        hashes_not_checked.append("runtime_archive_sha256")

    accelerator_result: dict[str, Any] = {"status": "not_checked", "reason": "not_installed"}
    accelerator_version = str(accelerator_req.get("version") or "")
    accelerator_id = str(accelerator_req.get("id") or "")
    accelerator_marker_path = (
        _resolved_child(components_root, f"accelerators/{accelerator_id}/{accelerator_version}/component.json")
        if components_root is not None and accelerator_id and accelerator_version
        else None
    )
    if accelerator_marker_path is not None and accelerator_marker_path.is_file():
        try:
            marker = read_json(accelerator_marker_path)
        except (OSError, ValueError, json.JSONDecodeError):
            marker = None
        marker_ok = (
            isinstance(marker, dict)
            and marker.get("id") == accelerator_req.get("id")
            and marker.get("version") == accelerator_req.get("version")
            and (
                not str((accelerator_req.get("artifact") or {}).get("sha256") or "")
                or str(marker.get("artifact_sha256") or "").lower()
                == str((accelerator_req.get("artifact") or {}).get("sha256") or "").lower()
            )
        )
        accelerator_result = {
            "status": "pass" if marker_ok else "fail",
            "marker": str(accelerator_marker_path),
            "marker_matches_catalog": bool(marker_ok),
            "archive_hash_checked": bool(str((accelerator_req.get("artifact") or {}).get("sha256") or "")),
            "archive_hash_source": "install_time_manifest" if str((accelerator_req.get("artifact") or {}).get("sha256") or "") else "not_available",
        }
    if accelerator_required and not str((accelerator_req.get("artifact") or {}).get("sha256") or ""):
        hashes_not_checked.append("accelerator_archive_sha256")

    model_result: dict[str, Any] = {"status": "not_checked", "reason": "not_required", "checked_files": [], "mismatches": []}
    if isinstance(model_req, dict):
        model_id = str(model_req.get("id") or "")
        revision = str(model_req.get("revision") or "")
        model_root = (
            _resolved_child(models_root, f"{model_id}/{revision}")
            if models_root is not None and model_id and revision
            else None
        )
        if model_root is not None and model_root.is_dir():
            checked_files: list[str] = []
            mismatches: list[dict[str, str]] = []
            marker_path = _resolved_child(model_root, "model.json")
            try:
                marker = read_json(marker_path) if marker_path is not None and marker_path.is_file() else None
            except (OSError, ValueError, json.JSONDecodeError):
                marker = None
            if not isinstance(marker, dict) or marker.get("id") != model_id or marker.get("revision") != revision:
                mismatches.append({"path": "model.json", "reason": "marker_mismatch"})
            model_files = _list_value(model_req.get("files"))
            for item in model_files:
                if not isinstance(item, dict):
                    continue
                relative = str(item.get("path") or "")
                expected = str(item.get("sha256") or "").lower()
                file_path = _resolved_child(model_root, relative)
                if file_path is None or not file_path.is_file() or not expected:
                    mismatches.append({"path": relative, "reason": "missing_or_unhashable"})
                    continue
                try:
                    actual = _sha256_file(file_path)
                except OSError:
                    mismatches.append({"path": relative, "reason": "unreadable"})
                    continue
                checked_files.append(relative)
                if actual != expected:
                    mismatches.append({"path": relative, "reason": "sha256_mismatch"})
            model_result = {
                "status": "pass" if not mismatches and len(checked_files) == len(model_files) else "fail",
                "model": model_id,
                "revision": revision,
                "marker_matches_catalog": isinstance(marker, dict) and marker.get("id") == model_id and marker.get("revision") == revision,
                "checked_files": checked_files,
                "mismatches": mismatches,
            }
        else:
            hashes_not_checked.append("model_files_sha256")
    elif model_required:
        hashes_not_checked.append("model_files_sha256")

    return {
        "runtime_marker": runtime_result,
        "accelerator_marker": accelerator_result,
        "model_files": model_result,
        "hashes_not_checked": hashes_not_checked,
    }


def _local_worker_probe(plan: dict[str, Any], integrity: dict[str, Any]) -> dict[str, Any]:
    """Run the installed worker/model protocol probe without network access."""

    active = plan.get("active_asr") if isinstance(plan.get("active_asr"), dict) else {}
    if active.get("kind") != "local_worker":
        return {"status": "not_checked", "reason": "not_required"}
    current = plan.get("current") if isinstance(plan.get("current"), dict) else {}
    readiness = current.get("readiness") if isinstance(current.get("readiness"), dict) else {}
    if readiness.get("can_run") is not True:
        return {"status": "not_checked", "reason": "readiness_not_ready"}
    if active.get("runtime_source") == "managed" and (integrity.get("runtime_marker") or {}).get("status") != "pass":
        return {"status": "not_checked", "reason": "runtime_integrity_not_ready"}
    if active.get("model_source") == "managed" and (integrity.get("model_files") or {}).get("status") != "pass":
        return {"status": "not_checked", "reason": "model_integrity_not_ready"}
    requirements = plan.get("requirements") if isinstance(plan.get("requirements"), dict) else {}
    paths = current.get("paths") if isinstance(current.get("paths"), dict) else {}
    python_executable: Path | None = None
    if active.get("runtime_source") == "managed":
        runtime_req = requirements.get("runtime") if isinstance(requirements.get("runtime"), dict) else {}
        components_raw = str(paths.get("components_root") or "")
        components_root = Path(components_raw) if components_raw else None
        marker_path = (
            _resolved_child(components_root, f"faster-whisper/{runtime_req.get('version', '')}/component.json")
            if components_root is not None
            else None
        )
        try:
            marker = read_json(marker_path) if marker_path is not None and marker_path.is_file() else None
        except (OSError, ValueError, json.JSONDecodeError):
            marker = None
        if isinstance(marker, dict) and marker_path is not None:
            python_executable = _resolved_child(marker_path.parent, str(marker.get("python") or "python.exe"))
    else:
        runtime_id = str(active.get("runtime_id") or "")
        environment = next(
            (row for row in _list_value(current.get("environment_candidates")) if isinstance(row, dict) and str(row.get("id") or "") == runtime_id),
            None,
        )
        raw_python = str(environment.get("python_executable") or "") if isinstance(environment, dict) else ""
        python_executable = Path(raw_python) if raw_python else None

    model_path: Path | None = None
    if active.get("model_source") == "managed":
        model_id = str(active.get("model") or "")
        model = next(
            (row for row in _list_value(current.get("models")) if isinstance(row, dict) and str(row.get("id") or "") == model_id),
            None,
        )
        raw_model_path = str(model.get("path") or "") if isinstance(model, dict) else ""
        model_path = Path(raw_model_path) if raw_model_path else None
    else:
        details = readiness.get("details") if isinstance(readiness.get("details"), dict) else {}
        raw_model_path = str(details.get("model_path") or "")
        model_path = Path(raw_model_path) if raw_model_path else None

    accelerator_root: Path | None = None
    accelerator_req = requirements.get("accelerator") if isinstance(requirements.get("accelerator"), dict) else None
    if accelerator_req is not None:
        components_raw = str(paths.get("components_root") or "")
        if components_raw:
            accelerator_root = _resolved_child(
                Path(components_raw),
                f"accelerators/{accelerator_req.get('id', '')}/{accelerator_req.get('version', '')}",
            )
    if python_executable is None or not python_executable.is_file() or model_path is None or not model_path.is_dir():
        return {"status": "fail", "code": "runtime_probe_inputs_missing"}
    if any(_is_reparse_path(candidate) for path in (python_executable, model_path) for candidate in (path, *path.parents)):
        return {"status": "fail", "code": "runtime_probe_path_unsafe"}
    try:
        raw = probe_python_environment(
            python_executable,
            model_id=str(active.get("model") or ""),
            model_path=model_path,
            device=str(active.get("device") or "auto"),
            compute_type=str(active.get("compute_type") or "auto"),
            accelerator_root=accelerator_root,
            timeout_seconds=180.0,
        )
    except Exception:  # noqa: BLE001 - probe failures stay structured and secret-free
        raw = {"ok": False, "code": "runtime_probe_failed"}
    model = raw.get("model") if isinstance(raw.get("model"), dict) else {}
    transcription = raw.get("transcription") if isinstance(raw.get("transcription"), dict) else {}
    runtime_req = requirements.get("runtime") if isinstance(requirements.get("runtime"), dict) else {}
    protocol_ok = _safe_int(raw.get("protocol_version")) == _safe_int(runtime_req.get("protocol_version") or 1)
    versions_ok = all(
        not str(runtime_req.get(requirement_key) or "")
        or str(raw.get(probe_key) or "") == str(runtime_req.get(requirement_key) or "")
        for requirement_key, probe_key in (
            ("python_version", "python_version"),
            ("faster_whisper_version", "faster_whisper_version"),
            ("ctranslate2_version", "ctranslate2_version"),
        )
    )
    passed = (
        raw.get("ok") is True
        and protocol_ok
        and versions_ok
        and model.get("loaded") is True
        and transcription.get("ok") is True
    )
    return {
        "status": "pass" if passed else "fail",
        "code": "runtime_probe_passed" if passed else _safe_code(raw.get("code"), "runtime_probe_failed"),
        "protocol_version": _safe_int(raw.get("protocol_version")),
        "versions_match_catalog": versions_ok,
        "python_version": str(raw.get("python_version") or ""),
        "faster_whisper_version": str(raw.get("faster_whisper_version") or ""),
        "ctranslate2_version": str(raw.get("ctranslate2_version") or ""),
        "model_loaded": model.get("loaded") is True,
        "transcription_ok": transcription.get("ok") is True,
        "device": str(model.get("device") or ""),
        "compute_type": str(model.get("compute_type") or ""),
        "cuda": _hardware_payload(raw.get("cuda")),
    }


def setup_verify_payload(*, root_dir: Path, providers_file: Path | None = None) -> dict[str, Any]:
    """Return read-only verification checks for the active ASR setup."""

    plan = setup_plan_payload(root_dir=root_dir, providers_file=providers_file)
    blockers = list(plan.get("blocking_items") or [])
    checks: list[dict[str, Any]] = []
    integrity = _integrity_payload(plan)
    integrity["runtime_probe"] = _local_worker_probe(plan, integrity)
    active_plan = plan.get("active_asr") if isinstance(plan.get("active_asr"), dict) else {}
    catalog_required = active_plan.get("kind") == "local_worker" and (
        active_plan.get("runtime_source") == "managed" or active_plan.get("model_source") == "managed"
    )

    def integrity_status(result: dict[str, Any], installed: bool) -> str:
        status = str(result.get("status") or "not_checked")
        if status == "pass":
            return "pass"
        if status == "fail" or installed:
            return "fail"
        return "skip"
    if plan.get("catalog_error") and catalog_required:
        catalog_code = str(plan.get("catalog_error") or "catalog_load_failed")
        checks.append({"id": "catalog", "status": "fail", "code": catalog_code, "message": "ASR component catalog is invalid or could not be loaded"})
    if plan.get("config_error"):
        checks.append({"id": "config", "status": "fail", "code": "config_load_failed", "message": "Configuration could not be loaded"})
    elif plan.get("readiness_error"):
        checks.append({"id": "readiness_probe", "status": "fail", "code": "readiness_probe_failed", "message": "The active ASR readiness probe failed"})
    elif plan.get("active_asr") is None:
        checks.append({"id": "asr_provider", "status": "fail", "code": "asr_provider_missing", "message": "Active ASR provider is missing"})
    else:
        readiness = plan["current"]["readiness"]
        checks.append(
            {
                "id": "readiness",
                "status": "pass" if readiness.get("can_run") is True else "fail",
                "code": str(readiness.get("code") or "unknown"),
                "message": "ASR readiness probe passed" if readiness.get("can_run") is True else "ASR readiness requires action",
            }
        )
        active = plan["active_asr"]
        accelerator_used = active.get("device") == "cuda" or (
            active.get("device") == "auto"
            and any(
                isinstance(row, dict)
                and str(row.get("id") or "") == "nvidia-cuda12"
                and row.get("installed") is True
                for row in _list_value(plan["current"].get("accelerators"))
            )
        )
        if active.get("kind") == "local_worker":
            runtime_probe = integrity["runtime_probe"]
            runtime_probe_status = str(runtime_probe.get("status") or "not_checked")
            checks.append(
                {
                    "id": "runtime_protocol_probe",
                    "status": "pass" if runtime_probe_status == "pass" else ("fail" if runtime_probe_status == "fail" else "skip"),
                    "code": str(runtime_probe.get("code") or "runtime_probe_not_run"),
                    "message": "Local ASR runtime and model probe passed" if runtime_probe_status == "pass" else "Local ASR runtime and model probe did not pass",
                }
            )
        if active.get("kind") in {"remote", "local_server"}:
            probe = plan["current"].get("provider_test") if isinstance(plan["current"], dict) else None
            probe_ok = _provider_test_success(probe)
            probe_code = str(probe.get("code") or "route_probe_required") if isinstance(probe, dict) else "route_probe_required"
            probe_status = "pass" if probe_ok else ("fail" if isinstance(probe, dict) and probe.get("status") == "fail" else "not_run")
            checks.append(
                {
                    "id": "route_probe",
                    "status": probe_status,
                    "code": "route_probe_passed" if probe_ok else probe_code,
                    "message": "ASR route probe passed" if probe_ok else "ASR route probe has not passed",
                }
            )
        if active.get("kind") == "local_worker" and active.get("runtime_source") == "managed":
            runtime = plan["current"].get("runtime") or {}
            runtime_installed = runtime.get("installed") is True
            checks.append(
                {
                    "id": "managed_runtime",
                    "status": "pass" if runtime_installed else "fail",
                    "code": "runtime_installed" if runtime_installed else "runtime_not_installed",
                    "message": "Managed Whisper runtime is installed" if runtime_installed else "Managed Whisper runtime is not installed",
                }
            )
            checks.append(
                {
                    "id": "managed_runtime_marker",
                    "status": integrity_status(integrity["runtime_marker"], runtime_installed),
                    "code": "runtime_marker_matches_catalog" if integrity["runtime_marker"].get("status") == "pass" else "runtime_marker_not_verified",
                    "message": "Managed runtime marker matches the catalog" if integrity["runtime_marker"].get("status") == "pass" else "Managed runtime marker was not verified",
                }
            )
            if accelerator_used:
                accelerator = next(
                    (row for row in _list_value(plan["current"].get("accelerators")) if isinstance(row, dict) and str(row.get("id") or "") == "nvidia-cuda12"),
                    None,
                )
                accelerator_installed = isinstance(accelerator, dict) and accelerator.get("installed") is True
                checks.append(
                    {
                        "id": "cuda_accelerator",
                        "status": "pass" if accelerator_installed else "fail",
                        "code": "accelerator_installed" if accelerator_installed else "accelerator_not_installed",
                        "message": "NVIDIA CUDA user-space component is installed" if accelerator_installed else "NVIDIA CUDA user-space component is not installed",
                    }
                )
                checks.append(
                    {
                        "id": "cuda_accelerator_marker",
                        "status": integrity_status(integrity["accelerator_marker"], accelerator_installed),
                        "code": "accelerator_marker_matches_catalog" if integrity["accelerator_marker"].get("status") == "pass" else "accelerator_marker_not_verified",
                        "message": "NVIDIA accelerator marker matches the catalog" if integrity["accelerator_marker"].get("status") == "pass" else "NVIDIA accelerator marker was not verified",
                    }
                )
        if active.get("kind") == "local_worker" and active.get("model_source") == "managed":
            model_id = str(active.get("model") or "")
            model = next(
                (row for row in _list_value(plan["current"].get("models")) if isinstance(row, dict) and str(row.get("id") or "") == model_id),
                None,
            )
            model_installed = isinstance(model, dict) and model.get("installed") is True
            checks.append(
                {
                    "id": "managed_model",
                    "status": "pass" if model_installed else "fail",
                    "code": "model_installed" if model_installed else "model_not_installed",
                    "message": "Selected managed model is installed" if model_installed else "Selected managed model is not installed",
                }
            )
            checks.append(
                {
                    "id": "managed_model_hashes",
                    "status": integrity_status(integrity["model_files"], model_installed),
                    "code": "model_hashes_match" if integrity["model_files"].get("status") == "pass" else "model_hashes_not_verified",
                    "message": "Selected model files match catalog SHA-256" if integrity["model_files"].get("status") == "pass" else "Selected model file hashes were not verified",
                }
            )
    # Derive the final result from checks rather than trusting Agent-provided
    # text.  ``blocking_items`` remains useful for a caller that only reads the
    # plan section.
    known_blocker_codes = {
        str(item.get("code") or "")
        for item in blockers
        if isinstance(item, dict)
    }
    remediation = {
        "route_probe": "run_route_probe",
        "runtime_protocol_probe": "repair_runtime_or_model",
        "managed_runtime_marker": "repair_runtime",
        "managed_model_hashes": "repair_model",
        "cuda_accelerator_marker": "repair_accelerator",
        "readiness": "repair_asr_configuration",
        "managed_runtime": "install_runtime",
        "managed_model": "install_model",
        "cuda_accelerator": "install_accelerator",
    }
    for item in checks:
        if item.get("status") not in {"fail", "not_run"}:
            continue
        code = str(item.get("code") or item.get("id") or "verification_failed")
        if code in known_blocker_codes:
            continue
        blockers.append(
            _blocking_item(
                code,
                str(item.get("message") or "ASR verification failed"),
                action=remediation.get(str(item.get("id") or ""), "inspect_verification"),
            )
        )
        known_blocker_codes.add(code)
    ok = (
        all(item.get("status") in {"pass", "skip"} for item in checks)
        and not plan.get("config_error")
        and (not plan.get("catalog_error") or not catalog_required)
        and not any(
            isinstance(item, dict) and item.get("severity") == "blocking"
            for item in plan.get("blocking_items") or []
        )
    )
    return {
        "schema_version": AGENT_SETUP_SCHEMA_VERSION,
        "contract": AGENT_SETUP_CONTRACT,
        "kind": "setup_verify",
        "ok": bool(ok),
        "network_access": False,
        "executes_local_code": isinstance(plan.get("active_asr"), dict) and plan["active_asr"].get("kind") == "local_worker",
        "verified_at": utc_now_iso(),
        "root_dir": plan.get("root_dir"),
        "active_asr": plan.get("active_asr"),
        "readiness": plan.get("current", {}).get("readiness", {}),
        "integrity": integrity,
        "checks": checks,
        "blocking_items": blockers,
        "success_conditions": _applicable_success_conditions(
            plan.get("active_asr") if isinstance(plan.get("active_asr"), dict) else None,
            plan.get("current") if isinstance(plan.get("current"), dict) else None,
        ),
        "route": _provider_route(plan.get("active_asr")) if isinstance(plan.get("active_asr"), dict) else None,
        "plan_id": plan.get("plan_id"),
        "read_only": True,
    }
