from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

from ..utils import read_json, utc_now_iso, write_json
from .asr_runtime import (
    WHISPER_HOST_PROTOCOL_VERSION,
    asr_provider_readiness,
    load_asr_catalog,
    model_catalog_entry,
    probe_python_environment,
    resolve_whisper_runtime,
    save_external_environment,
)
from .config import load_app_config


E2E_MARKER_NAME = "app_e2e_environment.json"
DEFAULT_ASR_PROVIDER = "faster_whisper_large_v3"


def resolve_python_executable(value: str) -> Path:
    candidate = value.strip()
    if not candidate:
        candidate = shutil.which("python") or ""
    elif not Path(candidate).expanduser().is_file():
        candidate = shutil.which(candidate) or candidate
    if not candidate:
        raise FileNotFoundError("Python executable was not found. Pass --python-executable.")
    resolved = Path(candidate).expanduser().resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"Python executable was not found: {resolved}")
    return resolved


def resolve_model_path(
    model_id: str,
    explicit_path: str = "",
    *,
    environment: dict[str, str] | None = None,
    home: Path | None = None,
) -> Path:
    if explicit_path.strip():
        resolved = Path(explicit_path).expanduser().resolve()
        if not resolved.is_dir():
            raise FileNotFoundError(f"Whisper model directory was not found: {resolved}")
        validate_model_path_identity(model_id, resolved)
        return resolved

    catalog = load_asr_catalog()
    model = model_catalog_entry(catalog, model_id)
    if model is None:
        raise ValueError(f"Unsupported Whisper model id: {model_id}")
    repository = str(model.get("repository") or "").strip()
    revision = str(model.get("revision") or "").strip()
    if not repository or not revision:
        raise RuntimeError(f"Whisper model catalog entry is incomplete: {model_id}")

    env = environment or dict(os.environ)
    cache_roots: list[Path] = []
    explicit_hub = env.get("HF_HUB_CACHE", "").strip()
    if explicit_hub:
        cache_roots.append(Path(explicit_hub).expanduser())
    hub_cache = env.get("HUGGINGFACE_HUB_CACHE", "").strip()
    if hub_cache:
        cache_roots.append(Path(hub_cache).expanduser())
    hf_home = env.get("HF_HOME", "").strip()
    if hf_home:
        cache_roots.append(Path(hf_home).expanduser() / "hub")
    cache_roots.append((home or Path.home()) / ".cache" / "huggingface" / "hub")

    repository_dir = f"models--{repository.replace('/', '--')}"
    seen: set[str] = set()
    checked: list[str] = []
    for root in cache_roots:
        candidate = (root / repository_dir / "snapshots" / revision).resolve()
        key = os.path.normcase(str(candidate))
        if key in seen:
            continue
        seen.add(key)
        checked.append(str(candidate))
        if candidate.is_dir():
            validate_model_path_identity(model_id, candidate)
            return candidate
    joined = "\n- ".join(checked)
    raise FileNotFoundError(
        f"Pinned Whisper model {model_id} was not found in the Hugging Face cache. "
        f"Pass --model-path. Checked:\n- {joined}"
    )


def validate_model_path_identity(model_id: str, model_path: Path) -> dict[str, str]:
    catalog = load_asr_catalog()
    model = model_catalog_entry(catalog, model_id)
    if model is None:
        raise ValueError(f"Unsupported Whisper model id: {model_id}")
    expected_hash = next(
        (
            str(item.get("sha256") or "").lower()
            for item in model.get("files") or []
            if isinstance(item, dict) and item.get("path") == "config.json"
        ),
        "",
    )
    config_path = Path(model_path) / "config.json"
    if not config_path.is_file():
        raise FileNotFoundError(f"Whisper model config was not found: {config_path}")
    actual_hash = _file_sha256(config_path)
    if not expected_hash or actual_hash != expected_hash:
        raise ValueError(
            f"Whisper model directory does not match catalog model id {model_id}: {model_path}"
        )
    return {
        "method": "catalog_config_sha256",
        "config_sha256": actual_hash,
        "revision": str(model.get("revision") or ""),
    }


