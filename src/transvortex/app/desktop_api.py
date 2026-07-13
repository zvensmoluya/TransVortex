from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from .. import __version__
from ..artifacts.result_workspace import (
    open_task_result,
    reexport_task,
    save_task_segments,
    update_task_memory_entry,
)
from ..artifacts.catalog import TaskCatalog
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
from ..providers.model_catalog import model_catalog_payload
from ..providers.probe import probe_provider
from ..prompts.asr_admin import delete_asr_prompt_profile, save_asr_prompt_profile
from ..utils import read_json, to_plain
from .asr_admin import pipeline_file_version, save_asr_provider_config
from .config import _read_yaml, load_app_config, resolve_providers_file
from .credentials import (
    auth_file_path,
    provider_credential_id,
    read_auth_credentials,
    resolve_credential,
    resolve_provider_credential,
    write_auth_credential,
)
from .desktop_requests import normalize_input_type, resume_request_from_payload, run_request_from_payload
from .doctor import doctor_report


TERMINAL_STATUSES = {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}
PROTOCOL_VERSION = 1
SERVICE_NAME = "transvortex.app_service"
SERVICE_CAPABILITIES = [
    "desktop_snapshot",
    "runtime",
    "runtime_pump",
    "derived_translation",
    "provider_admin",
    "asr_provider_admin",
    "result_workspace",
    "event_cursor",
]


class DesktopApiError(RuntimeError):
    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


