from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

import yaml

from ..asr_domain import ASR_CONFIG_SCHEMA_VERSION
from ..openrouter_asr import (
    OPENROUTER_ASR_BASE_URL,
    OPENROUTER_ASR_CREDENTIAL_ID,
    OPENROUTER_ASR_DEFAULT_MODEL,
    OPENROUTER_ASR_ENDPOINT,
    OPENROUTER_ASR_ENV_KEY,
    openrouter_asr_admin_defaults,
)
from ..utils import to_plain
from .asr_resolution import asr_engine_to_yaml_row, resolve_asr_engine
from .config import _parse_asr_provider, load_app_config
from .credentials import auth_file_path, resolve_provider_credential, write_auth_credential
from .models import AsrProviderConfig, NetworkConfig
from .asr_runtime import (
    asr_provider_readiness,
    asr_runtime_snapshot,
    load_asr_catalog,
    model_catalog_entry,
    registered_external_accelerator,
    registered_external_model,
)


ASR_PROVIDER_DEFAULTS = {
    "local_inprocess": {
        "name": "faster_whisper_large_v3",
        "protocol": "faster_whisper",
        "model": "large-v3",
    },
    "local_worker": {
        "name": "faster_whisper_local",
        "protocol": "faster_whisper",
        "model": "large-v3",
    },
    "local_server": {
        "name": "funasr_sensevoice_local",
        "protocol": "funasr_openai",
        "model": "sensevoice",
        "base_url": "http://127.0.0.1:8899",
    },
    "remote": {
        "name": "openai_whisper",
        "protocol": "openai_transcriptions",
        "model": "whisper-1",
        "base_url": "https://api.openai.com/v1",
    },
}