def prepare_app_e2e_environment(
    *,
    e2e_home: Path,
    python_executable: Path,
    model_path: Path,
    model_id: str,
    device: str,
    compute_type: str,
    pipeline_template: Path,
    base_providers_file: Path,
    providers_file: Path | None = None,
    asr_provider: str = DEFAULT_ASR_PROVIDER,
    probe_timeout_seconds: float = 180.0,
    force: bool = False,
) -> dict[str, Any]:
    home = Path(e2e_home).expanduser().resolve()
    python = Path(python_executable).expanduser().resolve()
    model = Path(model_path).expanduser().resolve()
    pipeline_source = Path(pipeline_template).expanduser().resolve()
    providers_source = Path(base_providers_file).expanduser().resolve()
    local_providers_source = (
        Path(providers_file).expanduser().resolve() if providers_file is not None else None
    )
    _validate_prepare_inputs(
        python=python,
        model=model,
        pipeline_template=pipeline_source,
        base_providers_file=providers_source,
        providers_file=local_providers_source,
    )
    model_identity = validate_model_path_identity(model_id, model)
    _prepare_home(home, force=force)
    write_json(
        home / E2E_MARKER_NAME,
        {
            "schema_version": 1,
            "purpose": "flutter_app_e2e",
            "status": "preparing",
            "generated_at": utc_now_iso(),
        },
    )

    probe = probe_python_environment(
        python,
        model_id=model_id,
        model_path=model,
        device=device,
        compute_type=compute_type,
        timeout_seconds=probe_timeout_seconds,
    )
    _require_successful_probe(probe, requested_device=device)

    config_root = home / "Config"
    config_root.mkdir(parents=True, exist_ok=True)
    environment = save_external_environment(
        root_dir=config_root,
        python_executable=python,
        probe=probe,
        app_data_root=home,
    )

    pipeline = _read_yaml(pipeline_source)
    _configure_external_worker(
        pipeline,
        provider_name=asr_provider,
        environment_id=str(environment["id"]),
        model_id=model_id,
        model_path=model,
        device=device,
        compute_type=compute_type,
    )
    pipeline_target = config_root / "pipeline.yaml"
    _write_yaml(pipeline_target, pipeline)

    base_providers_target = config_root / "providers.yaml"
    shutil.copy2(providers_source, base_providers_target)
    local_providers_target: Path | None = None
    if local_providers_source is not None:
        local_providers_target = config_root / "providers.local.yaml"
        shutil.copy2(local_providers_source, local_providers_target)
    else:
        stale_local_providers = config_root / "providers.local.yaml"
        if stale_local_providers.is_file():
            stale_local_providers.unlink()

    config = load_app_config(root_dir=config_root)
    provider = config.asr_providers.get(asr_provider)
    if provider is None:
        raise RuntimeError(f"prepared_asr_provider_missing: {asr_provider}")
    readiness = asr_provider_readiness(
        provider,
        root_dir=config_root,
        app_data_root=home,
    )
    if readiness.get("can_run") is not True or readiness.get("code") != "ready":
        raise RuntimeError(
            "prepared_asr_provider_not_ready: "
            f"{readiness.get('code') or readiness.get('status') or 'unknown'}"
        )
    resolved_runtime = resolve_whisper_runtime(
        provider,
        root_dir=config_root,
        app_data_root=home,
    )
    if not _same_path(resolved_runtime.get("python_executable"), python):
        raise RuntimeError("prepared_runtime_python_mismatch")
    if not _same_path(resolved_runtime.get("model_path"), model):
        raise RuntimeError("prepared_runtime_model_mismatch")

    model_probe = probe.get("model") if isinstance(probe.get("model"), dict) else {}
    cuda_probe = probe.get("cuda") if isinstance(probe.get("cuda"), dict) else {}
    transcription_probe = (
        probe.get("transcription") if isinstance(probe.get("transcription"), dict) else {}
    )
    report: dict[str, Any] = {
        "ok": True,
        "schema_version": 1,
        "purpose": "flutter_app_e2e",
        "generated_at": utc_now_iso(),
        "e2e_home": str(home),
        "config_root": str(config_root),
        "asr_provider": {
            "name": asr_provider,
            "kind": "local_worker",
            "protocol": "faster_whisper",
            "runtime_source": "external",
            "runtime_id": str(environment["id"]),
        },
        "runtime": {
            "python_executable": str(python),
            "python_version": str(probe.get("python_version") or ""),
            "faster_whisper_version": str(probe.get("faster_whisper_version") or ""),
            "ctranslate2_version": str(probe.get("ctranslate2_version") or ""),
            "protocol_version": int(probe.get("protocol_version") or 0),
            "cuda": {
                "available": cuda_probe.get("available") is True,
                "device_count": int(cuda_probe.get("device_count") or 0),
                "compute_types": [str(item) for item in cuda_probe.get("compute_types") or []],
            },
        },
        "model": {
            "id": model_id,
            "path": str(model),
            "identity": model_identity,
            "device": str(model_probe.get("device") or device),
            "compute_type": str(model_probe.get("compute_type") or compute_type),
            "loaded": model_probe.get("loaded") is True,
        },
        "transcription_probe": {
            "ok": transcription_probe.get("ok") is True,
            "row_count": int(transcription_probe.get("row_count") or 0),
        },
        "readiness": {
            "state": str(readiness.get("state") or ""),
            "code": str(readiness.get("code") or ""),
            "can_run": readiness.get("can_run") is True,
        },
        "files": {
            "pipeline": str(pipeline_target),
            "providers": str(base_providers_target),
            "providers_local": str(local_providers_target) if local_providers_target else "",
            "runtime_state": str(config_root / "asr_runtime_state.json"),
        },
    }
    write_json(home / E2E_MARKER_NAME, report)
    return report


