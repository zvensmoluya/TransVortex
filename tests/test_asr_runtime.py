from __future__ import annotations

import hashlib
import io
import json
import threading
import time
import zipfile
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from transvortex.app.asr_operations import AsrOperationError, AsrOperationManager
from transvortex.app.asr_runtime import (
    asr_provider_readiness,
    asr_runtime_paths,
    discover_python_environments,
    load_asr_runtime_state,
    probe_managed_model,
    probe_python_environment,
    provider_test_fingerprint,
    resolve_whisper_runtime,
    save_asr_runtime_state,
    save_external_environment,
)
from transvortex.app.media_inspect import inspect_media_source
from transvortex.app.models import AsrAuthConfig, AsrLocalConfig, AsrProviderConfig, AsrRuntimeConfig
from transvortex.utils import write_json


def _catalog(content: bytes = b"trusted-model") -> dict:
    return {
        "schema_version": 1,
        "runtime": {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "protocol_version": 1,
            "artifact": {"published": False, "url": "", "size": 0, "sha256": ""},
        },
        "accelerators": [],
        "models": [
            {
                "id": "small",
                "repository": "example/model",
                "revision": "pinned-revision",
                "files": [
                    {
                        "path": "model.bin",
                        "size": len(content),
                        "sha256": hashlib.sha256(content).hexdigest(),
                    }
                ],
            }
        ],
    }


def test_provider_test_fingerprint_tracks_auth_and_request_shape() -> None:
    original = AsrProviderConfig(
        name="remote_asr",
        kind="remote",
        model="whisper-1",
        auth=AsrAuthConfig(type="bearer", env_key="ASR_KEY", credential_id="asr-prod"),
    )
    changed_credential = AsrProviderConfig(
        name="remote_asr",
        kind="remote",
        model="whisper-1",
        auth=AsrAuthConfig(type="bearer", env_key="ASR_KEY", credential_id="asr-next"),
    )
    changed_request = AsrProviderConfig(
        name="remote_asr",
        kind="remote",
        model="whisper-1",
        auth=AsrAuthConfig(type="bearer", env_key="ASR_KEY", credential_id="asr-prod"),
    )
    changed_request.request.send_language = False

    assert provider_test_fingerprint(original) != provider_test_fingerprint(changed_credential)
    assert provider_test_fingerprint(original) != provider_test_fingerprint(changed_request)


def test_asr_readiness_rejects_insecure_or_misclassified_service_endpoints(tmp_path: Path) -> None:
    remote = AsrProviderConfig(name="remote", kind="remote", base_url="http://example.invalid/v1")
    local = AsrProviderConfig(name="local", kind="local_server", base_url="https://example.invalid/v1")

    assert asr_provider_readiness(remote, root_dir=tmp_path)["code"] == "remote_endpoint_requires_https"
    assert asr_provider_readiness(local, root_dir=tmp_path)["code"] == "local_service_endpoint_not_loopback"


def _wait_terminal(manager: AsrOperationManager, operation_id: str) -> dict:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        operation = manager.operation(operation_id)
        if operation["state"] not in {"queued", "running", "cancelling"}:
            return operation
        time.sleep(0.01)
    raise AssertionError("ASR operation did not finish")


def test_model_install_resumes_and_verifies_trusted_hash(tmp_path: Path) -> None:
    content = b"trusted-model"
    catalog = _catalog(content)
    paths = asr_runtime_paths(tmp_path)
    part = paths.downloads_root / "models" / "small" / "pinned-revision" / "model.bin.part"
    part.parent.mkdir(parents=True)
    part.write_bytes(content[:4])
    ranges: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        ranges.append(request.headers.get("Range", ""))
        return httpx.Response(206, content=content[4:], request=request)

    transport = httpx.MockTransport(handler)
    manager = AsrOperationManager(
        root_dir=tmp_path,
        catalog=catalog,
        client_factory=lambda: httpx.Client(transport=transport),
    )

    started = manager.start_install("model", "small")
    completed = _wait_terminal(manager, started["id"])

    target = paths.models_root / "small" / "pinned-revision"
    assert completed["state"] == "completed"
    assert ranges == ["bytes=4-"]
    assert (target / "model.bin").read_bytes() == content
    assert json.loads((target / "model.json").read_text(encoding="utf-8"))["revision"] == "pinned-revision"
    assert not part.exists()