def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _write_yaml(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.safe_dump(payload, allow_unicode=True, sort_keys=False)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _text(source: dict[str, Any], *keys: str, default: str = "") -> str:
    for key in keys:
        value = source.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return default


def pipeline_file_version(path: Path) -> dict[str, int] | None:
    if not path.exists():
        return None
    stat = path.stat()
    return {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size}


def _expected_version(raw: Any) -> dict[str, int] | None:
    raw = _as_dict(raw)
    if not raw:
        return None
    try:
        return {"mtime_ns": int(raw.get("mtime_ns", -1)), "size": int(raw.get("size", -1))}
    except (TypeError, ValueError):
        return {"mtime_ns": -1, "size": -1}


def _check_expected_version(path: Path, expected_version: Any) -> None:
    expected = _expected_version(expected_version)
    if expected is None:
        return
    current = pipeline_file_version(path)
    if current != expected:
        raise ValueError(
            json.dumps(
                {
                    "status": "FAIL",
                    "code": "asr_config_conflict",
                    "message": "ASR config changed on disk",
                    "hint_zh": "ASR 配置文件已被其它窗口或进程修改，请刷新后重试。",
                    "details": {"expected": expected, "current": current},
                },
                ensure_ascii=False,
            )
        )


def _kind_from_draft(draft: dict[str, Any]) -> str:
    kind = _text(draft, "kind", default="remote").lower()
    if kind in ASR_PROVIDER_DEFAULTS:
        return kind
    return "remote"


def _draft_to_asr_row(draft: dict[str, Any]) -> dict[str, Any]:
    draft = dict(draft)
    kind = _kind_from_draft(draft)
    defaults = ASR_PROVIDER_DEFAULTS[kind]
    protocol = _text(draft, "protocol", default=str(defaults["protocol"])).lower()
    name = _text(draft, "name", default=str(defaults["name"]))
    model = _text(
        draft,
        "model",
        default=(
            OPENROUTER_ASR_DEFAULT_MODEL
            if protocol == "openrouter_stt"
            else str(defaults["model"])
        ),
    )

    row: dict[str, Any] = {
        "name": name,
        "kind": kind,
        "protocol": protocol,
        "model": model,
    }

    if kind in {"local_server", "remote"}:
        row["base_url"] = _text(
            draft,
            "base_url",
            "baseUrl",
            default=str(defaults.get("base_url", "https://api.openai.com/v1")),
        ).rstrip("/")
        row["endpoint"] = _text(draft, "endpoint", default="/v1/audio/transcriptions")

    auth = _as_dict(draft.get("auth"))
    if kind == "remote":
        row["auth"] = {
            "type": "bearer",
            "env_key": _text(auth, "env_key", "envKey", default=_text(draft, "env_key", "envKey", default="OPENAI_API_KEY")),
            "credential_id": _text(
                auth,
                "credential_id",
                "credentialId",
                default=_text(draft, "credential_id", "credentialId", default=name),
            ),
        }
    else:
        row["auth"] = {"type": "none"}

    if kind in {"local_inprocess", "local_worker"}:
        local = dict(_as_dict(draft.get("local")))
        local["model_size"] = _text(local, "model_size", "modelSize", default=model)
        device = _text(draft, "device", default=_text(local, "device"))
        if device:
            local["device"] = device
        compute_type = _text(draft, "compute_type", "computeType", default=_text(local, "compute_type", "computeType"))
        if compute_type:
            local["compute_type"] = compute_type
        row["local"] = local
    if kind == "local_worker":
        runtime = dict(_as_dict(draft.get("runtime")))
        runtime_source = _text(runtime, "source", default="managed")
        runtime["source"] = runtime_source
        runtime_id = _text(
            runtime,
            "id",
            default="managed:faster-whisper" if runtime_source == "managed" else "",
        )
        if runtime_id:
            runtime["id"] = runtime_id
        else:
            runtime.pop("id", None)
        row["runtime"] = runtime
        accelerator = dict(_as_dict(draft.get("accelerator")))
        accelerator_source = _text(accelerator, "source", default="managed")
        accelerator["source"] = accelerator_source
        accelerator_id = _text(
            accelerator,
            "id",
            default="nvidia-cuda12" if accelerator_source == "managed" else "",
        )
        if accelerator_id:
            accelerator["id"] = accelerator_id
        else:
            accelerator.pop("id", None)
        row["accelerator"] = accelerator

    for key in ("execution", "chunking", "preprocessing", "request"):
        value = draft.get(key)
        if isinstance(value, dict):
            row[key] = value
    if "http2" in draft:
        row["http2"] = bool(draft["http2"])

    if protocol == "openrouter_stt":
        row["name"] = name or "openrouter_asr"
        row["base_url"] = _text(
            draft,
            "base_url",
            "baseUrl",
            default=OPENROUTER_ASR_BASE_URL,
        ).rstrip("/")
        row["endpoint"] = _text(
            draft,
            "endpoint",
            default=OPENROUTER_ASR_ENDPOINT,
        )
        row["auth"] = {
            "type": "bearer",
            "env_key": _text(
                auth,
                "env_key",
                "envKey",
                default=OPENROUTER_ASR_ENV_KEY,
            ),
            "credential_id": _text(
                auth,
                "credential_id",
                "credentialId",
                default=OPENROUTER_ASR_CREDENTIAL_ID,
            ),
        }
        # OpenRouter models are deliberately curated. Saving through the admin
        # surface reapplies the selected model profile so settings from one
        # model cannot leak into another model with a different response shape.
        row.update(openrouter_asr_admin_defaults(model))

    return row


def draft_to_asr_provider_config(
    draft: dict[str, Any],
    *,
    network: NetworkConfig | None = None,
) -> AsrProviderConfig:
    provider = _parse_asr_provider(_draft_to_asr_row(draft))
    provider.network = network or NetworkConfig()
    return provider


def asr_provider_to_yaml_row(config: AsrProviderConfig) -> dict[str, Any]:
    row = to_plain(config)
    row.pop("network", None)
    if config.kind in {"local_inprocess", "local_worker"}:
        row.pop("base_url", None)
        row.pop("endpoint", None)
    return row


def _engine_type_from_provider_draft(draft: dict[str, Any]) -> str:
    kind = _kind_from_draft(draft)
    protocol = _text(draft, "protocol").lower()
    if kind == "local_worker" and protocol == "faster_whisper":
        return "faster_whisper_worker"
    if kind == "local_server" and protocol == "funasr_openai":
        return "funasr_service"
    if kind == "remote" and protocol == "openrouter_stt":
        return "openrouter_asr"
    if kind == "remote" and protocol == "openai_transcriptions":
        return "openai_transcription"
    raise ValueError(f"Unsupported ASR engine draft: {kind}/{protocol}")


def _registered_model_id_for_draft(
    *,
    root_dir: Path,
    model: str,
    model_path: str,
) -> str:
    normalized_path = str(Path(model_path).expanduser().resolve()) if model_path else ""
    for row in asr_runtime_snapshot(root_dir).get("registered_models") or []:
        if not isinstance(row, dict):
            continue
        candidate_path = str(row.get("model_path") or "")
        try:
            candidate_path = str(Path(candidate_path).expanduser().resolve())
        except OSError:
            continue
        if candidate_path == normalized_path and str(row.get("model_id") or "") == model:
            return str(row.get("id") or "")
    return ""


def _draft_to_engine_row(
    draft: dict[str, Any],
    *,
    current_row: dict[str, Any],
    root_dir: Path,
) -> dict[str, Any]:
    engine_id = _text(draft, "name", "id")
    if not engine_id:
        raise ValueError("ASR engine id is required")
    engine_type = _engine_type_from_provider_draft(draft)
    model = _text(draft, "model")
    row: dict[str, Any] = {
        "id": engine_id,
        "type": engine_type,
    }
    if current_row.get("policy_overrides") is not None:
        row["policy_overrides"] = current_row["policy_overrides"]

    if engine_type == "faster_whisper_worker":
        runtime = _as_dict(draft.get("runtime"))
        current_runtime = _as_dict(current_row.get("runtime"))
        runtime_source = _text(runtime, "source", default=_text(current_runtime, "source", default="managed"))
        runtime_id = _text(runtime, "id", default=_text(current_runtime, "id", default="managed:faster-whisper"))
        row["runtime"] = {
            "source": "registered" if runtime_source in {"external", "registered"} else "managed",
            "id": runtime_id,
        }

        local = _as_dict(draft.get("local"))
        current_model = _as_dict(current_row.get("model"))
        model_source = _text(local, "model_source", "modelSource", default=_text(current_model, "source", default="managed"))
        if model_source in {"external", "registered"}:
            registration_id = _text(
                draft,
                "_model_registration_id",
                default=(
                    _text(current_model, "id")
                    if _text(current_model, "source") == "registered"
                    else ""
                ),
            )
            if not registration_id:
                registration_id = _registered_model_id_for_draft(
                    root_dir=root_dir,
                    model=model,
                    model_path=_text(local, "model_path", "modelPath"),
                )
            if not registration_id:
                raise ValueError("Registered ASR model binding is required")
            row["model"] = {"source": "registered", "id": registration_id}
        else:
            row["model"] = {"source": "managed", "id": model or "large-v3"}

        accelerator = _as_dict(draft.get("accelerator"))
        current_accelerator = _as_dict(current_row.get("accelerator"))
        accelerator_source = _text(
            accelerator,
            "source",
            default=_text(current_accelerator, "source", default="managed"),
        )
        accelerator_id = _text(
            draft,
            "_accelerator_registration_id",
            default=_text(
                accelerator,
                "id",
                default=_text(current_accelerator, "id", default="nvidia-cuda12"),
            ),
        )
        if accelerator_id:
            row["accelerator"] = {
                "source": "registered" if accelerator_source in {"external", "registered"} else "managed",
                "id": accelerator_id,
            }
        row["device"] = _text(draft, "device", default=_text(local, "device", default="auto"))
        row["compute_type"] = _text(
            draft,
            "compute_type",
            "computeType",
            default=_text(local, "compute_type", "computeType", default="auto"),
        )
        return row

    row["model"] = model or (
        OPENROUTER_ASR_DEFAULT_MODEL if engine_type == "openrouter_asr" else "sensevoice" if engine_type == "funasr_service" else "whisper-1"
    )
    current_endpoint = dict(_as_dict(current_row.get("endpoint")))
    endpoint: dict[str, Any] = dict(current_endpoint)
    base_url = _text(draft, "base_url", "baseUrl")
    path = _text(draft, "endpoint")
    if base_url:
        endpoint["base_url"] = base_url.rstrip("/")
    if path:
        endpoint["path"] = path
    auth = _as_dict(draft.get("auth"))
    if engine_type == "funasr_service":
        endpoint.pop("credential", None)
        endpoint.setdefault("scope", "loopback")
        endpoint.setdefault("proxy", "direct")
    else:
        current_credential = _as_dict(current_endpoint.get("credential"))
        endpoint["credential"] = {
            "binding_id": _text(
                current_credential,
                "binding_id",
                default=engine_id,
            ),
            "secret_ref": _text(
                auth,
                "credential_id",
                "credentialId",
                default=_text(
                    current_credential,
                    "secret_ref",
                    default=OPENROUTER_ASR_CREDENTIAL_ID if engine_type == "openrouter_asr" else engine_id,
                ),
            ),
            **(
                {"env_fallback": _text(current_credential, "env_fallback")}
                if "env_fallback" in current_credential
                else {}
            ),
        }
        endpoint.setdefault("scope", "remote")
    if endpoint:
        row["endpoint"] = endpoint
    return row


def save_asr_provider_config(
    *,
    root_dir: Path,
    provider_draft: dict[str, Any],
    api_key: str | None = None,
    expected_version: dict[str, Any] | None = None,
) -> dict[str, Any]:
    pipeline_file = root_dir / "pipeline.yaml"
    _check_expected_version(pipeline_file, expected_version)
    existing = _read_yaml(pipeline_file)
    if int(existing.get("config_schema_version") or 0) != ASR_CONFIG_SCHEMA_VERSION:
        raise ValueError(
            f"ASR settings require config_schema_version={ASR_CONFIG_SCHEMA_VERSION}"
        )
    current_rows = [row for row in _as_list(existing.get("asr_engines")) if isinstance(row, dict)]
    engine_id = _text(provider_draft, "name", "id")
    current_row = next((row for row in current_rows if str(row.get("id") or "") == engine_id), {})
    draft_row = _draft_to_engine_row(
        provider_draft,
        current_row=current_row,
        root_dir=root_dir,
    )
    resolution = resolve_asr_engine(draft_row, root_dir=root_dir)
    provider = resolution.runtime
    engine_row = asr_engine_to_yaml_row(resolution.spec, resolution.overrides)

    next_rows = [row for row in current_rows if str(row.get("id") or "") != provider.name]
    next_rows.append(engine_row)

    payload = dict(existing)
    asr = _as_dict(payload.get("asr"))
    asr.pop("provider", None)
    asr["engine"] = provider.name
    payload["asr"] = asr
    payload.pop("asr_providers", None)
    payload["asr_engines"] = next_rows

    if api_key and provider.auth.type != "none":
        write_auth_credential(provider.credential_id or provider.env_key or provider.name, api_key)
    _write_yaml(pipeline_file, payload)

    if provider.auth.type == "none":
        has_key = True
        credential_source = "not_required"
        credential_id = ""
    else:
        credential = resolve_provider_credential(
            provider,
            root_dir=root_dir,
        )
        has_key = credential.found
        credential_source = credential.source
        credential_id = credential.credential_id

    provider_payload = to_plain(provider)
    provider_payload.pop("network", None)
    return {
        "ok": True,
        "provider": provider.name,
        "engine": to_plain(resolution.spec),
        "policy": to_plain(resolution.policy),
        "asr_provider": provider_payload,
        "pipeline_file": str(pipeline_file),
        "pipeline_file_version": pipeline_file_version(pipeline_file),
        "auth_file": str(auth_file_path()),
        "credential_id": credential_id,
        "has_key": has_key,
        "credential_source": credential_source,
    }


def activate_asr_resources(
    *,
    root_dir: Path,
    providers_file: Path | None = None,
    provider_name: str = "",
    managed_model_id: str = "",
    model_registration_id: str = "",
    managed_accelerator_id: str = "",
    accelerator_registration_id: str = "",
    device: str = "",
    compute_type: str = "",
    expected_version: dict[str, Any] | None = None,
    create_if_missing: bool = False,
) -> dict[str, Any]:
    """Attach verified resources to a local worker without exposing raw YAML edits."""

    if managed_model_id and model_registration_id:
        raise ValueError("Choose either a managed model or an external model registration")
    if managed_accelerator_id and accelerator_registration_id:
        raise ValueError("Choose either a managed accelerator or an external accelerator registration")
    normalized_device = device.strip().lower()
    normalized_compute_type = compute_type.strip()
    if normalized_device and normalized_device not in {"auto", "cpu", "cuda"}:
        raise ValueError(f"Unsupported ASR device: {normalized_device}")
    if normalized_device in {"auto", "cpu"} and not normalized_compute_type:
        normalized_compute_type = "auto"
    if normalized_device == "cpu" and normalized_compute_type.lower() in {
        "float16",
        "int8_float16",
        "bfloat16",
        "int8_bfloat16",
    }:
        raise ValueError(
            f"ASR compute type is not compatible with CPU: {normalized_compute_type}"
        )
    if not any(
        (
            managed_model_id,
            model_registration_id,
            managed_accelerator_id,
            accelerator_registration_id,
            normalized_device,
            normalized_compute_type,
        )
    ):
        raise ValueError("At least one resource or local worker setting is required")
    config = load_app_config(root_dir=root_dir, providers_file=providers_file)
    selected_name = provider_name.strip() or config.pipeline.asr_provider
    provider = config.asr_providers.get(selected_name)
    if provider is None:
        if not create_if_missing or not selected_name:
            raise ValueError(f"ASR provider not found: {selected_name}")
        provider = draft_to_asr_provider_config(
            {
                "name": selected_name,
                "kind": "local_worker",
                "protocol": "faster_whisper",
                "model": managed_model_id or "small",
                "auth": {"type": "none"},
                "runtime": {
                    "source": "managed",
                    "id": "managed:faster-whisper",
                },
                "local": {
                    "model_source": "managed",
                    "model_size": managed_model_id or "small",
                    "managed_model_size": managed_model_id or "small",
                    "device": normalized_device or "auto",
                    "compute_type": normalized_compute_type or "auto",
                },
            },
            network=config.network,
        )
    if provider.kind != "local_worker":
        raise ValueError("ASR resources can only be attached to a local worker provider")
    catalog = load_asr_catalog()
    draft = to_plain(provider)
    draft.pop("network", None)
    draft["runtime"] = {"source": "managed", "id": "managed:faster-whisper"}
    local = dict(draft.get("local") or {})

    if managed_model_id:
        if model_catalog_entry(catalog, managed_model_id) is None:
            raise ValueError(f"Managed ASR model not found: {managed_model_id}")
        model_row = next(
            (
                item
                for item in asr_runtime_snapshot(root_dir).get("models") or []
                if isinstance(item, dict) and str(item.get("id") or "") == managed_model_id
            ),
            None,
        )
        if not isinstance(model_row, dict) or model_row.get("installed") is not True:
            raise ValueError(f"Managed ASR model is not installed: {managed_model_id}")
        draft["model"] = managed_model_id
        local.update(
            {
                "model_size": managed_model_id,
                "model_source": "managed",
                "managed_model_size": managed_model_id,
                "model_path": "",
            }
        )
    elif model_registration_id:
        model = registered_external_model(root_dir=root_dir, registration_id=model_registration_id)
        if model is None:
            raise ValueError(f"External ASR model registration is missing or stale: {model_registration_id}")
        model_id = str(model.get("model_id") or "")
        model_path = str(model.get("model_path") or "")
        draft["model"] = model_id
        draft["_model_registration_id"] = model_registration_id
        local.update(
            {
                "model_size": model_id,
                "model_source": "external",
                "external_model_id": model_id,
                "external_model_path": model_path,
                "model_path": model_path,
            }
        )
    if normalized_device:
        local["device"] = normalized_device
    if normalized_compute_type:
        local["compute_type"] = normalized_compute_type
    draft["local"] = local

    if managed_accelerator_id:
        accelerator = next(
            (
                item
                for item in catalog.get("accelerators") or []
                if isinstance(item, dict) and str(item.get("id") or "") == managed_accelerator_id
            ),
            None,
        )
        if accelerator is None:
            raise ValueError(f"Managed ASR accelerator not found: {managed_accelerator_id}")
        draft["accelerator"] = {"source": "managed", "id": managed_accelerator_id}
    elif accelerator_registration_id:
        accelerator = registered_external_accelerator(
            root_dir=root_dir,
            registration_id=accelerator_registration_id,
        )
        if accelerator is None:
            raise ValueError(
                f"External ASR accelerator registration is missing or stale: {accelerator_registration_id}"
            )
        draft["accelerator"] = {"source": "external", "id": accelerator_registration_id}
        draft["_accelerator_registration_id"] = accelerator_registration_id

    saved = save_asr_provider_config(
        root_dir=root_dir,
        provider_draft=draft,
        expected_version=expected_version,
    )
    refreshed = load_app_config(root_dir=root_dir, providers_file=providers_file)
    active = refreshed.asr_providers[selected_name]
    return {
        **saved,
        "model_source": active.local.model_source,
        "model": active.model,
        "accelerator_source": active.accelerator.source,
        "accelerator_id": active.accelerator.id,
        "device": active.local.device,
        "compute_type": active.local.compute_type,
        "readiness": asr_provider_readiness(active, root_dir=root_dir),
    }