def verify_app_e2e_session(
    *,
    e2e_home: Path,
    session_root: Path,
    manual_report_path: Path,
    expected_input_path: Path,
    exe_path: Path,
    repo_root: Path,
    session_report_path: Path,
    asr_provider: str = DEFAULT_ASR_PROVIDER,
) -> dict[str, Any]:
    home = Path(e2e_home).expanduser().resolve()
    root = Path(session_root).expanduser().resolve()
    manual_path = Path(manual_report_path).expanduser().resolve()
    expected_input = Path(expected_input_path).expanduser().resolve()
    executable = Path(exe_path).expanduser().resolve()
    repository = Path(repo_root).expanduser().resolve()
    report_path = Path(session_report_path).expanduser().resolve()

    if not executable.is_file():
        raise FileNotFoundError(f"Flutter Release executable was not found: {executable}")
    if not expected_input.is_file():
        raise FileNotFoundError(f"APP E2E input was not found: {expected_input}")

    preparation = _read_json_payload(home / E2E_MARKER_NAME)
    if preparation.get("ok") is not True or preparation.get("purpose") != "flutter_app_e2e":
        raise RuntimeError("APP E2E preparation marker is not complete")
    prepared_provider = preparation.get("asr_provider")
    if not isinstance(prepared_provider, dict) or any(
        (
            prepared_provider.get("name") != asr_provider,
            prepared_provider.get("kind") != "local_worker",
            prepared_provider.get("runtime_source") != "external",
        )
    ):
        raise RuntimeError("APP E2E preparation is not an external local_worker configuration")

    manual = _read_json_payload(manual_path)
    if (
        manual.get("ok") is not True
        or manual.get("manual_visible_e2e_ok") is not True
        or manual.get("launch_check") is True
    ):
        raise RuntimeError("Manual visible APP E2E acceptance did not pass")
    if not _same_path(manual.get("input_path"), expected_input):
        raise RuntimeError("Manual acceptance input does not match the requested APP E2E input")
    started_at = _parse_iso_datetime(manual.get("started_at"), label="manual started_at")
    ended_at = _parse_iso_datetime(manual.get("ended_at"), label="manual ended_at")
    if ended_at < started_at:
        raise RuntimeError("Manual acceptance ended_at precedes started_at")

    config_root = home / "Config"
    config = load_app_config(root_dir=config_root)
    provider = config.asr_providers.get(asr_provider)
    if provider is None:
        raise RuntimeError(f"APP E2E ASR provider is missing after the run: {asr_provider}")
    if provider.kind != "local_worker" or provider.runtime.source != "external":
        raise RuntimeError("APP E2E ASR provider no longer uses an external local_worker")
    prepared_runtime_id = str(prepared_provider.get("runtime_id") or "")
    if not prepared_runtime_id or provider.runtime.id != prepared_runtime_id:
        raise RuntimeError("APP E2E ASR provider no longer uses the prepared external runtime id")
    readiness = asr_provider_readiness(provider, root_dir=config_root, app_data_root=home)
    if readiness.get("can_run") is not True or readiness.get("code") != "ready":
        raise RuntimeError("APP E2E external worker is not ready after the run")
    resolved_runtime = resolve_whisper_runtime(provider, root_dir=config_root, app_data_root=home)
    prepared_runtime = preparation.get("runtime")
    prepared_model = preparation.get("model")
    if not isinstance(prepared_runtime, dict) or not isinstance(prepared_model, dict):
        raise RuntimeError("APP E2E preparation marker is missing runtime or model identity")
    prepared_python_path = str(prepared_runtime.get("python_executable") or "").strip()
    prepared_model_path = str(prepared_model.get("path") or "").strip()
    if not prepared_python_path or not prepared_model_path:
        raise RuntimeError("APP E2E preparation marker has incomplete runtime or model paths")
    if not _same_path(
        resolved_runtime.get("python_executable"),
        Path(prepared_python_path),
    ):
        raise RuntimeError("APP E2E runtime Python no longer matches the prepared environment")
    if not _same_path(
        resolved_runtime.get("model_path"),
        Path(prepared_model_path),
    ):
        raise RuntimeError("APP E2E model path no longer matches the prepared environment")

    task_dir, task, task_candidate_count = _find_session_task(
        tasks_root=home / "Workspace" / "Tasks",
        expected_input=expected_input,
        started_at=started_at,
        ended_at=ended_at,
    )
    if task.get("status") != "DONE":
        raise RuntimeError(
            f"Latest APP E2E task did not finish successfully: {task.get('status') or 'unknown'}"
        )
    checkpoint = _read_json_payload(task_dir / "checkpoint.json")
    if checkpoint.get("status") != "DONE":
        raise RuntimeError("APP E2E checkpoint is not DONE")
    total_segments = int(checkpoint.get("asr_total_segments") or 0)
    done_segments = checkpoint.get("asr_done_segments")
    done_count = int(checkpoint.get("asr_done_count") or 0)
    if (
        total_segments < 1
        or not isinstance(done_segments, list)
        or done_count != total_segments
        or len(done_segments) != total_segments
    ):
        raise RuntimeError("APP E2E task did not complete every ASR segment")
    settings = task.get("settings")
    if not isinstance(settings, dict) or settings.get("input_type") != "video_asr_translate":
        raise RuntimeError(
            "asr_not_exercised: APP E2E task did not use the full media ASR and translation mode"
        )
    if settings.get("asr_provider") != asr_provider:
        raise RuntimeError("APP E2E task did not use the prepared ASR provider")

    output_paths = _existing_task_outputs(task)
    row_evidence = _external_asr_row_evidence(
        task_dir,
        asr_provider=asr_provider,
        runtime_id=prepared_runtime_id,
        device=str(prepared_model.get("device") or ""),
        compute_type=str(prepared_model.get("compute_type") or ""),
    )
    process_evidence = _task_process_evidence(task_dir)
    git = _git_snapshot(repository)
    manual_steps = [
        {
            "id": str(step.get("id") or ""),
            "confirmed": step.get("confirmed") is True,
            "screenshot_path": str(step.get("screenshot_path") or ""),
        }
        for step in manual.get("steps") or []
        if isinstance(step, dict)
    ]
    report: dict[str, Any] = {
        "ok": True,
        "schema_version": 1,
        "purpose": "flutter_app_e2e_session",
        "generated_at": utc_now_iso(),
        "scope": "visible_flutter_release_external_worker_e2e",
        "session_root": str(root),
        "input_path": str(expected_input),
        "git": git,
        "executable": {
            "path": str(executable),
            "sha256": _file_sha256(executable),
        },
        "preparation": preparation,
        "manual_acceptance": {
            "report_path": str(manual_path),
            "ok": True,
            "started_at": str(manual.get("started_at") or ""),
            "ended_at": str(manual.get("ended_at") or ""),
            "steps": manual_steps,
        },
        "task": {
            "id": str(task.get("task_id") or task_dir.name),
            "status": "DONE",
            "directory": str(task_dir),
            "created_at": str(task.get("created_at") or ""),
            "updated_at": str(task.get("updated_at") or ""),
            "output_paths": output_paths,
            "checkpoint_status": "DONE",
            "candidate_count": task_candidate_count,
        },
        "asr_evidence": row_evidence,
        "process_evidence": process_evidence,
        "validated": [
            "visible_flutter_release",
            "workspace_local_service",
            "external_local_worker",
            "independent_jsonl_whisper_host",
            "real_asr_media_task",
            "task_output_and_result_review",
        ],
        "not_covered": [
            "managed_component_download",
            "managed_component_install",
            "installer_path",
            "clean_windows_machine",
        ],
        "report_path": str(report_path),
    }
    write_json(report_path, report)
    return report


