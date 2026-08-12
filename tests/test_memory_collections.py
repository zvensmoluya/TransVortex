from __future__ import annotations

from pathlib import Path

import pytest

from transvortex.app.desktop_api import DesktopApi, DesktopApiError
from transvortex.app.config import load_app_config
from transvortex.app.models import MemoryCollectionRef, MemoryConfig
from transvortex.artifacts.result_workspace import promote_task_memory_entries
from transvortex.artifacts.task_store import TaskStore
from transvortex.app.models import TaskRecord
from transvortex.core.orchestrator import _apply_saved_pipeline_settings, create_pipeline_task
from transvortex.memory.collections import (
    MemoryCollectionError,
    MemoryCollectionStore,
    build_selected_collections_snapshot,
)
from transvortex.memory.plan import effective_memory_sources, resolve_memory_plan
from transvortex.memory.schema import MemoryDocument, MemoryEntry
from transvortex.memory.store import MemoryStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        "\n".join(
            [
                "config_schema_version: 2",
                "artifacts_dir: artifacts",
                "asr: {engine: faster_whisper_large_v3}",
                "asr_engines:",
                "  - id: faster_whisper_large_v3",
                "    type: faster_whisper_worker",
                "    runtime: {source: managed, id: managed:faster-whisper}",
                "    model: {source: managed, id: large-v3}",
            ]
        ),
        encoding="utf-8",
    )
    (root / "providers.yaml").write_text(
        "\n".join(
            [
                "providers:",
                "  - name: p1",
                "    api_type: openai",
                "    base_url: https://example.com/v1",
                "    env_key: PROVIDER_KEY",
                "    models: [m1]",
                "routing:",
                "  primary: {provider: p1, model: m1}",
            ]
        ),
        encoding="utf-8",
    )


def test_collection_crud_preserves_entry_timestamp_and_revision(tmp_path: Path) -> None:
    store = MemoryCollectionStore(tmp_path / "collections")
    created = store.create(name="人物名", collection_id="characters", language_pairs=["ja->zh-CN"])
    updated, entry = store.upsert_entry(
        created.id,
        {"source": "スバル", "target": "昴", "category": "name"},
        expected_revision=created.revision,
    )

    loaded_once = store.get(created.id)
    loaded_twice = store.get(created.id)

    assert updated.revision == 2
    assert loaded_once.entries[0].updated_at == entry.updated_at
    assert loaded_twice.entries[0].updated_at == entry.updated_at
    with pytest.raises(MemoryCollectionError) as caught:
        store.update(created.id, {"name": "旧修订写入"}, expected_revision=1)
    assert caught.value.code == "memory_collection_revision_conflict"


def test_source_only_hint_entry_is_explicitly_allowed(tmp_path: Path) -> None:
    store = MemoryCollectionStore(tmp_path / "collections")
    collection = store.create(name="识别提示", collection_id="hints")

    updated, entry = store.upsert_entry(
        collection.id,
        {
            "source": "スバル",
            "status": "proposed",
            "constraint": "hint",
            "memory_type": "concept_hint",
        },
        expected_revision=collection.revision,
    )

    assert updated.revision == 2
    assert entry.source == "スバル"
    assert entry.target == ""
    assert entry.constraint == "hint"
    assert entry.memory_type == "concept_hint"

    with pytest.raises(MemoryCollectionError) as caught:
        store.upsert_entry(
            collection.id,
            {"source": "没有内容"},
            expected_revision=updated.revision,
        )
    assert caught.value.code == "memory_entry_invalid"