def test_model_install_reuses_complete_verified_download_without_network(tmp_path: Path) -> None:
    content = b"trusted-model"
    catalog = _catalog(content)
    paths = asr_runtime_paths(tmp_path)
    part = paths.downloads_root / "models" / "small" / "pinned-revision" / "model.bin.part"
    part.parent.mkdir(parents=True)
    part.write_bytes(content)
    client_factory_calls = 0

    def client_factory() -> httpx.Client:
        nonlocal client_factory_calls
        client_factory_calls += 1
        raise AssertionError("verified download cache must not create an HTTP client")

    manager = AsrOperationManager(
        root_dir=tmp_path,
        catalog=catalog,
        client_factory=client_factory,
    )

    completed = _wait_terminal(manager, manager.start_install("model", "small")["id"])

    target = paths.models_root / "small" / "pinned-revision"
    assert completed["state"] == "completed"
    assert completed["bytes_done"] == len(content)
    assert client_factory_calls == 0
    assert (target / "model.bin").read_bytes() == content
    assert not part.exists()


def test_model_install_overwrites_complete_download_with_wrong_hash(tmp_path: Path) -> None:
    content = b"trusted-model"
    catalog = _catalog(content)
    paths = asr_runtime_paths(tmp_path)
    part = paths.downloads_root / "models" / "small" / "pinned-revision" / "model.bin.part"
    part.parent.mkdir(parents=True)
    part.write_bytes(b"x" * len(content))
    requests = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal requests
        requests += 1
        return httpx.Response(200, content=content, request=request)

    manager = AsrOperationManager(
        root_dir=tmp_path,
        catalog=catalog,
        client_factory=lambda: httpx.Client(transport=httpx.MockTransport(handler)),
    )

    completed = _wait_terminal(manager, manager.start_install("model", "small")["id"])

    target = paths.models_root / "small" / "pinned-revision"
    assert completed["state"] == "completed"
    assert requests == 1
    assert (target / "model.bin").read_bytes() == content
    assert not part.exists()


def test_model_install_rejects_checksum_mismatch(tmp_path: Path, monkeypatch) -> None:
    catalog = _catalog(b"expected")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"tampered", request=request)

    monkeypatch.setattr("transvortex.app.asr_operations.time.sleep", lambda _seconds: None)
    transport = httpx.MockTransport(handler)
    manager = AsrOperationManager(
        root_dir=tmp_path,
        catalog=catalog,
        client_factory=lambda: httpx.Client(transport=transport),
    )

    completed = _wait_terminal(manager, manager.start_install("model", "small")["id"])

    assert completed["state"] == "failed"
    assert completed["error_code"] == "checksum_mismatch"
    assert not (asr_runtime_paths(tmp_path).models_root / "small" / "pinned-revision").exists()


def test_component_install_rejects_unpublished_artifact(tmp_path: Path) -> None:
    manager = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())

    with pytest.raises(AsrOperationError, match="not been published") as error:
        manager.start_install("runtime")

    assert error.value.code == "component_unpublished"


def test_runtime_component_install_verifies_and_extracts_archive(tmp_path: Path) -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as bundle:
        bundle.writestr("python.exe", b"embedded-runtime")
    archive = buffer.getvalue()
    catalog = _catalog()
    catalog["runtime"]["python"] = "python.exe"
    catalog["runtime"]["artifact"] = {
        "published": True,
        "url": "https://downloads.example.test/runtime.zip",
        "size": len(archive),
        "sha256": hashlib.sha256(archive).hexdigest(),
    }

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=archive, request=request)

    manager = AsrOperationManager(
        root_dir=tmp_path,
        catalog=catalog,
        client_factory=lambda: httpx.Client(transport=httpx.MockTransport(handler)),
    )

    completed = _wait_terminal(manager, manager.start_install("runtime")["id"])

    target = asr_runtime_paths(tmp_path).components_root / "faster-whisper" / "1.0.0"
    marker = json.loads((target / "component.json").read_text(encoding="utf-8"))
    assert completed["state"] == "completed"
    assert (target / "python.exe").read_bytes() == b"embedded-runtime"
    assert marker["id"] == "managed:faster-whisper"
    assert marker["protocol_version"] == 1
    assert marker["artifact_sha256"] == hashlib.sha256(archive).hexdigest()


