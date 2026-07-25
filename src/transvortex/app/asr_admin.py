from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml

from ..utils import to_plain
from .config import _parse_asr_provider, load_app_config
from .credentials import auth_file_path, resolve_credential, write_auth_credential
from .models import AsrProviderConfig, NetworkConfig
from .asr_runtime import (
    asr_provider_readiness,
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
    path.write_text(
        yaml.safe_dump(payload, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )


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


def _merge_dict(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _merge_dict(merged[key], value)
        else:
            merged[key] = value
    return merged


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
    model = _text(draft, "model", default=str(defaults["model"]))

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
    current_rows = [row for row in _as_list(existing.get("asr_providers")) if isinstance(row, dict)]
    draft_row = _draft_to_asr_row(provider_draft)
    current_row = next((row for row in current_rows if str(row.get("name") or "") == draft_row["name"]), {})
    provider = _parse_asr_provider(_merge_dict(current_row, draft_row))
    provider_row = asr_provider_to_yaml_row(provider)

    next_rows = [row for row in current_rows if str(row.get("name") or "") != provider.name]
    next_rows.append(provider_row)

    payload = dict(existing)
    asr = _as_dict(payload.get("asr"))
    asr["provider"] = provider.name
    payload["asr"] = asr
    payload["asr_providers"] = next_rows
    _write_yaml(pipeline_file, payload)

    if api_key and provider.auth.type != "none":
        write_auth_credential(provider.credential_id or provider.env_key or provider.name, api_key)

    if provider.auth.type == "none":
        has_key = True
        credential_source = "not_required"
        credential_id = ""
    else:
        credential = resolve_credential(
            env_key=provider.env_key,
            credential_id=provider.credential_id,
            provider_name=provider.name,
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
        raise ValueError(f"ASR provider not found: {selected_name}")
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
