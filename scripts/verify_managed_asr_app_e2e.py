from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
ACCEPTANCE_ID = "TransVortex.ManagedAsrInstalledAppE2E"
STAGING_OWNER = "TransVortex.ManagedAsrE2EStaging"
STAGING_MARKER_NAME = ".transvortex-managed-asr-e2e-session.json"
TASK_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
EXPECTED_ASR_META = {
    "source": "asr",
    "provider": "faster_whisper_large_v3",
    "protocol": "faster_whisper",
    "runtime_source": "managed",
    "runtime_id": "managed:faster-whisper",
    "transport": "stdio_jsonl",
    "device": "cuda",
    "compute_type": "int8_float16",
}


@dataclass(frozen=True)
class VerificationInputs:
    stage_report: Path
    session_root: Path
    local_app_data: Path
    task_dir: Path
    installer: Path
    install_root: Path
    output_report: Path


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_datetime(value: Any, description: str) -> datetime:
    text = str(value or "").strip()
    if not text:
        raise ValueError(f"{description} is missing")
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


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
            return
        parent = current.parent
        if parent == current:
            raise ValueError(f"{description} escapes the owned staging session")
        current = parent


def _regular_file(path: Path, description: str) -> Path:
    lexical = Path(os.path.abspath(os.fspath(path.expanduser())))
    if _is_link_or_junction(lexical):
        raise FileNotFoundError(f"{description} must be a regular file: {lexical}")
    resolved = lexical.resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"{description} must be a regular file: {resolved}")
    return resolved


def _read_json_object(path: Path, description: str) -> dict[str, Any]:
    resolved = _regular_file(path, description)
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{description} is not valid UTF-8 JSON: {resolved}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{description} must contain one JSON object: {resolved}")
    return payload


def _required_mapping(payload: Mapping[str, Any], key: str, context: str) -> dict[str, Any]:
    value = payload.get(key)
    if not isinstance(value, dict):
        raise ValueError(f"{context}.{key} must be an object")
    return value


def _required_text(payload: Mapping[str, Any], key: str, context: str) -> str:
    value = str(payload.get(key) or "").strip()
    if not value:
        raise ValueError(f"{context}.{key} must be a non-empty string")
    return value


def _file_evidence(path: Path, description: str) -> dict[str, Any]:
    resolved = _regular_file(path, description)
    size = resolved.stat().st_size
    if size < 1:
        raise ValueError(f"{description} must not be empty: {resolved}")
    return {
        "path": str(resolved),
        "size": size,
        "sha256": _sha256(resolved),
        "last_write_at": datetime.fromtimestamp(
            resolved.stat().st_mtime,
            timezone.utc,
        ).isoformat(),
    }