def test_component_archive_rejects_path_traversal(tmp_path: Path) -> None:
    manager = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())
    archive = tmp_path / "unsafe.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("../outside.txt", "unsafe")

    with pytest.raises(AsrOperationError) as error:
        manager._safe_extract_zip(archive, tmp_path / "extract", threading.Event())

    assert error.value.code == "unsafe_path"
    assert not (tmp_path / "outside.txt").exists()


def test_model_install_rejects_catalog_path_outside_managed_model_root(tmp_path: Path) -> None:
    catalog = _catalog()
    catalog["models"][0]["id"] = "../outside"
    manager = AsrOperationManager(root_dir=tmp_path, catalog=catalog)

    completed = _wait_terminal(manager, manager.start_install("model", "../outside")["id"])

    assert completed["state"] == "failed"
    assert completed["error_code"] == "unsafe_path"
    assert not (asr_runtime_paths(tmp_path).models_root.parent / "outside").exists()


def test_component_operation_can_be_cancelled(tmp_path: Path, monkeypatch) -> None:
    manager = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())

    def wait_for_cancel(_operation_id, _entry, cancel_event):  # noqa: ANN001
        while not cancel_event.wait(0.01):
            pass
        manager._check_cancelled(cancel_event)

    monkeypatch.setattr(manager, "_install_model", wait_for_cancel)
    started = manager.start_install("model", "small")
    manager.cancel(started["id"])
    completed = _wait_terminal(manager, started["id"])

    assert completed["state"] == "cancelled"
    assert completed["error_code"] == "cancelled"


def test_operation_reconcile_does_not_overwrite_another_live_service(tmp_path: Path) -> None:
    first = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())
    operation = {
        "id": "asr_live",
        "kind": "model",
        "item_id": "small",
        "state": "running",
        "owner_pid": __import__("os").getpid(),
        "created_at": "2026-07-14T00:00:00+00:00",
        "updated_at": "2026-07-14T00:00:00+00:00",
    }
    write_json(first.paths.operations_root / "asr_live.json", operation)

    second = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())

    assert second.operation("asr_live")["state"] == "running"


def test_install_backup_is_restored_after_interrupted_directory_swap(tmp_path: Path) -> None:
    catalog = _catalog()
    paths = asr_runtime_paths(tmp_path)
    target = paths.models_root / "small" / "pinned-revision"
    backup = target.parent / ".pinned-revision.previous"
    backup.mkdir(parents=True)
    (backup / "model.bin").write_bytes(b"trusted-model")
    write_json(backup / "model.json", {"id": "small", "revision": "pinned-revision"})

    AsrOperationManager(root_dir=tmp_path, catalog=catalog)

    assert target.is_dir()
    assert (target / "model.bin").read_bytes() == b"trusted-model"
    assert not backup.exists()


def test_install_directory_swap_retries_transient_permission_error(
    tmp_path: Path,
    monkeypatch,
) -> None:
    manager = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())
    staging = manager.paths.components_root / "faster-whisper" / ".1.0.0.installing"
    target = manager.paths.components_root / "faster-whisper" / "1.0.0"
    staging.mkdir(parents=True)
    (staging / "python.exe").write_bytes(b"runtime")
    real_replace = __import__("os").replace
    replace_attempts = 0
    retry_delays: list[float] = []

    def transient_replace(source, destination):  # noqa: ANN001
        nonlocal replace_attempts
        replace_attempts += 1
        if replace_attempts < 3:
            raise PermissionError("temporary scanner lock")
        real_replace(source, destination)

    monkeypatch.setattr("transvortex.app.asr_operations.os.replace", transient_replace)
    monkeypatch.setattr(
        "transvortex.app.asr_operations.time.sleep",
        lambda seconds: retry_delays.append(seconds),
    )

    manager._replace_directory(staging, target)

    assert replace_attempts == 3
    assert retry_delays == [0.1, 0.2]
    assert (target / "python.exe").read_bytes() == b"runtime"
    assert not staging.exists()