def app_e2e_plan(
    *,
    e2e_home: Path,
    python_executable: Path,
    model_path: Path,
    model_id: str,
    device: str,
    compute_type: str,
    pipeline_template: Path,
    base_providers_file: Path,
    providers_file: Path | None,
    asr_provider: str,
) -> dict[str, Any]:
    return {
        "ok": True,
        "plan_only": True,
        "purpose": "flutter_app_e2e",
        "e2e_home": str(Path(e2e_home).expanduser().resolve()),
        "python_executable": str(Path(python_executable).expanduser().resolve()),
        "model": {
            "id": model_id,
            "path": str(Path(model_path).expanduser().resolve()),
            "device": device,
            "compute_type": compute_type,
        },
        "asr_provider": {
            "name": asr_provider,
            "kind": "local_worker",
            "runtime_source": "external",
        },
        "sources": {
            "pipeline_template": str(Path(pipeline_template).expanduser().resolve()),
            "providers": str(Path(base_providers_file).expanduser().resolve()),
            "providers_local": (
                str(Path(providers_file).expanduser().resolve()) if providers_file else ""
            ),
        },
        "actions": [
            "probe_python_cuda_and_model",
            "run_minimal_transcription",
            "register_external_worker_environment",
            "write_isolated_desktop_config",
        ],
    }