def test_selected_collection_snapshot_is_ordered_and_frozen(tmp_path: Path) -> None:
    collection_store = MemoryCollectionStore(tmp_path / "collections")
    first = collection_store.create(name="优先", collection_id="first")
    first, _ = collection_store.upsert_entry(
        first.id,
        {"source": "Subaru", "target": "昴", "status": "locked"},
        expected_revision=first.revision,
    )
    second = collection_store.create(name="次选", collection_id="second")
    second, _ = collection_store.upsert_entry(
        second.id,
        {"source": "Subaru", "target": "斯巴鲁", "status": "confirmed"},
        expected_revision=second.revision,
    )
    snapshot = build_selected_collections_snapshot(
        collection_ids=["first", "second", "first"],
        store=collection_store,
        source_lang="en",
        target_lang="zh-CN",
    )
    task_memory = MemoryStore(tmp_path / "task" / "memory")
    task_memory.save_selected_collections(snapshot)
    second, _ = collection_store.upsert_entry(
        second.id,
        {"source": "Emilia", "target": "爱蜜莉雅"},
        expected_revision=second.revision,
    )

    effective = task_memory.load_effective(("collections",))

    assert snapshot["collection_ids"] == ["first", "second"]
    assert [(item.source, item.target) for item in effective.entries] == [("Subaru", "昴")]
    assert snapshot["report"]["conflicts"][0]["skipped_collection_id"] == "second"


def test_explicit_collection_selection_accepts_auto_detect_source(tmp_path: Path) -> None:
    store = MemoryCollectionStore(tmp_path / "collections")
    collection = store.create(
        name="日中术语",
        collection_id="ja-zh",
        language_pairs=["ja->zh-CN"],
    )
    store.upsert_entry(
        collection.id,
        {"source": "スバル", "target": "昴"},
        expected_revision=collection.revision,
    )

    snapshot = build_selected_collections_snapshot(
        collection_ids=[collection.id],
        store=store,
        source_lang="auto",
        target_lang="zh-CN",
    )

    assert snapshot["report"]["entries"] == 1


def test_memory_plan_separates_collection_use_from_dynamic_generation() -> None:
    memory = MemoryConfig(
        collections=[MemoryCollectionRef(id="shared")],
    )
    memory.bootstrap.enabled = False
    memory.patch.enabled = False

    plan = resolve_memory_plan(memory)

    assert plan.uses_collections is True
    assert plan.runs_bootstrap is False
    assert plan.dynamic_updates_enabled is False
    assert effective_memory_sources(memory) == ("collections", "runtime")


def test_config_accepts_ordered_task_collection_overrides(tmp_path: Path) -> None:
    _write_config(tmp_path)

    config = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "memory_collections": [
                {"id": "characters"},
                {"id": "shared"},
                {"id": "characters"},
            ]
        },
    )

    assert [item.id for item in config.pipeline.memory.collections] == ["characters", "shared"]


def test_task_creation_freezes_selected_collection_before_worker_start(tmp_path: Path) -> None:
    _write_config(tmp_path)
    collection_store = MemoryCollectionStore(tmp_path / "memory" / "collections")
    collection = collection_store.create(name="共享术语", collection_id="shared")
    collection, _ = collection_store.upsert_entry(
        collection.id,
        {"source": "Subaru", "target": "昴"},
        expected_revision=collection.revision,
    )

    task_id, artifacts_dir = create_pipeline_task(
        root_dir=tmp_path,
        input_file=tmp_path / "queued.srt",
        source_lang="en",
        target_lang="zh-CN",
        cli_overrides={"memory_collections": [{"id": "shared"}]},
    )
    snapshot_file = artifacts_dir / task_id / "memory" / "selected_collections.json"
    collection_store.upsert_entry(
        collection.id,
        {"source": "Emilia", "target": "爱蜜莉雅"},
        expected_revision=collection.revision,
    )

    snapshot = MemoryStore(snapshot_file.parent).load_selected_collections()
    assert snapshot_file.exists()
    assert snapshot["report"]["applied"][0]["revision"] == 2
    assert [item["source"] for item in snapshot["entries"]] == ["Subaru"]