class DesktopApi:
    def __init__(
        self,
        *,
        root_dir: Path,
        providers_file: Path | None = None,
        pump_status: Callable[[], dict[str, Any]] | None = None,
        task_ready_callback: Callable[[str], None] | None = None,
        shutdown_callback: Callable[[], None] | None = None,
    ) -> None:
        self.root_dir = root_dir
        self.providers_file = providers_file
        self._pump_status = pump_status
        self._task_ready_callback = task_ready_callback
        self._shutdown_callback = shutdown_callback
        self.shutdown_requested = False

    def dispatch(self, method: str, params: dict[str, Any] | None = None) -> Any:
        params = params or {}
        handlers = {
            "service.info": self.service_info,
            "service.health": self.service_health,
            "service.shutdown": self.service_shutdown,
            "desktop.ping": self.ping,
            "desktop.snapshot": self.desktop_snapshot,
            "catalog.status": self.catalog_status,
            "catalog.rebuild": self.catalog_rebuild,
            "config.get": self.config_get,
            "tasks.list": self.tasks_list,
            "tasks.events": self.tasks_events,
            "runtime.snapshot": self.runtime_snapshot,
            "runtime.reconcile": self.runtime_reconcile,
            "runtime.submitRun": self.runtime_submit_run,
            "runtime.submitResume": self.runtime_submit_resume,
            "runtime.retranslate": self.runtime_retranslate,
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
            "asr.provider.save": self.asr_provider_save,
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

    def service_info(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {
            "service": SERVICE_NAME,
            "protocol_version": PROTOCOL_VERSION,
            "app_version": __version__,
            "capabilities": SERVICE_CAPABILITIES,
        }

    def service_health(self, _params: dict[str, Any]) -> dict[str, Any]:
        pump = self._pump_status() if self._pump_status is not None else {"enabled": False}
        try:
            active = self._runtime().active_payload_light()
            return {
                "service": SERVICE_NAME,
                "status": "healthy" if not pump.get("last_error") else "degraded",
                "runtime": {
                    "active": active,
                },
                "pump": pump,
            }
        except Exception as exc:  # noqa: BLE001 - health must return structured state
            return {
                "service": SERVICE_NAME,
                "status": "degraded",
                "runtime": {},
                "pump": pump,
                "error": str(exc),
            }

    def service_shutdown(self, _params: dict[str, Any]) -> dict[str, Any]:
        self.shutdown_requested = True
        if self._shutdown_callback is not None:
            self._shutdown_callback()
        return {"ok": True, "shutdown": "requested"}

    def ping(self, _params: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "service": SERVICE_NAME}

    def config_get(self, _params: dict[str, Any]) -> dict[str, Any]:
        return config_payload(self.root_dir, self.providers_file)

    def desktop_snapshot(self, _params: dict[str, Any]) -> dict[str, Any]:
        config_error = ""
        try:
            config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
            artifacts_dir = config.pipeline.artifacts_dir
            config_view = config_payload(self.root_dir, self.providers_file, config=config)
        except Exception as exc:  # noqa: BLE001 - desktop snapshot should still expose recoverable config state
            config = None
            config_error = str(exc)
            artifacts_dir = _fallback_artifacts_dir(self.root_dir)
            config_view = config_payload(self.root_dir, self.providers_file, error=config_error)
        runtime = TaskRuntime(artifacts_dir)
        runtime.reconcile()
        return {
            "config": config_view,
            "tasks": _catalog_task_payloads(artifacts_dir),
            "runtime": runtime.snapshot(),
            "environment": doctor_report(root_dir=self.root_dir, providers_file=self.providers_file),
            "config_error": config_error,
        }

    def catalog_status(self, _params: dict[str, Any]) -> dict[str, Any]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        return TaskCatalog(config.pipeline.artifacts_dir).status()

    def catalog_rebuild(self, _params: dict[str, Any]) -> dict[str, Any]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        return TaskCatalog(config.pipeline.artifacts_dir).rebuild()

    def tasks_list(self, _params: dict[str, Any]) -> list[dict[str, Any]]:
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        return _catalog_task_payloads(config.pipeline.artifacts_dir)

    def tasks_events(self, params: dict[str, Any]) -> dict[str, Any]:
        task_id = _required_text(params, "task_id", "taskId")
        config = load_app_config(root_dir=self.root_dir, providers_file=self.providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        cursor = _optional_int(params, "cursor", default=0)
        limit = _optional_int(params, "limit", default=500)
        return TaskStore(config.pipeline.artifacts_dir).read_events_page(task_id, cursor=cursor, limit=limit)

    def runtime_snapshot(self, _params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().snapshot()

    def runtime_reconcile(self, _params: dict[str, Any]) -> dict[str, Any]:
        return self._runtime().reconcile()

    def runtime_submit_run(self, params: dict[str, Any]) -> dict[str, Any]:
        request = run_request_from_payload(_request_param(params))
        payload = self._runtime().submit_run(root_dir=self.root_dir, request=request, providers_file=self.providers_file)
        self._notify_task_ready(str(payload.get("task_id") or ""))
        return payload

    def runtime_submit_resume(self, params: dict[str, Any]) -> dict[str, Any]:
        request = resume_request_from_payload(_request_param(params))
        payload = self._runtime().submit_resume(root_dir=self.root_dir, request=request, providers_file=self.providers_file)
        self._notify_task_ready(str(payload.get("task_id") or ""))
        return payload

    def runtime_retranslate(self, params: dict[str, Any]) -> dict[str, Any]:
        routing = params.get("routing")
        overrides = params.get("overrides")
        if routing is not None and not isinstance(routing, dict):
            raise DesktopApiError("invalid_request", "routing must be an object")
        if overrides is not None and not isinstance(overrides, dict):
            raise DesktopApiError("invalid_request", "overrides must be an object")
        payload = self._runtime().submit_retranslate(
            root_dir=self.root_dir,
            parent_task_id=_required_text(params, "task_id", "taskId"),
            target_lang=_optional_text(params, "target_lang", "targetLang"),
            bilingual=_optional_bool(params, "bilingual"),
            output=_optional_text(params, "output") or "",
            provider=_optional_text(params, "provider") or "",
            model=_optional_text(params, "model") or "",
            routing=routing,
            overrides=overrides,
            providers_file=self.providers_file,
        )
        self._notify_task_ready(str(payload.get("task_id") or ""))
        return payload

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
            task = store.request_cancel(task_id, force_after_grace=_optional_float(params, "force_after_grace", "forceAfterGrace"))
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

    def asr_provider_save(self, params: dict[str, Any]) -> dict[str, Any]:
        return save_asr_provider_config(
            root_dir=self.root_dir,
            provider_draft=_dict_param(params, "provider_draft", "providerDraft"),
            api_key=_optional_text(params, "api_key", "apiKey"),
            expected_version=_optional_dict(params, "expected_version", "expectedVersion"),
        )

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
            output_dir=_optional_text(params, "output_dir", "outputDir"),
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

    def _notify_task_ready(self, task_id: str) -> None:
        if self._task_ready_callback is None or not task_id:
            return
        self._task_ready_callback(task_id)


def config_payload(
    root: Path,
    providers_file: Path | None,
    *,
    config: Any | None = None,
    error: str = "",
) -> dict[str, Any]:
    resolved_providers_file = resolve_providers_file(root, providers_file)
    if config is None:
        try:
            config = load_app_config(root_dir=root, providers_file=providers_file)
        except Exception as exc:  # noqa: BLE001 - settings UI needs partial config to guide repair
            return _partial_config_payload(root, resolved_providers_file, str(exc) if not error else error)
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
                "model_configs": to_plain(provider.model_configs),
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
        "pipeline_file_version": pipeline_file_version(root / "pipeline.yaml"),
        "artifacts_dir": str(config.pipeline.artifacts_dir),
        "pipeline": to_plain(config.pipeline),
        "routing": to_plain(config.routing),
        "active_routing_profile": config.active_routing_profile,
        "routing_profiles": to_plain(config.routing_profiles),
        "routing_profile_next_seq": int(getattr(config, "routing_profile_next_seq", 1) or 1),
        "protocol_templates": protocol_templates_payload(),
        "provider_presets": provider_presets_payload(),
        "model_catalog": model_catalog_payload(),
        "custom_adapter_template": custom_adapter_template_payload(),
        "provider_templates": provider_templates_payload(),
        "providers": sorted(providers, key=lambda row: row["name"]),
        "asr_providers": asr_providers,
        "config_error": error,
    }


def _fallback_artifacts_dir(root: Path) -> Path:
    raw = _read_yaml(root / "pipeline.yaml")
    artifacts = raw.get("artifacts_dir", "artifacts") if isinstance(raw, dict) else "artifacts"
    path = Path(str(artifacts or "artifacts"))
    return path if path.is_absolute() else root / path


def _partial_config_payload(root: Path, providers_file: Path, error: str) -> dict[str, Any]:
    providers_raw = _read_yaml(providers_file)
    pipeline_raw = _read_yaml(root / "pipeline.yaml")
    if not isinstance(providers_raw, dict):
        providers_raw = {}
    if not isinstance(pipeline_raw, dict):
        pipeline_raw = {}

    providers = []
    for row in providers_raw.get("providers") or []:
        if not isinstance(row, dict):
            continue
        name = str(row.get("name") or "").strip()
        if not name:
            continue
        env_key = str(row.get("env_key") or "").strip()
        credential_id = str(row.get("credential_id") or name).strip()
        credential = resolve_credential(
            env_key=env_key,
            credential_id=credential_id,
            provider_name=name,
            root_dir=root,
        )
        providers.append(
            {
                "name": name,
                "api_type": str(row.get("api_type") or ""),
                "compat_mode": str(row.get("compat_mode") or ""),
                "base_url": str(row.get("base_url") or ""),
                "env_key": env_key,
                "credential_id": credential_id,
                "credential_source": credential.source,
                "has_key": credential.found,
                "models": [str(item) for item in (row.get("models") or [])],
            }
        )

    asr_raw = pipeline_raw.get("asr") if isinstance(pipeline_raw.get("asr"), dict) else {}
    asr_provider_name = str(asr_raw.get("provider") or "faster_whisper_large_v3")
    asr_providers = {}
    for row in pipeline_raw.get("asr_providers") or []:
        if not isinstance(row, dict):
            continue
        name = str(row.get("name") or "").strip()
        if not name:
            continue
        auth = row.get("auth") if isinstance(row.get("auth"), dict) else {}
        auth_type = str(auth.get("type") or "bearer")
        env_key = str(auth.get("env_key") or row.get("env_key") or "TVX_MODEL_API_KEY")
        credential_id = str(auth.get("credential_id") or row.get("credential_id") or name)
        if auth_type == "none":
            credential_source = "not_required"
            has_key = True
        else:
            credential = resolve_credential(
                env_key=env_key,
                credential_id=credential_id,
                provider_name=name,
                root_dir=root,
            )
            credential_source = credential.source
            has_key = credential.found
        asr_providers[name] = {
            **row,
            "credential_source": credential_source,
            "has_key": has_key,
        }

    return {
        "root_dir": str(root),
        "auth_file": str(auth_file_path()),
        "providers_file": str(providers_file),
        "providers_file_version": providers_file_version(providers_file),
        "pipeline_file_version": pipeline_file_version(root / "pipeline.yaml"),
        "artifacts_dir": str(_fallback_artifacts_dir(root)),
        "pipeline": {
            "artifacts_dir": str(_fallback_artifacts_dir(root)),
            "asr_provider": asr_provider_name,
        },
        "routing": providers_raw.get("routing") if isinstance(providers_raw.get("routing"), dict) else {},
        "active_routing_profile": "",
        "routing_profiles": [],
        "routing_profile_next_seq": 1,
        "protocol_templates": protocol_templates_payload(),
        "provider_presets": provider_presets_payload(),
        "model_catalog": model_catalog_payload(),
        "custom_adapter_template": custom_adapter_template_payload(),
        "provider_templates": provider_templates_payload(),
        "providers": sorted(providers, key=lambda row: row["name"]),
        "asr_providers": asr_providers,
        "config_error": error,
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
    payload["input_type"] = _task_input_type(task)
    if artifacts_dir is not None:
        payload["task_dir"] = str(artifacts_dir / task.task_id)
    return payload


def _task_input_type(task: Any) -> str:
    settings = _task_settings(task)
    raw = str(settings.get("input_type") or "").strip()
    if raw:
        return normalize_input_type(raw)
    return ""


def _task_settings(task: Any) -> dict[str, Any]:
    settings = getattr(task, "settings", {})
    return settings if isinstance(settings, dict) else {}


def _catalog_task_payloads(artifacts_dir: Path) -> list[dict[str, Any]]:
    catalog = TaskCatalog(artifacts_dir)
    store = TaskStore(artifacts_dir)
    try:
        task_ids = catalog.list_task_ids(order="updated_desc")
    except Exception:
        catalog.rebuild()
        task_ids = catalog.list_task_ids(order="updated_desc")
    if not task_ids and _has_task_dirs(artifacts_dir):
        catalog.rebuild()
        task_ids = catalog.list_task_ids(order="updated_desc")
    payloads: list[dict[str, Any]] = []
    missing = False
    for task_id in task_ids:
        try:
            payloads.append(task_payload(store.load_task(task_id), artifacts_dir))
        except Exception:
            missing = True
    if missing:
        catalog.rebuild()
    return payloads


def _has_task_dirs(artifacts_dir: Path) -> bool:
    if not artifacts_dir.exists():
        return False
    try:
        return any(child.is_dir() and (child / "task.json").exists() for child in artifacts_dir.iterdir())
    except Exception:
        return False


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


def _optional_int(params: dict[str, Any], *keys: str, default: int) -> int:
    for key in keys:
        value = params.get(key)
        if value is None:
            continue
        try:
            return int(value)
        except Exception:
            raise DesktopApiError("invalid_request", f"{key} must be an integer") from None
    return default


def _optional_float(params: dict[str, Any], *keys: str) -> float | None:
    for key in keys:
        value = params.get(key)
        if value is None:
            continue
        try:
            return float(value)
        except Exception:
            raise DesktopApiError("invalid_request", f"{key} must be a number") from None
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
