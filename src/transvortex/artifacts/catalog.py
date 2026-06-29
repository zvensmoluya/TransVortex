from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..app.models import TaskRecord
from ..protocol.redaction import redact
from ..utils import read_json


CATALOG_SCHEMA_VERSION = 1


class TaskCatalog:
    def __init__(self, artifacts_dir: Path) -> None:
        self.artifacts_dir = artifacts_dir
        self.runtime_dir = artifacts_dir / ".runtime"
        self.db_path = self.runtime_dir / "catalog.sqlite"

    def status(self) -> dict[str, Any]:
        conn = self._connect()
        try:
            version = self._schema_version(conn)
            count = int(conn.execute("select count(*) from tasks").fetchone()[0])
        finally:
            conn.close()
        return {
            "ok": True,
            "path": str(self.db_path),
            "schema_version": version,
            "task_count": count,
        }

    def upsert_task(self, task: TaskRecord, *, last_event_at: str | None = None) -> None:
        conn = self._connect()
        try:
            with conn:
                existing = conn.execute(
                    "select last_event_at from tasks where task_id = ?",
                    (task.task_id,),
                ).fetchone()
                effective_last_event_at = last_event_at if last_event_at is not None else (
                    str(existing["last_event_at"] or "") if existing else ""
                )
                conn.execute(
                    """
                    insert into tasks (
                        task_id, status, created_at, updated_at, input_file, source_lang, target_lang,
                        bilingual, output_path, output_paths_json, error_summary, task_dir, last_event_at
                    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    on conflict(task_id) do update set
                        status = excluded.status,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        input_file = excluded.input_file,
                        source_lang = excluded.source_lang,
                        target_lang = excluded.target_lang,
                        bilingual = excluded.bilingual,
                        output_path = excluded.output_path,
                        output_paths_json = excluded.output_paths_json,
                        error_summary = excluded.error_summary,
                        task_dir = excluded.task_dir,
                        last_event_at = excluded.last_event_at
                    """,
                    self._task_row(task, last_event_at=effective_last_event_at),
                )
        finally:
            conn.close()

    def mark_event(self, task: TaskRecord, *, event_created_at: str) -> None:
        self.upsert_task(task, last_event_at=event_created_at)

    def list_task_ids(self, *, order: str = "updated_desc") -> list[str]:
        order_sql = "updated_at desc, created_at desc, task_id desc"
        if order == "created_asc":
            order_sql = "created_at asc, task_id asc"
        conn = self._connect()
        try:
            rows = conn.execute(f"select task_id from tasks order by {order_sql}").fetchall()
            return [str(row["task_id"]) for row in rows]
        finally:
            conn.close()

    def rebuild(self) -> dict[str, Any]:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        indexed = 0
        skipped: list[str] = []
        recovered_from: str | None = None
        try:
            conn = self._connect()
        except sqlite3.DatabaseError:
            recovered_from = self._move_corrupt_database()
            conn = self._connect()
        try:
            with conn:
                conn.execute("delete from tasks")
                if self.artifacts_dir.exists():
                    for child in self.artifacts_dir.iterdir():
                        if not child.is_dir() or child.name == ".runtime":
                            continue
                        task_file = child / "task.json"
                        if not task_file.exists():
                            continue
                        try:
                            task = TaskRecord(**read_json(task_file))
                            conn.execute(
                                """
                                insert into tasks (
                                    task_id, status, created_at, updated_at, input_file, source_lang, target_lang,
                                    bilingual, output_path, output_paths_json, error_summary, task_dir, last_event_at
                                ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                self._task_row(task, task_dir=child, last_event_at=_last_event_at(child / "events.jsonl")),
                            )
                            indexed += 1
                        except Exception:
                            skipped.append(child.name)
        finally:
            conn.close()
        return {
            "ok": True,
            "path": str(self.db_path),
            "indexed": indexed,
            "skipped": skipped,
            "schema_version": CATALOG_SCHEMA_VERSION,
            "recovered_from": recovered_from or "",
        }

    def _connect(self) -> sqlite3.Connection:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.db_path, timeout=5.0)
        conn.row_factory = sqlite3.Row
        conn.execute("pragma foreign_keys = on")
        conn.execute("pragma busy_timeout = 5000")
        conn.execute("pragma journal_mode = wal")
        try:
            self._ensure_schema(conn)
            conn.commit()
        except Exception:
            conn.close()
            raise
        return conn

    def _task_row(self, task: TaskRecord, *, task_dir: Path | None = None, last_event_at: str = "") -> tuple[Any, ...]:
        return (
            task.task_id,
            task.status,
            task.created_at,
            task.updated_at,
            _redacted_text(task.input_file),
            task.source_lang,
            task.target_lang,
            1 if task.bilingual else 0,
            _redacted_text(task.output_path or ""),
            _redacted_json(task.output_paths or {}),
            _redacted_text(task.error or ""),
            str(task_dir or (self.artifacts_dir / task.task_id)),
            last_event_at,
        )

    def _ensure_schema(self, conn: sqlite3.Connection) -> None:
        conn.execute(
            """
            create table if not exists catalog_meta (
                key text primary key,
                value text not null
            )
            """
        )
        conn.execute(
            """
            create table if not exists tasks (
                task_id text primary key,
                status text not null,
                created_at text not null,
                updated_at text not null,
                input_file text not null,
                source_lang text not null,
                target_lang text not null,
                bilingual integer not null,
                output_path text not null default '',
                output_paths_json text not null default '{}',
                error_summary text not null default '',
                task_dir text not null,
                last_event_at text not null default ''
            )
            """
        )
        conn.execute(
            """
            create table if not exists task_app_meta (
                task_id text primary key,
                archived integer not null default 0,
                starred integer not null default 0,
                hidden integer not null default 0,
                last_opened_at text not null default '',
                note text not null default '',
                foreign key(task_id) references tasks(task_id) on delete cascade
            )
            """
        )
        conn.execute("create index if not exists idx_tasks_updated_at on tasks(updated_at desc)")
        conn.execute("create index if not exists idx_tasks_created_at on tasks(created_at asc)")
        conn.execute("create index if not exists idx_tasks_status on tasks(status)")
        current = self._schema_version(conn)
        if current not in {0, CATALOG_SCHEMA_VERSION}:
            raise RuntimeError(f"Unsupported task catalog schema version: {current}")
        conn.execute(
            "insert or replace into catalog_meta(key, value) values ('schema_version', ?)",
            (str(CATALOG_SCHEMA_VERSION),),
        )

    def _schema_version(self, conn: sqlite3.Connection) -> int:
        row = conn.execute("select value from catalog_meta where key = 'schema_version'").fetchone()
        if row is None:
            return 0
        try:
            return int(row["value"])
        except Exception:
            return 0

    def _move_corrupt_database(self) -> str:
        if not self.db_path.exists():
            return ""
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        target = self.db_path.with_name(f"{self.db_path.name}.corrupt-{stamp}")
        self.db_path.replace(target)
        for suffix in ("-wal", "-shm"):
            sidecar = self.db_path.with_name(f"{self.db_path.name}{suffix}")
            if sidecar.exists():
                sidecar.replace(target.with_name(f"{target.name}{suffix}"))
        return str(target)


def try_sync_task(artifacts_dir: Path, task: TaskRecord, *, last_event_at: str | None = None) -> None:
    try:
        TaskCatalog(artifacts_dir).upsert_task(task, last_event_at=last_event_at)
    except Exception:
        pass


def _redacted_text(value: str) -> str:
    return str(redact(value))


def _redacted_json(value: Any) -> str:
    return json.dumps(redact(value), ensure_ascii=False, sort_keys=True)


def _last_event_at(path: Path) -> str:
    if not path.exists():
        return ""
    last = ""
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue
                created_at = payload.get("created_at")
                if created_at:
                    last = str(created_at)
    except Exception:
        return ""
    return last