def _load_inputs(
    *,
    stage_report: Path,
    task_id: str,
    installer: Path,
    install_root: Path,
    output_report: Path | None,
) -> VerificationInputs:
    stage_input = stage_report.expanduser()
    stage_path = _regular_file(stage_input, "Staging report")
    stage = _read_json_object(stage_path, "Staging report")
    if int(stage.get("schema_version") or 0) != SCHEMA_VERSION or stage.get("ok") is not True:
        raise ValueError("Staging report must describe a successful schema version 1 session")
    if stage.get("plan_only") is True or stage.get("side_effects_applied") is not True:
        raise ValueError("Staging report must describe an applied local staging session")

    session = _required_mapping(stage, "session", "stage")
    environment = _required_mapping(stage, "environment", "stage")
    session_root_input = Path(
        _required_text(session, "root", "stage.session")
    ).expanduser()
    session_root = session_root_input.resolve()
    _assert_unlinked_path_within(stage_input, session_root_input, "Staging report")
    declared_report = Path(
        _required_text(session, "report_path", "stage.session")
    ).expanduser().resolve()
    if not _same_path(stage_path, declared_report) or not _is_within(stage_path, session_root):
        raise ValueError("Staging report path is inconsistent with its owned session")
    if not session_root.is_dir() or _is_link_or_junction(session_root_input):
        raise FileNotFoundError(f"Owned staging session is unavailable: {session_root}")

    marker_input = session_root_input / STAGING_MARKER_NAME
    _assert_unlinked_path_within(marker_input, session_root_input, "Staging ownership marker")
    marker_path = marker_input.resolve()
    declared_marker = Path(
        _required_text(session, "ownership_marker", "stage.session")
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
        _required_text(environment, "LOCALAPPDATA", "stage.environment")
    ).expanduser()
    _assert_unlinked_path_within(
        local_app_data_input,
        session_root_input,
        "Isolated LOCALAPPDATA",
    )
    local_app_data = local_app_data_input.resolve()
    if not _same_path(local_app_data, session_root / "LocalAppData"):
        raise ValueError("stage.environment.LOCALAPPDATA is outside the staging session")

    normalized_task_id = str(task_id or "").strip()
    if not TASK_ID_PATTERN.fullmatch(normalized_task_id) or normalized_task_id in {".", ".."}:
        raise ValueError(f"Unsafe task id: {task_id!r}")
    task_input = (
        local_app_data_input
        / "TransVortex"
        / "Workspace"
        / "Tasks"
        / normalized_task_id
    )
    _assert_unlinked_path_within(task_input, session_root_input, "Task directory")
    task_dir = task_input.resolve()
    if not task_dir.is_dir():
        raise FileNotFoundError(f"Installed APP task directory was not found: {task_dir}")

    install_input = install_root.expanduser()
    _assert_unlinked_path_within(install_input, session_root_input, "Install root")
    install_path = install_input.resolve()
    if not install_path.is_dir():
        raise FileNotFoundError(f"Installed APP root was not found: {install_path}")
    for relative, description in (
        (Path("TransVortex.exe"), "Installed APP executable"),
        (Path("runtime") / "python" / "python.exe", "Installed Python runtime"),
        (Path("Uninstall.exe"), "Installed uninstaller"),
    ):
        candidate = install_input / relative
        _assert_unlinked_path_within(candidate, install_input, description)
        _regular_file(candidate, description)

    output_input = (
        output_report.expanduser()
        if output_report is not None
        else session_root_input / "managed_asr_installed_app_e2e.json"
    )
    _assert_unlinked_path_within(output_input, session_root_input, "Output report")
    output_path = output_input.resolve()
    if output_path.exists() and _is_link_or_junction(output_path):
        raise ValueError(f"Output report must not be a link or junction: {output_path}")
    if output_path.exists() and not output_path.is_file():
        raise ValueError(f"Output report path is not a file: {output_path}")
    output_parent = output_path.parent.resolve()
    reports_root = (session_root / "reports").resolve()
    if not _same_path(output_parent, session_root) and not _is_within(output_parent, reports_root):
        raise ValueError("Output report must be in the staging session root or its reports directory")
    if any(_same_path(output_path, source) for source in (stage_path, marker_path)):
        raise ValueError("Output report must not overwrite staging ownership evidence")

    return VerificationInputs(
        stage_report=stage_path,
        session_root=session_root,
        local_app_data=local_app_data,
        task_dir=task_dir,
        installer=_regular_file(installer, "Installer"),
        install_root=install_path,
        output_report=output_path,
    )


def _checkpoint_evidence(task: Mapping[str, Any], checkpoint: Mapping[str, Any]) -> dict[str, Any]:
    if task.get("status") != "DONE" or checkpoint.get("status") != "DONE":
        raise RuntimeError("Installed APP task and checkpoint must both be DONE")
    asr_total = int(checkpoint.get("asr_total_segments") or 0)
    asr_done = int(checkpoint.get("asr_done_count") or 0)
    translate_total = int(checkpoint.get("translate_total_chunks") or 0)
    translate_done = int(checkpoint.get("translate_done_count") or 0)
    if asr_total < 1 or asr_done != asr_total:
        raise RuntimeError("Installed APP task did not complete every ASR segment")
    if translate_total < 1 or translate_done != translate_total:
        raise RuntimeError("Installed APP task did not complete every translation chunk")
    return {
        "task_status": "DONE",
        "checkpoint_status": "DONE",
        "asr_total_segments": asr_total,
        "asr_done_count": asr_done,
        "source_segment_count": int(checkpoint.get("source_segment_count") or 0),
        "translate_total_chunks": translate_total,
        "translate_done_count": translate_done,
        "model_request_count": int(checkpoint.get("model_request_count") or 0),
        "updated_at": str(checkpoint.get("updated_at") or ""),
    }