def test_install_directory_swap_retries_backup_cleanup_lock(
    tmp_path: Path,
    monkeypatch,
) -> None:
    manager = AsrOperationManager(root_dir=tmp_path, catalog=_catalog())
    staging = manager.paths.components_root / "faster-whisper" / ".1.0.0.installing"
    target = manager.paths.components_root / "faster-whisper" / "1.0.0"
    backup = target.parent / ".1.0.0.previous"
    target.mkdir(parents=True)
    (target / "old.dll").write_bytes(b"old")
    staging.mkdir(parents=True)
    (staging / "python.exe").write_bytes(b"runtime")

    real_rmtree = __import__("shutil").rmtree
    cleanup_attempts = 0
    retry_delays: list[float] = []

    def transient_rmtree(path, *args, **kwargs):  # noqa: ANN001
        nonlocal cleanup_attempts
        if Path(path) == backup:
            cleanup_attempts += 1
            if cleanup_attempts < 3:
                raise PermissionError("temporary scanner lock")
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr("transvortex.app.asr_operations.shutil.rmtree", transient_rmtree)
    monkeypatch.setattr(
        "transvortex.app.asr_operations.time.sleep",
        lambda seconds: retry_delays.append(seconds),
    )

    manager._replace_directory(staging, target)

    assert cleanup_attempts == 3
    assert retry_delays == [0.1, 0.2]
    assert (target / "python.exe").read_bytes() == b"runtime"
    assert not backup.exists()


def test_managed_whisper_readiness_distinguishes_install_steps(tmp_path: Path, monkeypatch) -> None:
    catalog = _catalog()
    catalog_path = tmp_path / "catalog.json"
    write_json(catalog_path, catalog)
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))
    paths = asr_runtime_paths(tmp_path)
    provider = AsrProviderConfig(
        name="whisper",
        kind="local_worker",
        protocol="faster_whisper",
        model="small",
        runtime=AsrRuntimeConfig(source="managed", id="managed:faster-whisper"),
        local=AsrLocalConfig(device="auto", compute_type="auto"),
    )

    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "runtime_unpublished"

    runtime_root = paths.components_root / "faster-whisper" / "1.0.0"
    runtime_root.mkdir(parents=True)
    (runtime_root / "python.exe").write_bytes(b"")
    write_json(
        runtime_root / "component.json",
        {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "python": "python.exe",
            "protocol_version": 1,
        },
    )
    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "model_missing"

    paths.operations_root.mkdir(parents=True)
    write_json(
        paths.operations_root / "active.json",
        {"id": "active", "kind": "model", "item_id": "small", "state": "running"},
    )
    checking = asr_provider_readiness(provider, root_dir=tmp_path)
    assert checking["state"] == "checking"
    assert checking["code"] == "model_installing"

    (paths.operations_root / "active.json").unlink()
    model_root = paths.models_root / "small" / "pinned-revision"
    model_root.mkdir(parents=True)
    (model_root / "model.bin").write_bytes(b"trusted-model")
    write_json(model_root / "model.json", {"id": "small", "revision": "pinned-revision"})
    ready = asr_provider_readiness(provider, root_dir=tmp_path)
    assert ready["state"] == "ready"
    assert ready["can_run"] is True


