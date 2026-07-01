from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import uuid
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .protocol.redaction import redact


JSON_REPLACE_RETRIES = 3
JSON_REPLACE_RETRY_DELAY_SECONDS = 0.02


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def gen_task_id() -> str:
    return f"tvx_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"


def to_plain(obj: Any) -> Any:
    if is_dataclass(obj):
        return {k: to_plain(v) for k, v in asdict(obj).items()}
    if isinstance(obj, dict):
        return {k: to_plain(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [to_plain(i) for i in obj]
    if isinstance(obj, Path):
        return str(obj)
    return obj


class _FileLockState:
    def __init__(self) -> None:
        self.guard = threading.RLock()
        self.owner_thread: int | None = None
        self.depth = 0
        self.handle: Any | None = None


_FILE_LOCK_STATES: dict[str, _FileLockState] = {}
_FILE_LOCK_STATES_GUARD = threading.Lock()


class FileLock:
    """Small cross-process file lock with same-thread reentrancy."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._state: _FileLockState | None = None

    def __enter__(self) -> "FileLock":
        key = str(self.path.resolve())
        with _FILE_LOCK_STATES_GUARD:
            state = _FILE_LOCK_STATES.setdefault(key, _FileLockState())
        state.guard.acquire()
        thread_id = threading.get_ident()
        if state.owner_thread == thread_id:
            state.depth += 1
            self._state = state
            return self

        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+b")
        try:
            _lock_file(handle)
        except Exception:
            handle.close()
            state.guard.release()
            raise
        state.owner_thread = thread_id
        state.depth = 1
        state.handle = handle
        self._state = state
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        state = self._state
        if state is None:
            return
        try:
            state.depth -= 1
            if state.depth <= 0:
                handle = state.handle
                state.handle = None
                state.owner_thread = None
                state.depth = 0
                if handle is not None:
                    try:
                        _unlock_file(handle)
                    finally:
                        handle.close()
        finally:
            state.guard.release()
            self._state = None


def _lock_file(handle: Any) -> None:
    handle.seek(0)
    if os.name == "nt":
        import msvcrt

        msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        return
    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)


def _unlock_file(handle: Any) -> None:
    handle.seek(0)
    if os.name == "nt":
        import msvcrt

        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        return
    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(redact(to_plain(data)), ensure_ascii=False, indent=2)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        _replace_with_retry(tmp_path, path)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def _replace_with_retry(src: Path, dst: Path) -> None:
    for attempt in range(JSON_REPLACE_RETRIES):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if attempt >= JSON_REPLACE_RETRIES - 1:
                raise
            time.sleep(JSON_REPLACE_RETRY_DELAY_SECONDS)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def append_jsonl(path: Path, item: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(redact(to_plain(item)), ensure_ascii=False))
        f.write("\n")


def read_jsonl(path: Path) -> list[Any]:
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows
