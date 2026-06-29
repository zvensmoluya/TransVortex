from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from ..artifacts.result_workspace import (
    open_task_result,
    reexport_task,
    save_task_segments,
    update_task_memory_entry,
)
from ..artifacts.runtime import TaskRuntime
from ..artifacts.task_store import TaskStore
from ..core.orchestrator import task_status_json
from ..memory.exporter import MemoryPresetExportOptions, export_runtime_memory_to_preset
from ..providers.admin import (
    custom_adapter_template_payload,
    delete_provider_config,
    fetch_provider_models,
    protocol_templates_payload,
    provider_presets_payload,
    provider_templates_payload,
    providers_file_version,
    run_provider_connection_test,
    save_provider_config,
    save_provider_routing,
)
from ..providers.probe import probe_provider
from ..prompts.asr_admin import delete_asr_prompt_profile, save_asr_prompt_profile
from ..utils import read_json, to_plain
from .config import load_app_config, resolve_providers_file
from .credentials import (
    auth_file_path,
    provider_credential_id,
    read_auth_credentials,
    resolve_credential,
    resolve_provider_credential,
    write_auth_credential,
)
from .desktop_requests import resume_request_from_payload, run_request_from_payload
from .doctor import doctor_report


TERMINAL_STATUSES = {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}


class DesktopApiError(RuntimeError):
    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