def test_managed_cuda_readiness_requires_real_hardware_probe(tmp_path: Path, monkeypatch) -> None:
    catalog = _catalog()
    catalog["accelerators"] = [
        {"id": "nvidia-cuda12", "version": "12.4", "artifact": {"published": False}}
    ]
    catalog_path = tmp_path / "catalog.json"
    write_json(catalog_path, catalog)
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))
    paths = asr_runtime_paths(tmp_path)
    runtime_root = paths.components_root / "faster-whisper" / "1.0.0"
    runtime_root.mkdir(parents=True)
    (runtime_root / "python.exe").write_bytes(b"")
    write_json(
        runtime_root / "component.json",
        {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "python": "python.exe",
            "protocol_version": 1,
        },
    )
    model_root = paths.models_root / "small" / "pinned-revision"
    model_root.mkdir(parents=True)
    (model_root / "model.bin").write_bytes(b"trusted-model")
    write_json(model_root / "model.json", {"id": "small", "revision": "pinned-revision"})
    accelerator_root = paths.components_root / "accelerators" / "nvidia-cuda12" / "12.4"
    accelerator_root.mkdir(parents=True)
    marker_path = accelerator_root / "component.json"
    write_json(marker_path, {"id": "nvidia-cuda12", "version": "12.4", "root": str(accelerator_root)})
    provider = AsrProviderConfig(
        name="whisper",
        kind="local_worker",
        protocol="faster_whisper",
        model="small",
        runtime=AsrRuntimeConfig(source="managed", id="managed:faster-whisper"),
        local=AsrLocalConfig(device="cuda", compute_type="auto"),
    )

    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "hardware_untested"

    write_json(
        marker_path,
        {
            "id": "nvidia-cuda12",
            "version": "12.4",
            "root": str(accelerator_root),
            "hardware_probe": {"ok": True, "cuda": {"available": False}},
        },
    )
    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "hardware_incompatible"

    write_json(
        marker_path,
        {
            "id": "nvidia-cuda12",
            "version": "12.4",
            "root": str(accelerator_root),
            "hardware_probe": {
                "ok": True,
                "cuda": {"available": True, "compute_types": ["float16", "int8_float16"]},
            },
        },
    )
    assert asr_provider_readiness(provider, root_dir=tmp_path)["can_run"] is True


def test_managed_hardware_probe_is_saved_to_accelerator_marker(tmp_path: Path, monkeypatch) -> None:
    catalog = _catalog()
    catalog["accelerators"] = [
        {"id": "nvidia-cuda12", "version": "12.4", "artifact": {"published": False}}
    ]
    manager = AsrOperationManager(root_dir=tmp_path, catalog=catalog)
    runtime_root = manager.paths.components_root / "faster-whisper" / "1.0.0"
    runtime_root.mkdir(parents=True)
    (runtime_root / "python.exe").write_bytes(b"")
    write_json(
        runtime_root / "component.json",
        {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "python": "python.exe",
            "protocol_version": 1,
        },
    )
    accelerator_root = manager.paths.components_root / "accelerators" / "nvidia-cuda12" / "12.4"
    accelerator_root.mkdir(parents=True)
    marker_path = accelerator_root / "component.json"
    write_json(marker_path, {"id": "nvidia-cuda12", "version": "12.4", "root": str(accelerator_root)})
    monkeypatch.setattr(
        "transvortex.app.asr_operations.subprocess.run",
        lambda *_args, **_kwargs: SimpleNamespace(
            stdout='{"ok": true, "cuda": {"available": true, "compute_types": ["float16"]}}\n',
            stderr="",
            returncode=0,
        ),
    )

    result = manager.probe_hardware()

    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    assert result["cuda"]["available"] is True
    assert marker["hardware_probe"]["cuda"]["available"] is True
    assert marker["hardware_probe"]["checked_at"]


def test_environment_discovery_uses_registered_locations_without_executing_python(
    tmp_path: Path,
    monkeypatch,
) -> None:
    python = tmp_path / "python.exe"
    python.write_bytes(b"not executable")
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setattr("transvortex.app.asr_runtime.shutil.which", lambda _name: None)

    candidates = discover_python_environments()

    assert candidates == [
        {
            "id": candidates[0]["id"],
            "python_executable": str(python.resolve()),
            "source": "path",
        }
    ]


def test_environment_probe_returns_structured_failure_for_missing_runtime(tmp_path: Path) -> None:
    missing = probe_python_environment(tmp_path / "missing-python.exe")

    assert missing["ok"] is False
    assert missing["code"] == "environment_missing"


def test_external_environment_readiness_requires_matching_host_protocol(tmp_path: Path, monkeypatch) -> None:
    catalog_path = tmp_path / "catalog.json"
    write_json(catalog_path, _catalog())
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))
    python = tmp_path / "python.exe"
    python.write_bytes(b"")
    model = tmp_path / "external-model"
    model.mkdir()
    environment = save_external_environment(
        root_dir=tmp_path,
        python_executable=python,
        probe={
            "ok": True,
            "protocol_version": 1,
            "cuda": {"available": False, "compute_types": []},
            "model_paths": {"small": str(model)},
        },
    )
    provider = AsrProviderConfig(
        name="external_whisper",
        kind="local_worker",
        protocol="faster_whisper",
        model="small",
        runtime=AsrRuntimeConfig(source="external", id=environment["id"]),
        local=AsrLocalConfig(device="cpu", compute_type="auto"),
    )

    assert asr_provider_readiness(provider, root_dir=tmp_path)["can_run"] is True

    save_external_environment(
        root_dir=tmp_path,
        python_executable=python,
        probe={
            "ok": True,
            "protocol_version": 99,
            "cuda": {"available": False, "compute_types": []},
            "model_paths": {"small": str(model)},
        },
    )
    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "environment_protocol_incompatible"