def _validate_prepare_inputs(
    *,
    python: Path,
    model: Path,
    pipeline_template: Path,
    base_providers_file: Path,
    providers_file: Path | None,
) -> None:
    if not python.is_file():
        raise FileNotFoundError(f"Python executable was not found: {python}")
    if not model.is_dir():
        raise FileNotFoundError(f"Whisper model directory was not found: {model}")
    if not pipeline_template.is_file():
        raise FileNotFoundError(f"Pipeline template was not found: {pipeline_template}")
    if not base_providers_file.is_file():
        raise FileNotFoundError(f"Providers file was not found: {base_providers_file}")
    if providers_file is not None and not providers_file.is_file():
        raise FileNotFoundError(f"Local providers file was not found: {providers_file}")


def _prepare_home(home: Path, *, force: bool) -> None:
    marker = home / E2E_MARKER_NAME
    if home.exists():
        children = list(home.iterdir())
        if children:
            if not marker.is_file():
                raise FileExistsError(
                    f"Refusing to use a non-empty directory that is not an APP E2E home: {home}"
                )
            try:
                ownership = read_json(marker)
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                raise FileExistsError(f"APP E2E ownership marker is invalid: {marker}") from exc
            if not isinstance(ownership, dict) or ownership.get("purpose") != "flutter_app_e2e":
                raise FileExistsError(f"APP E2E ownership marker is invalid: {marker}")
            if not force:
                raise FileExistsError(
                    f"E2E home already exists: {home}. Pass --force to refresh its known config files."
                )
    home.mkdir(parents=True, exist_ok=True)