def _worker_evidence(
    task_dir: Path,
    expected_task_id: str,
    expected_executable: Path,
    expected_sha256: str,
) -> tuple[dict[str, Any], datetime]:
    worker = _read_json_object(task_dir / "worker.json", "Task worker evidence")
    worker_executable = _regular_file(
        Path(str(worker.get("executable") or "")),
        "Task worker executable",
    )
    worker_sha256 = _required_text(worker, "executable_sha256", "worker").lower()
    if any(
        (
            worker.get("task_id") != expected_task_id,
            worker.get("owner") != "python",
            worker.get("command") != "_worker",
            worker.get("state") != "ended",
            int(worker.get("exit_code") if worker.get("exit_code") is not None else -1) != 0,
            not _same_path(worker_executable, expected_executable),
            worker_sha256 != expected_sha256,
            _sha256(worker_executable) != expected_sha256,
        )
    ):
        raise RuntimeError("Installed APP Python task worker did not exit cleanly")
    ended_at = _parse_datetime(worker.get("ended_at"), "worker.ended_at")

    events_path = _regular_file(task_dir / "events.jsonl", "Task events")
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
        raise RuntimeError("Installed APP task did not persist its final DONE event")
    return (
        {
            "owner": "python",
            "command": "_worker",
            "state": "ended",
            "exit_code": 0,
            "executable": str(worker_executable),
            "executable_sha256": worker_sha256,
            "matches_install_runtime": True,
            "started_at": str(worker.get("started_at") or ""),
            "ended_at": ended_at.isoformat(),
            "done_event_at": str(done_event.get("created_at") or ""),
            "events": _file_evidence(events_path, "Task events"),
        },
        ended_at,
    )


def _asr_evidence(task_dir: Path) -> dict[str, Any]:
    rows_input = task_dir / "source" / "asr" / "rows"
    _assert_unlinked_path_within(rows_input, task_dir, "Persisted ASR rows")
    rows_root = rows_input.resolve()
    if not rows_root.is_dir() or _is_link_or_junction(rows_root):
        raise RuntimeError("asr_not_exercised: installed APP task has no ASR row directory")
    row_files = sorted(rows_root.glob("segment_*.json"))
    if not row_files:
        raise RuntimeError("asr_not_exercised: installed APP task has no persisted ASR rows")

    row_count = 0
    files: list[dict[str, Any]] = []
    for row_file in row_files:
        payload = json.loads(row_file.read_text(encoding="utf-8-sig"))
        if not isinstance(payload, list):
            raise ValueError(f"ASR row evidence must be a list: {row_file}")
        for row in payload:
            if not isinstance(row, dict):
                raise ValueError(f"ASR row evidence contains a non-object row: {row_file}")
            meta = row.get("meta")
            if not isinstance(meta, dict) or any(
                meta.get(key) != value for key, value in EXPECTED_ASR_META.items()
            ):
                raise RuntimeError(
                    "ASR row evidence does not prove the managed CUDA faster-whisper worker"
                )
            row_count += 1
        files.append(_file_evidence(row_file, "Persisted ASR row file"))
    if row_count < 1:
        raise RuntimeError("asr_not_exercised: installed APP task persisted no subtitle rows")
    return {
        **EXPECTED_ASR_META,
        "transport_basis": "persisted_asr_row_meta",
        "row_file_count": len(row_files),
        "row_count": row_count,
        "row_files": files,
    }