def test_legacy_task_resume_does_not_inherit_new_global_collections(tmp_path: Path) -> None:
    _write_config(tmp_path)
    config = load_app_config(
        root_dir=tmp_path,
        cli_overrides={"memory_collections": [{"id": "new-global-default"}]},
    )

    _apply_saved_pipeline_settings(config, {"memory": {"enabled": True}})

    assert config.pipeline.memory.collections == []


def test_promote_requires_explicit_task_entry_selection(tmp_path: Path) -> None:
    _write_config(tmp_path)
    collection_store = MemoryCollectionStore(tmp_path / "memory" / "collections")
    collection = collection_store.create(name="共享术语", collection_id="shared")
    task_store = TaskStore(tmp_path / "artifacts")
    task_store.save_task(
        TaskRecord(
            task_id="task1",
            input_file="demo.srt",
            source_lang="ja",
            target_lang="zh-CN",
            bilingual=False,
            status="DONE",
            created_at="2026-08-07T00:00:00+00:00",
            updated_at="2026-08-07T00:00:00+00:00",
        )
    )
    runtime = MemoryStore(task_store.task_dir("task1") / "memory")
    runtime.save(
        MemoryDocument(
            entries=[
                MemoryEntry(id="one", source="スバル", target="昴"),
                MemoryEntry(id="two", source="エミリア", target="爱蜜莉雅"),
            ]
        )
    )

    result = promote_task_memory_entries(
        root_dir=tmp_path,
        task_id="task1",
        collection_id="shared",
        entry_ids=["two"],
        expected_revision=collection.revision,
    )

    assert [item.source for item in collection_store.get("shared").entries] == ["エミリア"]
    assert result["applied"][0]["entry_id"] == "two"


def test_promote_dry_run_and_repeat_are_safe(tmp_path: Path) -> None:
    store = MemoryCollectionStore(tmp_path / "collections")
    collection = store.create(name="共享术语", collection_id="shared")
    candidate = MemoryEntry(id="candidate", source="Subaru", target="昴")

    preview = store.promote_entries(
        "shared",
        [candidate],
        task_id="task1",
        expected_revision=collection.revision,
        dry_run=True,
    )
    assert preview["collection"]["revision"] == 2
    assert store.get("shared").revision == 1

    applied = store.promote_entries(
        "shared",
        [candidate],
        task_id="task1",
        expected_revision=1,
    )
    repeated = store.promote_entries(
        "shared",
        [candidate],
        task_id="task1",
        expected_revision=applied["collection"]["revision"],
    )
    assert repeated["applied"] == []
    assert repeated["skipped"] == [{"entry_id": "candidate", "reason": "already_promoted"}]
    assert repeated["collection"]["revision"] == 2


def test_desktop_memory_contract_exposes_safe_crud(tmp_path: Path) -> None:
    _write_config(tmp_path)
    api = DesktopApi(root_dir=tmp_path)

    created = api.dispatch(
        "memory.collection.create",
        {"collection_id": "shared", "name": "共享术语", "language_pairs": ["ja->zh-CN"]},
    )["collection"]
    saved = api.dispatch(
        "memory.entry.upsert",
        {
            "collection_id": "shared",
            "expected_revision": created["revision"],
            "entry": {"source": "スバル", "target": "昴", "status": "locked"},
        },
    )["collection"]

    listed = api.dispatch("memory.collections.list")
    resolved = api.dispatch(
        "memory.plan.resolve",
        {
            "collection_ids": ["shared"],
            "source_lang": "ja",
            "target_lang": "zh-CN",
        },
    )

    assert listed["collections"][0]["entries"] == 1
    assert resolved["entries"][0]["target"] == "昴"
    with pytest.raises(DesktopApiError) as caught:
        api.dispatch(
            "memory.collection.update",
            {
                "collection_id": "shared",
                "expected_revision": created["revision"],
                "changes": {"name": "过期修改"},
            },
        )
    assert caught.value.code == "memory_collection_revision_conflict"
    assert saved["revision"] == 2