class DesktopApi:
    def __init__(self, *, root_dir: Path, providers_file: Path | None = None) -> None:
        self.root_dir = root_dir
        self.providers_file = providers_file

    def dispatch(self, method: str, params: dict[str, Any] | None = None) -> Any:
        params = params or {}
        handlers = {
            "desktop.ping": self.ping,
            "desktop.snapshot": self.desktop_snapshot,
            "config.get": self.config_get,
            "tasks.list": self.tasks_list,
            "tasks.events": self.tasks_events,
            "runtime.snapshot": self.runtime_snapshot,
            "runtime.reconcile": self.runtime_reconcile,
            "runtime.submitRun": self.runtime_submit_run,
            "runtime.submitResume": self.runtime_submit_resume,
            "runtime.acquireNext": self.runtime_acquire_next,
            "runtime.releaseActive": self.runtime_release_active,
            "runtime.cancel": self.runtime_cancel,
            "auth.list": self.auth_list,
            "auth.set": self.auth_set,
            "provider.probe": self.provider_probe,
            "provider.save": self.provider_save,
            "provider.delete": self.provider_delete,
            "provider.models": self.provider_models,
            "provider.test": self.provider_test,
            "provider.routing.save": self.provider_routing_save,
            "prompt.asr.save": self.prompt_asr_save,
            "prompt.asr.delete": self.prompt_asr_delete,
            "result.open": self.result_open,
            "result.segments.save": self.result_segments_save,
            "result.reexport": self.result_reexport,
            "result.memoryEntry.update": self.result_memory_entry_update,
            "memory.exportPreset": self.memory_export_preset,
        }
        handler = handlers.get(method)
        if handler is None:
            raise DesktopApiError("method_not_found", f"Unknown desktop method: {method}", details={"method": method})
        return handler(params)

    def ping(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "service": "transvortex.app_service"}

    def config_get(self, _params: dict[str, Any]) -> dict[str, Any]:
        return config_payload(self.root_dir, self.providers_file)

    def desktop_snapshot(self, _params: dict[str, Any]) -> dict[str, Any]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        runtime = TaskRuntime(config.pipeline.artifacts_dir)
        runtime.reconcile()
        store = TaskStore(config.pipeline.artifacts_dir)
        return {
            "config": config_payload(self.root_dir, self.providers_file),
            "tasks": [task_payload(task, config.pipeline.artifacts_dir) for task in store.list_tasks()],
            "runtime": runtime.snapshot(),
            "environment": doctor_report(root_dir=self.root_dir, providers_file=self.providers_file),
        }

    def tasks_list(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        store = TaskStore(config.pipeline.artifacts_dir)
        return [task_payload(task, config.pipeline.artifacts_dir) for task in store.list_tasks()]

    def tasks_events(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        task_id = _required_text(params, "task_id", "taskId")
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        return TaskStore(config.pipeline.artifacts_dir).read_events(task_id)

    def runtime_snapshot(self, _params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().snapshot()

    def runtime_reconcile(self, _params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().reconcile()

    def runtime_submit_run(self, params: dict[str, Any]) -> dict[str, Any]:
        request = run_request_from_payload(_request_param(params))
        return self._runtime().submit_run(root_dir=self.root_dir, request=request, providers_file=self.providers_file)

    def runtime_submit_resume(self, params: dict[str, Any]) -> dict[str, Any]:
        request = resume_request_from_payload(_request_param(params))
        return self._runtime().submit_resume(root_dir=self.root_dir, request=request, providers_file=self.providers_file)

    def runtime_acquire_next(self, _params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().acquire_next(root_dir=self.root_dir, providers_file=self.providers_file)

    def runtime_release_active(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().release_active(
            _required_text(params, "task_id", "taskId"),
            state=str(params.get("state") or "interrupted"),
            reason=str(params.get("reason") or "worker_launch_failed"),
        )

    def runtime_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        task_id = _required_text(params, "task_id", "taskId")
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        runtime = TaskRuntime(config.pipeline.artifacts_dir)
        if params.get("force"):
            task = runtime.force_cancel(task_id, reason=str(params.get("reason") or "force_cancel"))
        else:
            task = store.request_cancel(task_id)
            grace = params.get("force_after_grace")
            if grace is not None:
                deadline = time.time() + max(0.0, float(grace))
                while time.time() < deadline:
                    latest = store.load_task(task_id)
                    if latest.status in TERMINAL_STATUSES:
                        return task_status_json(latest, store=store)
                    time.sleep(0.2)
                latest = store.load_task(task_id)
                if latest.status not in TERMINAL_STATUSES:
                    task = runtime.force_cancel(task_id, reason=str(params.get("reason") or "force_after_grace"))
        return task_status_json(task, store=store)

    def auth_list(self, _params: dict[str, Any]) -> dict[str, Any]:
        return auth_list_payload()

    def auth_set(self, params: dict[str, Any]) -> dict[str, Any]:
        credential_id = _required_text(params, "credential_id", "credentialId")
        api_key = _required_text(params, "api_key", "apiKey", "value")
        path = write_auth_credential(credential_id, api_key)
        return {"ok": True, "credential_id": credential_id, "auth_file": str(path)}

    def provider_probe(self, params: dict[str, Any]) -> dict[str, Any]:
        return probe_provider(
            root_dir=self.root_dir,
            providers_file=self.providers_file,
            provider_name=_optional_text(params, "provider", "provider_name", "providerName"),
            model=_optional_text(params, "model"),
            source_lang=str(params.get("source_lang") or params.get("sourceLang") or "en"),
            target_lang=str(params.get("target_lang") or params.get("targetLang") or "zh-CN"),
        )

    def provider_save(self, params: dict[str, Any]) -> dict[str, Any]:
        return save_provider_config(
            root_dir=self.root_dir,
            provider_draft=_dict_param(params, "provider_draft", "providerDraft"),
            api_key=_optional_text(params, "api_key", "apiKey"),
            expected_version=_optional_dict(params, "expected_version", "expectedVersion"),
        )

    def provider_delete(self, params: dict[str, Any]) -> dict[str, Any]:
        return delete_provider_config(
            root_dir=self.root_dir,
            name=_required_text(params, "name"),
            expected_version=_optional_dict(params, "expected_version", "expectedVersion"),
        )

    def provider_models(self, params: dict[str, Any]) -> dict[str, Any]:
        return fetch_provider_models(
            provider_draft=_dict_param(params, "provider_draft", "providerDraft"),
            api_key=_optional_text(params, "api_key", "apiKey"),
            root_dir=self.root_dir,
        )

    def provider_test(self, params: dict[str, Any]) -> dict[str, Any]:
        return run_provider_connection_test(
            provider_draft=_dict_param(params, "provider_draft", "providerDraft"),
            model=_required_text(params, "model"),
            api_key=_optional_text(params, "api_key", "apiKey"),
            root_dir=self.root_dir,
        )

    def provider_routing_save(self, params: dict[str, Any]) -> dict[str, Any]:
        routing = params.get("routing", params)
        if not isinstance(routing, dict):
            raise DesktopApiError("invalid_request", "routing must be an object")
        return save_provider_routing(root_dir=self.root_dir, routing=routing)

    def prompt_asr_save(self, params: dict[str, Any]) -> dict[str, Any]:
        return save_asr_prompt_profile(root_dir=self.root_dir, profile=_dict_param(params, "profile"))

    def prompt_asr_delete(self, params: dict[str, Any]) -> dict[str, Any]:
        return delete_asr_prompt_profile(root_dir=self.root_dir, profile_id=_required_text(params, "id", "profile_id", "profileId"))

    def result_open(self, params: dict[str, Any]) -> dict[str, Any]:
        return open_task_result(root_dir=self.root_dir, task_id=_required_text(params, "task_id", "taskId"))

    def result_segments_save(self, params: dict[str, Any]) -> dict[str, Any]:
        segments = params.get("segments")
        if not isinstance(segments, list):
            raise DesktopApiError("invalid_request", "segments must be a list")
        return save_task_segments(root_dir=self.root_dir, task_id=_required_text(params, "task_id", "taskId"), segments_payload=segments)

    def result_reexport(self, params: dict[str, Any]) -> dict[str, Any]:
        return reexport_task(
            root_dir=self.root_dir,
            task_id=_required_text(params, "task_id", "taskId"),
            output_format=_required_text(params, "output_format", "outputFormat"),
            bilingual=_optional_bool(params, "bilingual"),
            subtitle_bilingual_order=_optional_text(params, "subtitle_bilingual_order", "subtitleBilingualOrder"),
            subtitle_prefer_single_line=_optional_bool(params, "subtitle_prefer_single_line", "subtitlePreferSingleLine"),
        )

    def result_memory_entry_update(self, params: dict[str, Any]) -> dict[str, Any]:
        return update_task_memory_entry(
            root_dir=self.root_dir,
            task_id=_required_text(params, "task_id", "taskId"),
            entry_id=_required_text(params, "entry_id", "entryId"),
            status=_required_text(params, "status"),
        )

    def memory_export_preset(self, params: dict[str, Any]) -> dict[str, Any]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        return export_runtime_memory_to_preset(
            root_dir=self.root_dir,
            artifacts_dir=config.pipeline.artifacts_dir,
            options=MemoryPresetExportOptions(
                task_id=_required_text(params, "task_id", "taskId"),
                preset_id=_required_text(params, "preset_id", "presetId"),
                name=str(params.get("name") or ""),
                description=str(params.get("description") or ""),
                default_status=str(params.get("default_status") or params.get("defaultStatus") or "confirmed"),
                overwrite=bool(params.get("overwrite", False)),
                dry_run=bool(params.get("dry_run", params.get("dryRun", False))),
            ),
        )

    def _runtime(self) -> TaskRuntime:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        return TaskRuntime(config.pipeline.artifacts_dir)


def config_payload(root: Path, providers_file: Path | None) -> dict[str, Any]:
    resolved_providers_file = resolve_providers_file(root, providers_file)
    config = load_app_config(root_dir=root, providers_file=providers_file)
    providers = []
    for provider in config.providers.values():
        credential = resolve_provider_credential(provider, root_dir=root)
        providers.append(
            {
                "name": provider.name,
                "api_type": provider.api_type,
                "compat_mode": provider.compat_mode,
                "base_url": provider.base_url,
                "env_key": provider.env_key,
                "credential_id": provider_credential_id(provider),
                "credential_source": credential.source,
                "has_key": credential.found,
                "models": provider.models,
                "auth": to_plain(provider.auth),
                "endpoint": to_plain(provider.endpoint),
                "request_mapping": provider.mapping.request,
                "response_mapping": provider.mapping.response,
                "extra_headers": provider.extra_headers,
                "model_list": to_plain(provider.model_list),
                "limits": to_plain(provider.limits),
                "capabilities": to_plain(provider.capabilities),
            }
        )
    asr_providers = {}
    for name, provider in sorted(config.asr_providers.items(), key=lambda item: item[0]):
        if provider.auth.type == "none":
            credential_source = "not_required"
            has_key = True
        else:
            credential = resolve_credential(
                env_key=provider.env_key,
                credential_id=provider.credential_id,
                provider_name=provider.name,
                root_dir=root,
            )
            credential_source = credential.source
            has_key = credential.found
        asr_providers[name] = {
            **to_plain(provider),
            "credential_source": credential_source,
            "has_key": has_key,
        }
    return {
        "root_dir": str(root),
        "auth_file": str(auth_file_path()),
        "providers_file": str(resolved_providers_file),
        "providers_file_version": providers_file_version(resolved_providers_file),
        "artifacts_dir": str(config.pipeline.artifacts_dir),
        "pipeline": to_plain(config.pipeline),
        "routing": to_plain(config.routing),
        "active_routing_profile": config.active_routing_profile,
        "routing_profiles": to_plain(config.routing_profiles),
        "routing_profile_next_seq": int(getattr(config, "routing_profile_next_seq", 1) or 1),
        "protocol_templates": protocol_templates_payload(),
        "provider_presets": provider_presets_payload(),
        "custom_adapter_template": custom_adapter_template_payload(),
        "provider_templates": provider_templates_payload(),
        "providers": sorted(providers, key=lambda row: row["name"]),
        "asr_providers": asr_providers,
    }


def auth_status_payload(root: Path, providers_file: Path | None) -> dict[str, Any]:
    config = load_app_config(root_dir=root, providers_file=providers_file)
    rows = []
    for provider in sorted(config.providers.values(), key=lambda item: item.name):
        credential = resolve_provider_credential(provider, root_dir=root)
        rows.append(
            {
                "provider": provider.name,
                "env_key": provider.env_key,
                "credential_id": provider_credential_id(provider),
                "has_key": credential.found,
                "source": credential.source,
            }
        )
    return {"auth_file": str(auth_file_path()), "providers": rows}


def auth_list_payload() -> dict[str, Any]:
    credentials = read_auth_credentials()
    return {
        "auth_file": str(auth_file_path()),
        "credentials": [{"credential_id": key, "has_key": True} for key in sorted(credentials)],
    }


def task_payload(task: Any, artifacts_dir: Path | None = None) -> dict[str, Any]:
    store = TaskStore(artifacts_dir) if artifacts_dir is not None else None
    payload = task_status_json(task, store=store)
    if artifacts_dir is not None:
        payload["task_dir"] = str(artifacts_dir / task.task_id)
    return payload


def _request_param(params: dict[str, Any]) -> dict[str, Any]:
    request = params.get("request", params)
    if not isinstance(request, dict):
        raise DesktopApiError("invalid_request", "request must be an object")
    return request


def _required_text(params: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = params.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise DesktopApiError("invalid_request", f"{keys[0]} is required")


def _optional_text(params: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = params.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _optional_bool(params: dict[str, Any], *keys: str) -> bool | None:
    for key in keys:
        value = params.get(key)
        if isinstance(value, bool):
            return value
    return None


def _dict_param(params: dict[str, Any], *keys: str) -> dict[str, Any]:
    for key in keys:
        value = params.get(key)
        if isinstance(value, dict):
            return value
    raise DesktopApiError("invalid_request", f"{keys[0]} must be an object")


def _optional_dict(params: dict[str, Any], *keys: str) -> dict[str, Any] | None:
    for key in keys:
        value = params.get(key)
        if isinstance(value, dict):
            return value
    return None