def test_managed_runtime_registers_and_resolves_external_model(tmp_path: Path, monkeypatch) -> None:
    config_bytes = b'{"model_type":"whisper"}'
    catalog = _catalog()
    catalog["models"][0]["files"].append(
        {
            "path": "config.json",
            "size": len(config_bytes),
            "sha256": hashlib.sha256(config_bytes).hexdigest(),
        }
    )
    catalog_path = tmp_path / "catalog.json"
    write_json(catalog_path, catalog)
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))
    paths = asr_runtime_paths(tmp_path)
    runtime_root = paths.components_root / "faster-whisper" / "1.0.0"
    runtime_root.mkdir(parents=True)
    (runtime_root / "python.exe").write_bytes(b"")
    write_json(
        runtime_root / "component.json",
        {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "python": "python.exe",
            "protocol_version": 1,
        },
    )
    model_root = tmp_path / "existing-small"
    model_root.mkdir()
    (model_root / "config.json").write_bytes(config_bytes)
    (model_root / "model.bin").write_bytes(b"existing-model")
    monkeypatch.setattr(
        "transvortex.app.asr_runtime.probe_python_environment",
        lambda *_args, **_kwargs: {
            "ok": True,
            "protocol_version": 1,
            "model": {"loaded": True},
            "transcription": {"ok": True},
        },
    )

    result = probe_managed_model(root_dir=tmp_path, model_path=model_root, device="cpu")
    provider = AsrProviderConfig(
        name="whisper",
        kind="local_worker",
        protocol="faster_whisper",
        model="small",
        runtime=AsrRuntimeConfig(source="managed", id="managed:faster-whisper"),
        local=AsrLocalConfig(
            model_size="small",
            model_source="external",
            model_path=str(model_root),
            device="cpu",
        ),
    )

    assert result["ok"] is True
    assert result["model"]["model_id"] == "small"
    assert asr_provider_readiness(provider, root_dir=tmp_path)["can_run"] is True
    runtime = resolve_whisper_runtime(provider, root_dir=tmp_path)
    assert runtime["python_executable"] == str(runtime_root / "python.exe")
    assert runtime["model_path"] == str(model_root.resolve())

    (model_root / "model.bin").write_bytes(b"changed-model")
    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "model_changed"

    state = load_asr_runtime_state(paths)
    state["models"][result["model"]["id"]]["probe"] = "invalid"
    save_asr_runtime_state(paths, state)
    assert asr_provider_readiness(provider, root_dir=tmp_path)["code"] == "model_unverified"


def test_media_inspection_only_requires_asr_when_video_has_no_selected_subtitle(
    tmp_path: Path,
    monkeypatch,
) -> None:
    video = tmp_path / "demo.mkv"
    video.write_bytes(b"media")
    streams = [
        {
            "index": 2,
            "codec_name": "subrip",
            "language": "ja",
            "title": "Japanese",
            "default": True,
            "forced": False,
            "supported": True,
        }
    ]
    monkeypatch.setattr("transvortex.app.media_inspect.list_subtitle_streams", lambda _path: streams)

    embedded = inspect_media_source(video, source_lang="ja")
    no_match = inspect_media_source(video, source_lang="en")
    forced_asr = inspect_media_source(video, source_lang="ja", source_mode="asr")
    subtitle = inspect_media_source(tmp_path / "input.srt")
    audio = inspect_media_source(tmp_path / "input.wav")

    assert embedded["needs_asr"] is False
    assert embedded["selected_subtitle_stream"]["index"] == 2
    assert no_match["needs_asr"] is True
    assert forced_asr["needs_asr"] is True
    assert subtitle["needs_asr"] is False
    assert audio["needs_asr"] is True