def _output_evidence(
    task: Mapping[str, Any],
    *,
    worker_ended_at: datetime,
) -> tuple[dict[str, Any], dict[str, Any]]:
    configured = task.get("output_paths")
    if not isinstance(configured, dict):
        raise RuntimeError("Installed APP task did not record output_paths")
    evidence: dict[str, dict[str, Any]] = {}
    settings = task.get("settings")
    if not isinstance(settings, dict) or settings.get("reexport_bilingual") is not True:
        raise RuntimeError("Installed APP task did not request bilingual review re-export")
    for format_name in ("srt", "ass"):
        raw_path = str(configured.get(format_name) or "").strip()
        if not raw_path:
            raise RuntimeError(f"Installed APP task did not record its {format_name.upper()} output")
        if Path(raw_path).suffix.lower() != f".{format_name}":
            raise RuntimeError(f"Installed APP {format_name.upper()} output has an unexpected extension")
        evidence[format_name] = _file_evidence(
            Path(raw_path),
            f"Installed APP {format_name.upper()} output",
        )

    task_updated_at = _parse_datetime(task.get("updated_at"), "task.updated_at")
    output_write_times = [
        _parse_datetime(row["last_write_at"], f"{name} output last_write_at")
        for name, row in evidence.items()
    ]
    if task_updated_at < worker_ended_at or any(
        written_at <= worker_ended_at for written_at in output_write_times
    ):
        raise RuntimeError(
            "Output timestamps do not prove a post-completion review re-export"
        )
    reexport = {
        "verified": True,
        "basis": "task_and_output_timestamps_after_worker_exit",
        "task_updated_at": task_updated_at.isoformat(),
        "worker_ended_at": worker_ended_at.isoformat(),
        "minimum_output_delay_seconds": min(
            (written_at - worker_ended_at).total_seconds()
            for written_at in output_write_times
        ),
        "bilingual": True,
    }
    return evidence, reexport


def _write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as handle:
            temporary_name = handle.name
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
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


def run_verification(
    *,
    stage_report: Path,
    task_id: str,
    installer: Path,
    install_root: Path,
    output_report: Path | None = None,
) -> dict[str, Any]:
    inputs = _load_inputs(
        stage_report=stage_report,
        task_id=task_id,
        installer=installer,
        install_root=install_root,
        output_report=output_report,
    )
    task = _read_json_object(inputs.task_dir / "task.json", "Installed APP task")
    checkpoint = _read_json_object(
        inputs.task_dir / "checkpoint.json",
        "Installed APP checkpoint",
    )
    task_id_from_file = _required_text(task, "task_id", "task")
    if task_id_from_file != inputs.task_dir.name:
        raise ValueError("Task id does not match its owned directory")

    checkpoint_evidence = _checkpoint_evidence(task, checkpoint)
    expected_python = (inputs.install_root / "runtime" / "python" / "python.exe").resolve()
    actual_python = Path(sys.executable).expanduser().resolve()
    if not _same_path(actual_python, expected_python):
        raise RuntimeError(
            "Installed APP E2E verifier must run under the installed runtime Python: "
            f"expected {expected_python}, got {actual_python}"
        )
    launcher = {
        "path": str(actual_python),
        "sha256": _sha256(actual_python),
        "matches_install_runtime": True,
    }
    worker, worker_ended_at = _worker_evidence(
        inputs.task_dir,
        task_id_from_file,
        expected_python,
        launcher["sha256"],
    )
    asr = _asr_evidence(inputs.task_dir)
    outputs, reexport = _output_evidence(task, worker_ended_at=worker_ended_at)

    report = {
        "schema_version": SCHEMA_VERSION,
        "acceptance": ACCEPTANCE_ID,
        "ok": True,
        "generated_at": _utc_now(),
        "stage": {
            **_file_evidence(inputs.stage_report, "Staging report"),
            "session_root": str(inputs.session_root),
        },
        "installed_artifacts": {
            "installer": _file_evidence(inputs.installer, "Installer"),
            "app_executable": _file_evidence(
                inputs.install_root / "TransVortex.exe",
                "Installed TransVortex executable",
            ),
            "python": _file_evidence(
                inputs.install_root / "runtime" / "python" / "python.exe",
                "Installed Python runtime",
            ),
            "uninstaller": _file_evidence(
                inputs.install_root / "Uninstall.exe",
                "Installed uninstaller",
            ),
        },
        "verifier_launcher": launcher,
        "task": {
            "id": task_id_from_file,
            "directory": str(inputs.task_dir),
            **checkpoint_evidence,
        },
        "worker": worker,
        "asr": asr,
        "outputs": outputs,
        "review_reexport": reexport,
    }
    _write_json_atomic(inputs.output_report, report)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify an installed APP E2E task that used locally staged managed ASR.",
    )
    parser.add_argument("--stage-report", type=Path, required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--install-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = run_verification(
            stage_report=args.stage_report,
            task_id=args.task_id,
            installer=args.installer,
            install_root=args.install_root,
            output_report=args.output,
        )
    except Exception as exc:
        print(f"managed ASR installed APP E2E verification failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