def _require_successful_probe(probe: dict[str, Any], *, requested_device: str) -> None:
    if probe.get("ok") is not True:
        code = str(probe.get("code") or "environment_probe_failed")
        message = str(probe.get("message") or "Whisper environment probe failed")
        raise RuntimeError(f"{code}: {message}")
    if int(probe.get("protocol_version") or 0) != WHISPER_HOST_PROTOCOL_VERSION:
        raise RuntimeError(
            "environment_protocol_incompatible: "
            f"expected {WHISPER_HOST_PROTOCOL_VERSION}, got {probe.get('protocol_version')}"
        )
    model = probe.get("model") if isinstance(probe.get("model"), dict) else {}
    transcription = (
        probe.get("transcription") if isinstance(probe.get("transcription"), dict) else {}
    )
    if model.get("loaded") is not True or transcription.get("ok") is not True:
        raise RuntimeError("environment_probe_incomplete: model load or minimal transcription did not pass")
    if requested_device == "cuda":
        cuda = probe.get("cuda") if isinstance(probe.get("cuda"), dict) else {}
        if cuda.get("available") is not True or model.get("device") != "cuda":
            raise RuntimeError("hardware_incompatible: CUDA was requested but the probe did not use CUDA")


def _configure_external_worker(
    pipeline: dict[str, Any],
    *,
    provider_name: str,
    environment_id: str,
    model_id: str,
    model_path: Path,
    device: str,
    compute_type: str,
) -> None:
    asr = pipeline.get("asr") if isinstance(pipeline.get("asr"), dict) else {}
    pipeline["asr"] = asr
    asr["provider"] = provider_name

    rows = pipeline.get("asr_providers")
    if not isinstance(rows, list):
        rows = []
        pipeline["asr_providers"] = rows
    provider = next(
        (item for item in rows if isinstance(item, dict) and item.get("name") == provider_name),
        None,
    )
    if provider is None:
        provider = {"name": provider_name}
        rows.insert(0, provider)
    provider["kind"] = "local_worker"
    provider["protocol"] = "faster_whisper"
    provider["model"] = model_id
    provider["auth"] = {"type": "none"}
    provider["runtime"] = {"source": "external", "id": environment_id}

    local = provider.get("local") if isinstance(provider.get("local"), dict) else {}
    provider["local"] = local
    local.update(
        {
            "model_size": model_id,
            "model_source": "external",
            "model_path": str(model_path),
            "device": device,
            "compute_type": compute_type,
        }
    )


