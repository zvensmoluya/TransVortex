from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.parse
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable

import httpx

from ..http import build_httpx_client
from ..utils import FileLock, read_json, utc_now_iso, write_json
from .models import NetworkConfig
from .asr_runtime import (
    AsrRuntimePaths,
    ASR_STORAGE_CONFIG_VERSION,
    asr_storage_content_blocker,
    asr_storage_status,
    asr_runtime_paths,
    load_asr_catalog,
    managed_model_path,
    model_catalog_entry,
    required_asr_disk_bytes,
    whisper_host_script,
)


ACTIVE_OPERATION_STATES = {"queued", "running", "cancelling"}
DOWNLOAD_CHUNK_SIZE = 1024 * 1024
DOWNLOAD_ATTEMPTS = 3
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 16 * 1024 * 1024 * 1024
DIRECTORY_SWAP_ATTEMPTS = 20
DIRECTORY_SWAP_MAX_RETRY_SECONDS = 1.0


class AsrOperationError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class _OperationCancelled(RuntimeError):
    pass


class AsrOperationManager:
    def __init__(
        self,
        *,
        root_dir: Path,
        app_data_root: Path | None = None,
        catalog: dict[str, Any] | None = None,
        client_factory: Callable[[], httpx.Client] | None = None,
        network: NetworkConfig | None = None,
    ) -> None:
        self.root_dir = Path(root_dir).resolve()
        self.paths = asr_runtime_paths(self.root_dir, app_data_root=app_data_root)
        self.catalog = catalog or load_asr_catalog()
        self.network = network or NetworkConfig()
        self._client_factory = client_factory or self._default_client
        self._lock = threading.RLock()
        self._cancel_events: dict[str, threading.Event] = {}
        self._threads: dict[str, threading.Thread] = {}
        self._recover_install_backups()
        self._reconcile_interrupted_operations()

    def start_install(self, kind: str, item_id: str = "") -> dict[str, Any]:
        self._ensure_storage_ready()
        normalized_kind = kind.strip().lower()
        entry = self._catalog_entry(normalized_kind, item_id)
        target_id = str(entry.get("id") or item_id)
        with self._lock:
            active = self._find_any_active()
            if active is not None:
                if active.get("kind") == normalized_kind and active.get("item_id") == target_id:
                    return active
                raise AsrOperationError(
                    "operation_active",
                    "Another ASR setup task is already running; wait for it to finish or cancel it first",
                )
            operation_id = f"asr_{uuid.uuid4().hex}"
            total = self._entry_download_size(normalized_kind, entry)
            self._check_disk_space(total)
            now = utc_now_iso()
            operation = {
                "id": operation_id,
                "kind": normalized_kind,
                "item_id": target_id,
                "state": "queued",
                "bytes_done": 0,
                "bytes_total": total,
                "current_file": "",
                "error_code": "",
                "message": "",
                "created_at": now,
                "updated_at": now,
                "result": {},
                "owner_pid": os.getpid(),
            }
            self._save_operation(operation)
            cancel_event = threading.Event()
            thread = threading.Thread(
                target=self._run_install,
                args=(operation_id, normalized_kind, entry, cancel_event),
                name=f"transvortex-{normalized_kind}-installer",
                daemon=True,
            )
            self._cancel_events[operation_id] = cancel_event
            self._threads[operation_id] = thread
            thread.start()
            return operation

    def start_setup(self, model_id: str) -> dict[str, Any]:
        self._ensure_storage_ready()
        normalized_model_id = model_id.strip()
        runtime = self._catalog_entry("runtime", "")
        model = self._catalog_entry("model", normalized_model_id)
        target_id = str(model.get("id") or normalized_model_id)
        with self._lock:
            active = self._find_any_active()
            if active is not None:
                if active.get("kind") == "setup" and active.get("item_id") == target_id:
                    return active
                raise AsrOperationError(
                    "operation_active",
                    "Another ASR setup task is already running; wait for it to finish or cancel it first",
                )
            runtime_total = self._entry_download_size("runtime", runtime)
            model_total = self._entry_download_size("model", model)
            total = runtime_total + model_total
            self._check_disk_space(total)
            operation_id = f"asr_{uuid.uuid4().hex}"
            now = utc_now_iso()
            operation = {
                "id": operation_id,
                "kind": "setup",
                "item_id": target_id,
                "state": "queued",
                "phase": "runtime",
                "phase_index": 0,
                "phase_count": 3,
                "bytes_done": 0,
                "bytes_total": total,
                "current_file": "",
                "error_code": "",
                "message": "",
                "created_at": now,
                "updated_at": now,
                "result": {},
                "owner_pid": os.getpid(),
            }
            self._save_operation(operation)
            cancel_event = threading.Event()
            thread = threading.Thread(
                target=self._run_setup,
                args=(operation_id, runtime, model, runtime_total, cancel_event),
                name="transvortex-asr-setup",
                daemon=True,
            )
            self._cancel_events[operation_id] = cancel_event
            self._threads[operation_id] = thread
            thread.start()
            return operation

    def operation(self, operation_id: str) -> dict[str, Any]:
        with self._lock:
            path = self._operation_path(operation_id)
            if not path.is_file():
                raise AsrOperationError("operation_not_found", f"ASR operation not found: {operation_id}")
            payload = read_json(path)
            return payload if isinstance(payload, dict) else {}

    def operations(self) -> list[dict[str, Any]]:
        with self._lock:
            if not self.paths.operations_root.is_dir():
                return []
            rows: list[dict[str, Any]] = []
            for path in self.paths.operations_root.glob("*.json"):
                try:
                    payload = read_json(path)
                except (OSError, ValueError):
                    continue
                if isinstance(payload, dict):
                    rows.append(payload)
            return sorted(rows, key=lambda row: str(row.get("created_at") or ""), reverse=True)

    def cancel(self, operation_id: str) -> dict[str, Any]:
        with self._lock:
            operation = self.operation(operation_id)
            if operation.get("state") not in ACTIVE_OPERATION_STATES:
                return operation
            event = self._cancel_events.get(operation_id)
            if event is None:
                return self._finish(
                    operation_id,
                    "failed",
                    error_code="operation_interrupted",
                    message="The installer process is no longer running",
                )
            event.set()
            return self._update(operation_id, state="cancelling", message="Cancellation requested")

    def cancel_all(self, *, wait_seconds: float = 0.0) -> None:
        with self._lock:
            for event in self._cancel_events.values():
                event.set()
            threads = list(self._threads.values())
        if wait_seconds <= 0:
            return
        deadline = time.monotonic() + wait_seconds
        for thread in threads:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            thread.join(remaining)

    def probe_hardware(self) -> dict[str, Any]:
        result = self._probe_and_record_hardware()
        if result is None:
            raise AsrOperationError(
                "hardware_probe_unavailable",
                "Install the managed Whisper runtime and NVIDIA accelerator before testing hardware",
            )
        return result

    def storage_status(self) -> dict[str, Any]:
        with self._lock:
            return asr_storage_status(self.paths, operations=self.operations())

    def set_storage_root(self, storage_root: str) -> dict[str, Any]:
        raw = storage_root.strip()
        candidate = Path(raw).expanduser()
        if not raw or not candidate.is_absolute():
            raise AsrOperationError("invalid_storage_root", "ASR storage root must be an absolute directory")
        candidate = candidate.resolve()
        if candidate == candidate.parent:
            raise AsrOperationError(
                "invalid_storage_root",
                "Choose a dedicated folder instead of the root of a drive",
            )
        with self._lock:
            if self._find_any_active() is not None:
                raise AsrOperationError(
                    "operation_active",
                    "Wait for the active ASR task to finish before changing its storage location",
                )
            if candidate == self.paths.storage_root:
                return self.storage_status()
            current_blocker = asr_storage_content_blocker(self.paths)
            if current_blocker:
                raise AsrOperationError(
                    "storage_change_requires_migration",
                    "The current ASR storage contains managed resources or partial downloads",
                )
            for managed_root in (
                self.paths.components_root,
                self.paths.models_root,
                self.paths.downloads_root,
            ):
                resolved = managed_root.resolve()
                if candidate == resolved or resolved in candidate.parents:
                    raise AsrOperationError(
                        "invalid_storage_root",
                        "The new ASR storage folder cannot be inside a managed resource directory",
                    )
            target_paths = asr_runtime_paths(
                self.root_dir,
                app_data_root=self.paths.app_data_root,
                storage_root=candidate,
            )
            if asr_storage_content_blocker(target_paths):
                raise AsrOperationError(
                    "storage_target_has_managed_data",
                    "The selected folder already contains managed ASR data",
                )
            try:
                candidate.mkdir(parents=True, exist_ok=True)
                probe = candidate / f".transvortex-write-probe-{uuid.uuid4().hex}"
                with probe.open("xb") as handle:
                    handle.write(b"ok")
                probe.unlink()
                self.paths.config_root.mkdir(parents=True, exist_ok=True)
                if candidate == self.paths.app_data_root:
                    if self.paths.storage_config_file.exists():
                        self.paths.storage_config_file.unlink()
                else:
                    write_json(
                        self.paths.storage_config_file,
                        {
                            "schema_version": ASR_STORAGE_CONFIG_VERSION,
                            "storage_root": str(candidate),
                        },
                    )
            except OSError as exc:
                raise AsrOperationError(
                    "storage_root_unwritable",
                    f"Cannot use the selected ASR storage folder: {exc}",
                ) from exc
            self.paths = asr_runtime_paths(
                self.root_dir,
                app_data_root=self.paths.app_data_root,
            )
            return self.storage_status()

    def remove(self, kind: str, item_id: str = "") -> dict[str, Any]:
        self._ensure_storage_ready()
        normalized_kind = kind.strip().lower()
        entry = self._catalog_entry(normalized_kind, item_id)
        target_id = str(entry.get("id") or item_id)
        with self._lock:
            if self._find_any_active() is not None:
                raise AsrOperationError("operation_active", "Cannot remove an ASR component while it is changing")
            target = self._install_target(normalized_kind, entry)
            self._assert_managed_target(target)
            if target.exists():
                shutil.rmtree(target)
            return {"ok": True, "kind": normalized_kind, "item_id": target_id, "removed": True}

    def _run_install(
        self,
        operation_id: str,
        kind: str,
        entry: dict[str, Any],
        cancel_event: threading.Event,
    ) -> None:
        try:
            self._update(operation_id, state="running", message="")
            with FileLock(self.paths.downloads_root / ".component-install.lock"):
                self._check_cancelled(cancel_event)
                result = self._installed_result(kind, entry, cancel_event)
                if result is None:
                    if kind == "model":
                        result = self._install_model(operation_id, entry, cancel_event)
                    else:
                        result = self._install_archive(operation_id, kind, entry, cancel_event)
            self._finish(operation_id, "completed", result=result)
        except _OperationCancelled:
            self._finish(operation_id, "cancelled", error_code="cancelled", message="Download cancelled")
        except AsrOperationError as exc:
            self._finish(operation_id, "failed", error_code=exc.code, message=str(exc))
        except Exception as exc:  # noqa: BLE001 - background operation must persist a terminal state
            self._finish(operation_id, "failed", error_code="install_failed", message=str(exc))
        finally:
            with self._lock:
                self._cancel_events.pop(operation_id, None)
                self._threads.pop(operation_id, None)

    def _run_setup(
        self,
        operation_id: str,
        runtime: dict[str, Any],
        model: dict[str, Any],
        runtime_total: int,
        cancel_event: threading.Event,
    ) -> None:
        try:
            self._update(
                operation_id,
                state="running",
                phase="runtime",
                phase_index=0,
                message="",
            )
            with FileLock(self.paths.downloads_root / ".component-install.lock"):
                self._check_cancelled(cancel_event)
                runtime_result = self._installed_result("runtime", runtime, cancel_event)
                if runtime_result is None:
                    runtime_result = self._install_archive(
                        operation_id,
                        "runtime",
                        runtime,
                        cancel_event,
                    )
                self._progress(operation_id, runtime_total, "")
                self._update(operation_id, phase="model", phase_index=1, current_file="")
                self._check_cancelled(cancel_event)
                model_result = self._installed_result("model", model, cancel_event)
                if model_result is None:
                    model_result = self._install_model(
                        operation_id,
                        model,
                        cancel_event,
                        progress_base=runtime_total,
                    )
                self._update(
                    operation_id,
                    phase="activate",
                    phase_index=2,
                    bytes_done=int(self.operation(operation_id).get("bytes_total") or 0),
                    current_file="",
                )
            self._finish(
                operation_id,
                "completed",
                result={"runtime": runtime_result, "model": model_result},
            )
        except _OperationCancelled:
            self._finish(
                operation_id,
                "cancelled",
                error_code="cancelled",
                message="Setup cancelled; verified partial data was kept for retry",
            )
        except AsrOperationError as exc:
            self._finish(operation_id, "failed", error_code=exc.code, message=str(exc))
        except Exception as exc:  # noqa: BLE001 - background operation must persist a terminal state
            self._finish(operation_id, "failed", error_code="install_failed", message=str(exc))
        finally:
            with self._lock:
                self._cancel_events.pop(operation_id, None)
                self._threads.pop(operation_id, None)

    def _install_model(
        self,
        operation_id: str,
        model: dict[str, Any],
        cancel_event: threading.Event,
        *,
        progress_base: int = 0,
    ) -> dict[str, Any]:
        target = managed_model_path(self.paths, model)
        staging = target.parent / f".{target.name}.installing"
        self._assert_managed_target(target)
        self._assert_managed_target(staging)
        staging.mkdir(parents=True, exist_ok=True)
        completed = 0
        repository = str(model.get("repository") or "")
        revision = str(model.get("revision") or "")
        if not repository or not revision:
            raise AsrOperationError("invalid_catalog", "Model repository or revision is missing")
        for file_entry in model.get("files") or []:
            self._check_cancelled(cancel_event)
            if not isinstance(file_entry, dict):
                continue
            relative = self._safe_relative_path(str(file_entry.get("path") or ""))
            expected_size = int(file_entry.get("size") or 0)
            expected_sha = self._expected_sha256(file_entry)
            staged_file = staging.joinpath(*relative.parts)
            if self._file_valid(staged_file, expected_size, expected_sha, cancel_event=cancel_event):
                completed += expected_size
                self._progress(operation_id, progress_base + completed, str(relative))
                continue
            if staged_file.exists():
                staged_file.unlink()
            cache_file = self.paths.downloads_root / "models" / str(model["id"]) / revision / relative
            part_file = cache_file.with_name(cache_file.name + ".part")
            self._assert_download_target(part_file)
            self._assert_managed_target(staged_file)
            url = self._model_file_url(repository, revision, relative)
            self._download_verified(
                url=url,
                destination=part_file,
                expected_size=expected_size,
                expected_sha256=expected_sha,
                cancel_event=cancel_event,
                progress=lambda current, label=str(relative), base=progress_base + completed: self._progress(
                    operation_id, base + current, label
                ),
            )
            staged_file.parent.mkdir(parents=True, exist_ok=True)
            os.replace(part_file, staged_file)
            completed += expected_size
            self._progress(operation_id, progress_base + completed, str(relative))
        marker = {
            "id": model.get("id"),
            "revision": revision,
            "repository": repository,
            "installed_at": utc_now_iso(),
        }
        write_json(staging / "model.json", marker)
        self._replace_directory(staging, target)
        return {"path": str(target), "model": model.get("id"), "revision": revision}

    def _install_archive(
        self,
        operation_id: str,
        kind: str,
        entry: dict[str, Any],
        cancel_event: threading.Event,
        *,
        progress_base: int = 0,
    ) -> dict[str, Any]:
        artifact = entry.get("artifact") if isinstance(entry.get("artifact"), dict) else {}
        if artifact.get("published") is not True:
            raise AsrOperationError("component_unpublished", "This ASR component has not been published yet")
        url = self._trusted_https_url(str(artifact.get("url") or ""))
        expected_size = int(artifact.get("size") or 0)
        expected_sha = self._expected_sha256(artifact)
        filename = Path(urllib.parse.urlparse(url).path).name or f"{kind}.zip"
        if not filename.lower().endswith(".zip"):
            raise AsrOperationError("unsupported_archive", "ASR component artifact must be a ZIP archive")
        part_file = self.paths.downloads_root / "artifacts" / f"{filename}.part"
        self._assert_download_target(part_file)
        self._download_verified(
            url=url,
            destination=part_file,
            expected_size=expected_size,
            expected_sha256=expected_sha,
            cancel_event=cancel_event,
            progress=lambda current: self._progress(operation_id, progress_base + current, filename),
        )
        target = self._install_target(kind, entry)
        staging = target.parent / f".{target.name}.installing"
        self._assert_managed_target(target)
        self._assert_managed_target(staging)
        if staging.exists():
            self._assert_managed_target(staging)
            shutil.rmtree(staging)
        staging.mkdir(parents=True, exist_ok=True)
        self._safe_extract_zip(part_file, staging, cancel_event)
        if kind == "runtime":
            python_name = str(entry.get("python") or "python.exe")
            if not (staging / python_name).is_file():
                raise AsrOperationError("invalid_component", f"Runtime archive does not contain {python_name}")
            marker = {
                "id": entry.get("id"),
                "version": entry.get("version"),
                "python": python_name,
                "protocol_version": entry.get("protocol_version"),
                "artifact_sha256": str((entry.get("artifact") or {}).get("sha256") or "").lower(),
                "installed_at": utc_now_iso(),
            }
        else:
            marker = {
                "id": entry.get("id"),
                "version": entry.get("version"),
                "artifact_sha256": str((entry.get("artifact") or {}).get("sha256") or "").lower(),
                "installed_at": utc_now_iso(),
            }
        write_json(staging / "component.json", marker)
        self._replace_directory(staging, target)
        if kind == "accelerator":
            marker["root"] = str(target)
            write_json(target / "component.json", marker)
        hardware_probe = self._probe_and_record_hardware()
        try:
            part_file.unlink()
        except OSError:
            pass
        return {
            "path": str(target),
            "kind": kind,
            "item_id": entry.get("id"),
            "hardware_probe": hardware_probe or {},
        }

    def _probe_and_record_hardware(self) -> dict[str, Any] | None:
        runtime = self.catalog.get("runtime") if isinstance(self.catalog.get("runtime"), dict) else {}
        runtime_root = self._install_target("runtime", runtime)
        runtime_marker_path = runtime_root / "component.json"
        if not runtime_marker_path.is_file():
            return None
        runtime_marker = read_json(runtime_marker_path)
        if not isinstance(runtime_marker, dict):
            return None
        python_executable = runtime_root / str(runtime_marker.get("python") or "python.exe")
        accelerator = next(
            (row for row in self.catalog.get("accelerators") or [] if isinstance(row, dict)),
            None,
        )
        if accelerator is None:
            return None
        accelerator_root = self._install_target("accelerator", accelerator)
        accelerator_marker_path = accelerator_root / "component.json"
        if not python_executable.is_file() or not accelerator_marker_path.is_file():
            return None
        command = [
            str(python_executable),
            "-u",
            str(whisper_host_script()),
            "--probe",
            "--accelerator-root",
            str(accelerator_root),
        ]
        creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=60,
                check=False,
                creationflags=creationflags,
                env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"},
            )
            lines = [line for line in completed.stdout.splitlines() if line.strip()]
            payload = json.loads(lines[-1]) if lines else {}
            if not isinstance(payload, dict):
                payload = {}
            if not payload:
                payload = {
                    "ok": False,
                    "code": "hardware_probe_failed",
                    "message": completed.stderr.strip() or f"Probe exited with code {completed.returncode}",
                }
        except Exception as exc:  # noqa: BLE001 - hardware probe result is persisted as a diagnostic
            payload = {"ok": False, "code": "hardware_probe_failed", "message": str(exc)}
        payload["checked_at"] = utc_now_iso()
        accelerator_marker = read_json(accelerator_marker_path)
        if not isinstance(accelerator_marker, dict):
            accelerator_marker = {
                "id": accelerator.get("id"),
                "version": accelerator.get("version"),
                "root": str(accelerator_root),
            }
        accelerator_marker["hardware_probe"] = payload
        write_json(accelerator_marker_path, accelerator_marker)
        return payload

    def _download_verified(
        self,
        *,
        url: str,
        destination: Path,
        expected_size: int,
        expected_sha256: str,
        cancel_event: threading.Event,
        progress: Callable[[int], None],
    ) -> None:
        trusted_url = self._trusted_https_url(url)
        self._check_cancelled(cancel_event)
        if self._file_valid(
            destination,
            expected_size,
            expected_sha256,
            cancel_event=cancel_event,
        ):
            progress(expected_size)
            return
        destination.parent.mkdir(parents=True, exist_ok=True)
        last_error: Exception | None = None
        for attempt in range(DOWNLOAD_ATTEMPTS):
            self._check_cancelled(cancel_event)
            try:
                self._download_once(
                    trusted_url,
                    destination,
                    expected_size,
                    cancel_event,
                    progress,
                )
                if not self._file_valid(
                    destination,
                    expected_size,
                    expected_sha256,
                    cancel_event=cancel_event,
                ):
                    destination.unlink(missing_ok=True)
                    raise AsrOperationError("checksum_mismatch", "Downloaded file did not match the trusted manifest")
                return
            except _OperationCancelled:
                raise
            except Exception as exc:  # noqa: BLE001 - retry preserves partial downloads
                last_error = exc
                if attempt + 1 < DOWNLOAD_ATTEMPTS:
                    time.sleep(0.25 * (attempt + 1))
        if isinstance(last_error, AsrOperationError):
            raise last_error
        raise AsrOperationError("download_failed", str(last_error or "Download failed"))

    def _download_once(
        self,
        url: str,
        destination: Path,
        expected_size: int,
        cancel_event: threading.Event,
        progress: Callable[[int], None],
    ) -> None:
        offset = destination.stat().st_size if destination.is_file() else 0
        if offset > expected_size:
            destination.unlink()
            offset = 0
        headers = {"Range": f"bytes={offset}-"} if offset else {}
        with self._client_factory() as client:
            with client.stream("GET", url, headers=headers) as response:
                self._trusted_https_url(str(response.url))
                if response.status_code == 416 and offset == expected_size:
                    progress(offset)
                    return
                response.raise_for_status()
                resumed = offset > 0 and response.status_code == 206
                if offset and not resumed:
                    offset = 0
                mode = "ab" if resumed else "wb"
                current = offset
                progress(current)
                with destination.open(mode) as handle:
                    for chunk in response.iter_bytes(DOWNLOAD_CHUNK_SIZE):
                        self._check_cancelled(cancel_event)
                        if not chunk:
                            continue
                        handle.write(chunk)
                        current += len(chunk)
                        if current > expected_size:
                            raise AsrOperationError("download_size_mismatch", "Download exceeded the trusted size")
                        progress(current)
        if destination.stat().st_size != expected_size:
            raise AsrOperationError(
                "download_incomplete",
                f"Expected {expected_size} bytes but received {destination.stat().st_size}",
            )

    def _safe_extract_zip(self, archive: Path, destination: Path, cancel_event: threading.Event) -> None:
        with zipfile.ZipFile(archive) as bundle:
            infos = bundle.infolist()
            total = sum(max(info.file_size, 0) for info in infos)
            if total > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                raise AsrOperationError("archive_too_large", "ASR component archive expands beyond the safety limit")
            destination_root = destination.resolve()
            for info in infos:
                self._check_cancelled(cancel_event)
                unix_mode = (info.external_attr >> 16) & 0xFFFF
                if (unix_mode & 0o170000) == 0o120000:
                    raise AsrOperationError("unsafe_archive", "ASR component archive contains a symbolic link")
                relative = self._safe_relative_path(info.filename)
                target = destination.joinpath(*relative.parts)
                resolved = target.resolve()
                if resolved != destination_root and destination_root not in resolved.parents:
                    raise AsrOperationError("unsafe_archive", "ASR component archive escapes its destination")
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as source, target.open("wb") as output:
                    while True:
                        self._check_cancelled(cancel_event)
                        chunk = source.read(DOWNLOAD_CHUNK_SIZE)
                        if not chunk:
                            break
                        output.write(chunk)

    def _replace_directory(self, staging: Path, target: Path) -> None:
        self._assert_managed_target(staging)
        self._assert_managed_target(target)
        backup = target.parent / f".{target.name}.previous"
        self._assert_managed_target(backup)
        if backup.exists():
            self._remove_directory_with_retry(backup)
        if target.exists():
            self._replace_path(target, backup)
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._replace_path(staging, target)
        except Exception:
            if backup.exists() and not target.exists():
                self._replace_path(backup, target)
            raise
        if backup.exists():
            try:
                self._remove_directory_with_retry(backup)
            except OSError:
                # The new target is already active. Leave the old backup for the
                # next startup recovery rather than reporting a false install failure.
                pass

    def _remove_directory_with_retry(self, path: Path) -> None:
        for attempt in range(DIRECTORY_SWAP_ATTEMPTS):
            try:
                shutil.rmtree(path)
                return
            except FileNotFoundError:
                return
            except OSError as exc:
                winerror = getattr(exc, "winerror", None)
                retryable = isinstance(exc, PermissionError) or winerror in {5, 32, 33}
                if not retryable or attempt + 1 >= DIRECTORY_SWAP_ATTEMPTS:
                    raise
                time.sleep(min(0.1 * (attempt + 1), DIRECTORY_SWAP_MAX_RETRY_SECONDS))

    @staticmethod
    def _replace_path(source: Path, target: Path) -> None:
        for attempt in range(DIRECTORY_SWAP_ATTEMPTS):
            try:
                os.replace(source, target)
                return
            except OSError as exc:
                winerror = getattr(exc, "winerror", None)
                retryable = isinstance(exc, PermissionError) or winerror in {5, 32, 33}
                if not retryable or attempt + 1 >= DIRECTORY_SWAP_ATTEMPTS:
                    raise
                time.sleep(min(0.1 * (attempt + 1), DIRECTORY_SWAP_MAX_RETRY_SECONDS))

    def _recover_install_backups(self) -> None:
        entries: list[tuple[str, dict[str, Any]]] = []
        runtime = self.catalog.get("runtime")
        if isinstance(runtime, dict):
            entries.append(("runtime", runtime))
        entries.extend(
            ("accelerator", row)
            for row in self.catalog.get("accelerators") or []
            if isinstance(row, dict)
        )
        entries.extend(
            ("model", row)
            for row in self.catalog.get("models") or []
            if isinstance(row, dict)
        )
        for kind, entry in entries:
            target = self._install_target(kind, entry)
            backup = target.parent / f".{target.name}.previous"
            if not backup.exists():
                continue
            self._assert_managed_target(backup)
            if target.exists():
                try:
                    self._remove_directory_with_retry(backup)
                except OSError:
                    # Keep startup usable; a later initialization can retry cleanup.
                    continue
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                self._replace_path(backup, target)

    def _installed_result(
        self,
        kind: str,
        entry: dict[str, Any],
        cancel_event: threading.Event,
    ) -> dict[str, Any] | None:
        target = self._install_target(kind, entry)
        self._assert_managed_target(target)
        marker_path = target / ("model.json" if kind == "model" else "component.json")
        if not marker_path.is_file():
            return None
        try:
            marker = read_json(marker_path)
        except (OSError, ValueError):
            return None
        if not isinstance(marker, dict):
            return None
        if kind == "model":
            if marker.get("id") != entry.get("id") or marker.get("revision") != entry.get("revision"):
                return None
            for file_entry in entry.get("files") or []:
                if not isinstance(file_entry, dict):
                    continue
                relative = self._safe_relative_path(str(file_entry.get("path") or ""))
                if not self._file_valid(
                    target.joinpath(*relative.parts),
                    int(file_entry.get("size") or 0),
                    self._expected_sha256(file_entry),
                    cancel_event=cancel_event,
                ):
                    return None
            return {"path": str(target), "model": entry.get("id"), "revision": entry.get("revision")}
        if marker.get("id") != entry.get("id") or marker.get("version") != entry.get("version"):
            return None
        if kind == "runtime" and not (target / str(marker.get("python") or "python.exe")).is_file():
            return None
        return {"path": str(target), "kind": kind, "item_id": entry.get("id"), "already_installed": True}

    def _catalog_entry(self, kind: str, item_id: str) -> dict[str, Any]:
        if kind == "runtime":
            entry = self.catalog.get("runtime")
        elif kind == "accelerator":
            entry = next(
                (
                    row
                    for row in self.catalog.get("accelerators") or []
                    if isinstance(row, dict) and row.get("id") == item_id
                ),
                None,
            )
        elif kind == "model":
            entry = model_catalog_entry(self.catalog, item_id)
        else:
            raise AsrOperationError("unsupported_component_kind", f"Unsupported ASR component kind: {kind}")
        if not isinstance(entry, dict):
            raise AsrOperationError("component_not_found", f"ASR {kind} not found: {item_id}")
        return entry

    def _install_target(self, kind: str, entry: dict[str, Any]) -> Path:
        if kind == "runtime":
            return self.paths.components_root / "faster-whisper" / str(entry.get("version") or "")
        if kind == "accelerator":
            return (
                self.paths.components_root
                / "accelerators"
                / str(entry.get("id") or "")
                / str(entry.get("version") or "")
            )
        return managed_model_path(self.paths, entry)

    def _entry_download_size(self, kind: str, entry: dict[str, Any]) -> int:
        if kind == "model":
            total = sum(int(row.get("size") or 0) for row in entry.get("files") or [] if isinstance(row, dict))
        else:
            artifact = entry.get("artifact") if isinstance(entry.get("artifact"), dict) else {}
            if artifact.get("published") is not True:
                raise AsrOperationError("component_unpublished", "This ASR component has not been published yet")
            total = int(artifact.get("size") or 0)
        if total <= 0:
            raise AsrOperationError("invalid_catalog", "ASR component has no trusted download size")
        return total

    def _check_disk_space(self, download_size: int) -> None:
        try:
            self.paths.storage_root.mkdir(parents=True, exist_ok=True)
            available = shutil.disk_usage(self.paths.storage_root).free
        except OSError as exc:
            raise AsrOperationError(
                "storage_root_unavailable",
                f"ASR storage folder is unavailable: {exc}",
            ) from exc
        required = required_asr_disk_bytes(download_size)
        if available < required:
            raise AsrOperationError(
                "insufficient_disk_space",
                f"ASR installation needs {required} bytes free but only {available} bytes are available",
            )

    def _ensure_storage_ready(self) -> None:
        if self.paths.storage_config_error:
            raise AsrOperationError("storage_config_invalid", self.paths.storage_config_error)

    def _find_active(self, kind: str, item_id: str) -> dict[str, Any] | None:
        return next(
            (
                row
                for row in self.operations()
                if row.get("kind") == kind
                and row.get("item_id") == item_id
                and row.get("state") in ACTIVE_OPERATION_STATES
            ),
            None,
        )

    def _find_any_active(self) -> dict[str, Any] | None:
        return next(
            (row for row in self.operations() if row.get("state") in ACTIVE_OPERATION_STATES),
            None,
        )

    def _progress(self, operation_id: str, bytes_done: int, current_file: str) -> None:
        self._update(operation_id, bytes_done=max(int(bytes_done), 0), current_file=current_file)

    def _update(self, operation_id: str, **changes: Any) -> dict[str, Any]:
        with self._lock:
            operation = self.operation(operation_id)
            operation.update(changes)
            operation["updated_at"] = utc_now_iso()
            self._save_operation(operation)
            return operation

    def _finish(
        self,
        operation_id: str,
        state: str,
        *,
        error_code: str = "",
        message: str = "",
        result: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        changes: dict[str, Any] = {
            "state": state,
            "error_code": error_code,
            "message": message,
            "current_file": "",
        }
        if result is not None:
            changes["result"] = result
        if state == "completed":
            operation = self.operation(operation_id)
            changes["bytes_done"] = int(operation.get("bytes_total") or operation.get("bytes_done") or 0)
        return self._update(operation_id, **changes)

    def _save_operation(self, operation: dict[str, Any]) -> None:
        write_json(self._operation_path(str(operation["id"])), operation)

    def _operation_path(self, operation_id: str) -> Path:
        normalized = operation_id.strip()
        if not normalized or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for char in normalized):
            raise AsrOperationError("invalid_operation_id", "Invalid ASR operation id")
        return self.paths.operations_root / f"{normalized}.json"

    def _reconcile_interrupted_operations(self) -> None:
        for operation in self.operations():
            if operation.get("state") not in ACTIVE_OPERATION_STATES:
                continue
            try:
                owner_pid = int(operation.get("owner_pid") or 0)
            except (TypeError, ValueError):
                owner_pid = 0
            if owner_pid > 0 and self._pid_exists(owner_pid):
                continue
            operation.update(
                {
                    "state": "failed",
                    "error_code": "operation_interrupted",
                    "message": "The previous installer process stopped before completion; retry can resume the download",
                    "updated_at": utc_now_iso(),
                }
            )
            self._save_operation(operation)

    def _assert_managed_target(self, path: Path) -> None:
        resolved = path.resolve()
        roots = (self.paths.components_root.resolve(), self.paths.models_root.resolve())
        matching_root = next(
            (root for root in roots if resolved == root or root in resolved.parents),
            None,
        )
        if matching_root is None:
            raise AsrOperationError("unsafe_path", f"Refusing to change unmanaged path: {resolved}")
        if self._has_reparse_component(path, matching_root):
            raise AsrOperationError("unsafe_path", f"Refusing a linked ASR path: {path}")

    def _assert_download_target(self, path: Path) -> None:
        resolved = path.resolve()
        root = self.paths.downloads_root.resolve()
        if resolved != root and root not in resolved.parents:
            raise AsrOperationError("unsafe_path", f"Refusing to write outside ASR downloads: {resolved}")
        if self._has_reparse_component(path, root):
            raise AsrOperationError("unsafe_path", f"Refusing a linked ASR download path: {path}")

    @staticmethod
    def _has_reparse_component(path: Path, stop_root: Path) -> bool:
        current = Path(os.path.abspath(os.fspath(path)))
        lexical_root = Path(os.path.abspath(os.fspath(stop_root)))
        is_junction = getattr(os.path, "isjunction", None)
        while True:
            if current.is_symlink() or bool(is_junction and is_junction(current)):
                return True
            if os.path.normcase(str(current)) == os.path.normcase(str(lexical_root)):
                return False
            parent = current.parent
            if parent == current:
                return False
            current = parent

    @staticmethod
    def _safe_relative_path(value: str) -> PurePosixPath:
        normalized = value.replace("\\", "/")
        relative = PurePosixPath(normalized)
        if not normalized or relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
            raise AsrOperationError("unsafe_path", f"Unsafe ASR component path: {value}")
        if ":" in relative.parts[0]:
            raise AsrOperationError("unsafe_path", f"Unsafe ASR component path: {value}")
        return relative

    @staticmethod
    def _expected_sha256(entry: dict[str, Any]) -> str:
        value = str(entry.get("sha256") or "").lower()
        if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise AsrOperationError("invalid_catalog", "ASR component is missing a valid SHA-256 digest")
        return value

    def _file_valid(
        self,
        path: Path,
        expected_size: int,
        expected_sha256: str,
        *,
        cancel_event: threading.Event | None = None,
    ) -> bool:
        if self._has_reparse_component(path, path.parent) or not path.is_file() or path.stat().st_size != expected_size:
            return False
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(DOWNLOAD_CHUNK_SIZE), b""):
                if cancel_event is not None and cancel_event.is_set():
                    raise _OperationCancelled()
                digest.update(chunk)
        return digest.hexdigest().lower() == expected_sha256

    @staticmethod
    def _model_file_url(repository: str, revision: str, relative: PurePosixPath) -> str:
        if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repository):
            raise AsrOperationError("invalid_catalog", f"Unsafe model repository: {repository}")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", revision):
            raise AsrOperationError("invalid_catalog", f"Unsafe model revision: {revision}")
        repository_path = "/".join(urllib.parse.quote(part, safe="") for part in repository.split("/") if part)
        revision_path = urllib.parse.quote(revision, safe="")
        file_path = "/".join(urllib.parse.quote(part, safe="") for part in relative.parts)
        return f"https://huggingface.co/{repository_path}/resolve/{revision_path}/{file_path}?download=true"

    @staticmethod
    def _trusted_https_url(value: str) -> str:
        parsed = urllib.parse.urlparse(value)
        if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise AsrOperationError("untrusted_download_url", "ASR downloads require an HTTPS URL without embedded credentials")
        return value

    @staticmethod
    def _check_cancelled(cancel_event: threading.Event) -> None:
        if cancel_event.is_set():
            raise _OperationCancelled()

    @staticmethod
    def _pid_exists(pid: int) -> bool:
        if pid <= 0:
            return False
        if pid == os.getpid():
            return True
        if os.name == "nt":
            try:
                import ctypes

                kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
                kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
                kernel32.OpenProcess.restype = ctypes.c_void_p
                kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
                kernel32.CloseHandle.restype = ctypes.c_int
                handle = kernel32.OpenProcess(0x1000, 0, pid)
                if not handle:
                    return False
                kernel32.CloseHandle(handle)
                return True
            except Exception:
                return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def set_network(self, network: NetworkConfig) -> None:
        self.network = network

    def _default_client(self) -> httpx.Client:
        return build_httpx_client(
            follow_redirects=True,
            timeout=httpx.Timeout(connect=20.0, read=60.0, write=30.0, pool=20.0),
            http2=False,
            network=self.network,
        )