def _read_yaml(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(payload, dict):
        raise ValueError(f"YAML root must be an object: {path}")
    return payload


def _write_yaml(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.safe_dump(payload, allow_unicode=True, sort_keys=False)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def _read_json_payload(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"Required APP E2E evidence was not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise ValueError(f"APP E2E evidence root must be an object: {path}")
    return payload


def _parse_iso_datetime(value: Any, *, label: str) -> datetime:
    text = str(value or "").strip()
    if not text:
        raise ValueError(f"{label} is missing")
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _find_session_task(
    *,
    tasks_root: Path,
    expected_input: Path,
    started_at: datetime,
    ended_at: datetime,
) -> tuple[Path, dict[str, Any], int]:
    if not tasks_root.is_dir():
        raise FileNotFoundError(f"APP E2E task root was not created: {tasks_root}")
    candidates: list[tuple[datetime, Path, dict[str, Any]]] = []
    for task_file in tasks_root.glob("*/task.json"):
        try:
            task = _read_json_payload(task_file)
            created_at = _parse_iso_datetime(task.get("created_at"), label="task created_at")
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if (
            created_at < started_at
            or created_at > ended_at
            or not _same_path(task.get("input_file"), expected_input)
        ):
            continue
        candidates.append((created_at, task_file.parent, task))
    if not candidates:
        raise RuntimeError(
            "No task created by this APP E2E session matched the requested input. "
            "Use media that actually requires ASR and submit it in the visible APP."
        )
    if len(candidates) != 1:
        raise RuntimeError(
            "APP E2E evidence is ambiguous: more than one task matched this input and manual "
            "acceptance window. Start a new E2E session and submit the task once."
        )
    _created_at, task_dir, task = candidates[0]
    return task_dir, task, 1


def _existing_task_outputs(task: dict[str, Any]) -> dict[str, str]:
    outputs: dict[str, str] = {}
    primary = str(task.get("output_path") or "").strip()
    if primary:
        outputs["primary"] = primary
    configured = task.get("output_paths")
    if isinstance(configured, dict):
        for key, value in configured.items():
            path = str(value or "").strip()
            if path:
                outputs[str(key)] = path
    if not outputs:
        raise RuntimeError("APP E2E task did not record any output paths")
    missing = [
        path
        for path in outputs.values()
        if not Path(path).is_file() or Path(path).stat().st_size < 1
    ]
    if missing:
        raise FileNotFoundError(f"APP E2E task output was not found: {missing[0]}")
    return outputs


def _external_asr_row_evidence(
    task_dir: Path,
    *,
    asr_provider: str,
    runtime_id: str,
    device: str,
    compute_type: str,
) -> dict[str, Any]:
    row_files = sorted((task_dir / "source" / "asr" / "rows").glob("segment_*.json"))
    if not row_files:
        raise RuntimeError("asr_not_exercised: APP E2E task has no persisted ASR row files")
    row_count = 0
    for row_file in row_files:
        payload = json.loads(row_file.read_text(encoding="utf-8-sig"))
        if not isinstance(payload, list):
            raise ValueError(f"ASR row evidence must be a list: {row_file}")
        for row in payload:
            if not isinstance(row, dict):
                raise ValueError(f"ASR row evidence contains a non-object row: {row_file}")
            meta = row.get("meta")
            if not isinstance(meta, dict) or any(
                (
                    meta.get("source") != "asr",
                    meta.get("provider") != asr_provider,
                    meta.get("protocol") != "faster_whisper",
                    meta.get("runtime_source") != "external",
                    meta.get("runtime_id") != runtime_id,
                    meta.get("transport") != "stdio_jsonl",
                    meta.get("device") != device,
                    meta.get("compute_type") != compute_type,
                )
            ):
                raise RuntimeError(
                    "ASR task evidence does not prove the configured external faster-whisper worker"
                )
            row_count += 1
    if row_count < 1:
        raise RuntimeError(
            "asr_not_exercised: APP E2E task did not persist any external worker subtitle rows"
        )
    return {
        "provider": asr_provider,
        "provider_kind": "local_worker",
        "protocol": "faster_whisper",
        "runtime_source": "external",
        "runtime_id": runtime_id,
        "transport": "stdio_jsonl",
        "transport_basis": "persisted_asr_row_meta",
        "device": device,
        "compute_type": compute_type,
        "row_file_count": len(row_files),
        "row_count": row_count,
        "row_files": [str(path) for path in row_files],
    }


def _task_process_evidence(task_dir: Path) -> dict[str, Any]:
    worker = _read_json_payload(task_dir / "worker.json")
    if any(
        (
            worker.get("owner") != "python",
            worker.get("command") != "_worker",
            worker.get("state") != "ended",
            int(worker.get("exit_code") if worker.get("exit_code") is not None else -1) != 0,
        )
    ):
        raise RuntimeError("APP E2E Python task worker did not exit cleanly")
    events_path = task_dir / "events.jsonl"
    if not events_path.is_file():
        raise FileNotFoundError(f"APP E2E task events were not found: {events_path}")
    done_event: dict[str, Any] | None = None
    with events_path.open("r", encoding="utf-8-sig") as handle:
        for line in handle:
            if not line.strip():
                continue
            event = json.loads(line)
            if (
                isinstance(event, dict)
                and event.get("type") == "done"
                and event.get("stage") == "DONE"
                and float(event.get("progress") or 0.0) == 1.0
            ):
                done_event = event
    if done_event is None:
        raise RuntimeError("APP E2E task did not persist its final DONE event")
    return {
        "owner": "python",
        "command": "_worker",
        "state": "ended",
        "exit_code": 0,
        "done_event_at": str(done_event.get("created_at") or ""),
    }


def _git_snapshot(repo_root: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"commit": "", "dirty": None}
    if not (repo_root / ".git").exists():
        return result
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        result["commit"] = commit.stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        result["dirty"] = bool(status.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return result


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _same_path(value: Any, expected: Path) -> bool:
    if not str(value or "").strip():
        return False
    try:
        actual = Path(str(value)).expanduser().resolve()
    except OSError:
        return False
    return os.path.normcase(str(actual)) == os.path.normcase(str(expected.resolve()))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare an isolated Flutter APP E2E home backed by an external Whisper worker runtime."
    )
    parser.add_argument("--e2e-home", required=True)
    parser.add_argument("--verify-session", action="store_true")
    parser.add_argument("--session-root", default="")
    parser.add_argument("--manual-report", default="")
    parser.add_argument("--expected-input", default="")
    parser.add_argument("--exe-path", default="")
    parser.add_argument("--repo-root", default="")
    parser.add_argument("--session-report", default="")
    parser.add_argument("--python-executable", default="")
    parser.add_argument("--model-id", default="large-v3", choices=("small", "medium", "large-v3"))
    parser.add_argument("--model-path", default="")
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "cuda"))
    parser.add_argument("--compute-type", default="auto")
    parser.add_argument("--pipeline-template", default="")
    parser.add_argument("--base-providers-file", default="")
    parser.add_argument("--providers-file", default="")
    parser.add_argument("--asr-provider", default=DEFAULT_ASR_PROVIDER)
    parser.add_argument("--probe-timeout-seconds", type=float, default=180.0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.verify_session:
            required = {
                "session_root": args.session_root,
                "manual_report": args.manual_report,
                "expected_input": args.expected_input,
                "exe_path": args.exe_path,
                "repo_root": args.repo_root,
                "session_report": args.session_report,
            }
            missing = [name.replace("_", "-") for name, value in required.items() if not value]
            if missing:
                raise ValueError(
                    "Session verification requires: " + ", ".join(f"--{name}" for name in missing)
                )
            result = verify_app_e2e_session(
                e2e_home=Path(args.e2e_home),
                session_root=Path(args.session_root),
                manual_report_path=Path(args.manual_report),
                expected_input_path=Path(args.expected_input),
                exe_path=Path(args.exe_path),
                repo_root=Path(args.repo_root),
                session_report_path=Path(args.session_report),
                asr_provider=args.asr_provider,
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if not args.pipeline_template or not args.base_providers_file:
            raise ValueError("Preparation requires --pipeline-template and --base-providers-file")
        python = resolve_python_executable(args.python_executable)
        model = resolve_model_path(args.model_id, args.model_path)
        common = {
            "e2e_home": Path(args.e2e_home),
            "python_executable": python,
            "model_path": model,
            "model_id": args.model_id,
            "device": args.device,
            "compute_type": args.compute_type,
            "pipeline_template": Path(args.pipeline_template),
            "base_providers_file": Path(args.base_providers_file),
            "providers_file": Path(args.providers_file) if args.providers_file else None,
            "asr_provider": args.asr_provider,
        }
        if args.plan_only:
            result = app_e2e_plan(**common)
        else:
            result = prepare_app_e2e_environment(
                **common,
                probe_timeout_seconds=args.probe_timeout_seconds,
                force=args.force,
            )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001 - command returns one structured failure
        print(
            json.dumps(
                {"ok": False, "error_type": type(exc).__name__, "message": str(exc)},
                ensure_ascii=False,
                indent=2,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
