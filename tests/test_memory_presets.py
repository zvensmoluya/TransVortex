from __future__ import annotations

import json
from pathlib import Path

from transvortex.app.models import MemoryPresetRef
from transvortex.app.models import AppConfig, PipelineConfig, ProviderConfig, RouteTarget, RoutingConfig, Segment
from transvortex.app.models import TaskRecord
from transvortex.artifacts.task_store import TaskStore
from transvortex.memory.exporter import (
    MemoryPresetBootstrapOptions,
    MemoryPresetExportError,
    MemoryPresetExportOptions,
    bootstrap_memory_preset,
    export_runtime_memory_to_preset,
)
from transvortex.memory.presets import (
    MemoryPresetError,
    build_selected_presets_snapshot,
    discover_preset_bundles,
    load_preset_bundle,
    materialize_entries,
    scope_matches,
)
from transvortex.utils import write_json


def _write_preset(root: Path, name: str, payload: str) -> Path:
    presets_dir = root / "memory" / "presets"
    presets_dir.mkdir(parents=True, exist_ok=True)
    path = presets_dir / f"{name}.json"
    path.write_text(payload, encoding="utf-8")
    return path


def _write_task_memory(root: Path, task_id: str, entries: list[dict], conflicts: list[dict] | None = None) -> None:
    store = TaskStore(root / "artifacts")
    store.save_task(
        TaskRecord(
            task_id=task_id,
            input_file="demo.srt",
            source_lang="ja",
            target_lang="zh-CN",
            bilingual=False,
            status="DONE",
            created_at="2026-05-15T00:00:00+00:00",
            updated_at="2026-05-15T00:00:00+00:00",
        )
    )
    memory_dir = store.task_dir(task_id) / "memory"
    write_json(memory_dir / "translation_memory.json", {"version": 1, "entries": entries})
    if conflicts:
        for conflict in conflicts:
            (memory_dir / "conflicts.jsonl").parent.mkdir(parents=True, exist_ok=True)
            with (memory_dir / "conflicts.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(conflict, ensure_ascii=False))
                f.write("\n")


def test_load_preset_bundle_parses_metadata_and_entries(tmp_path: Path) -> None:
    path = _write_preset(
        tmp_path,
        "rezero",
        """
{
  "id": "rezero",
  "version": "1.0.0",
  "name": "Re:Zero",
  "scope": {"language_pairs": ["ja->zh-CN", "ja->zh-TW"], "tags": ["anime"]},
  "default_status": "confirmed",
  "entries": [
    {"source": "スバル", "target": "昴", "category": "name", "priority": 90}
  ]
}
        """.strip(),
    )
    result = load_preset_bundle(path)
    assert result.bundle is not None
    assert result.bundle.id == "rezero"
    assert result.bundle.scope.language_pairs == ["ja->zh-cn", "ja->zh-tw"]
    assert result.bundle.entries[0].source == "スバル"


def test_load_preset_bundle_reports_invalid_payload(tmp_path: Path) -> None:
    path = tmp_path / "memory" / "presets" / "broken.json"
    path.parent.mkdir(parents=True)
    path.write_text("[]", encoding="utf-8")
    result = load_preset_bundle(path)
    assert result.bundle is None
    assert "must be a JSON object" in result.error


def test_export_runtime_memory_to_preset_writes_loadable_draft(tmp_path: Path) -> None:
    _write_task_memory(
        tmp_path,
        "task1",
        [
            {
                "source": "スバル",
                "target": "昴",
                "category": "name",
                "status": "confirmed",
                "aliases": ["Subaru"],
                "confidence": 0.91,
            },
            {
                "source": "エミリア",
                "target": "爱蜜莉雅",
                "category": "name",
                "status": "proposed",
                "confidence": 0.73,
            },
        ],
        conflicts=[
            {
                "source": "エミリア",
                "existing_target": "爱蜜莉雅",
                "proposed_target": "艾米莉娅",
                "reason": "different target proposed",
            }
        ],
    )

    payload = export_runtime_memory_to_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        options=MemoryPresetExportOptions(
            task_id="task1",
            preset_id="rezero",
            name="Re:Zero",
            description="Draft glossary",
        ),
    )

    assert payload["ok"] is True
    assert payload["report"]["exported"] == 2
    path = tmp_path / "memory" / "presets" / "rezero.json"
    result = load_preset_bundle(path)
    assert result.bundle is not None
    assert result.bundle.default_status == "proposed"
    assert result.bundle.scope.language_pairs == ["ja->zh-cn"]
    entries = {entry.source: entry for entry in result.bundle.entries}
    assert entries["スバル"].target == "昴"
    assert entries["スバル"].status == "proposed"
    assert "艾米莉娅" in entries["エミリア"].notes


def test_export_runtime_memory_filters_and_dedupes_entries(tmp_path: Path) -> None:
    _write_task_memory(
        tmp_path,
        "task1",
        [
            {"source": "", "target": "空", "status": "proposed"},
            {"source": "Ghost", "target": "", "status": "proposed"},
            {"source": "Bad", "target": "坏", "status": "rejected"},
            {"source": "Subaru", "target": "昴", "status": "proposed", "confidence": 0.5},
            {"source": " subaru ", "target": "斯巴鲁", "status": "confirmed", "confidence": 0.8},
        ],
    )

    payload = export_runtime_memory_to_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        options=MemoryPresetExportOptions(
            task_id="task1",
            preset_id="rezero",
            default_status="confirmed",
        ),
    )

    result = load_preset_bundle(tmp_path / "memory" / "presets" / "rezero.json")
    assert result.bundle is not None
    assert [(entry.source, entry.target, entry.status) for entry in result.bundle.entries] == [
        ("subaru", "斯巴鲁", "confirmed")
    ]
    assert {row["reason"] for row in payload["report"]["skipped"]} == {
        "empty_source",
        "empty_target",
        "status_not_exportable",
    }
    assert payload["report"]["duplicates"][0]["reason"] == "duplicate_source"
    assert payload["report"]["conflicts"][0]["reason"] == "duplicate_source_different_target"


def test_export_runtime_memory_dry_run_does_not_write_preset(tmp_path: Path) -> None:
    _write_task_memory(tmp_path, "task1", [{"source": "Subaru", "target": "昴"}])

    payload = export_runtime_memory_to_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        options=MemoryPresetExportOptions(task_id="task1", preset_id="rezero", dry_run=True),
    )

    assert payload["dry_run"] is True
    assert payload["preset"]["entries"][0]["source"] == "Subaru"
    assert not (tmp_path / "memory" / "presets" / "rezero.json").exists()


def test_export_runtime_memory_requires_overwrite_for_existing_preset(tmp_path: Path) -> None:
    _write_task_memory(tmp_path, "task1", [{"source": "Subaru", "target": "昴"}])
    _write_preset(tmp_path, "rezero", """{"id": "rezero", "entries": [{"source": "Old", "target": "旧"}]}""")

    try:
        export_runtime_memory_to_preset(
            root_dir=tmp_path,
            artifacts_dir=tmp_path / "artifacts",
            options=MemoryPresetExportOptions(task_id="task1", preset_id="rezero"),
        )
    except MemoryPresetExportError as exc:
        assert "already exists" in str(exc)
    else:  # pragma: no cover - assertion branch
        raise AssertionError("expected existing preset to fail")

    export_runtime_memory_to_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        options=MemoryPresetExportOptions(task_id="task1", preset_id="rezero", overwrite=True),
    )
    result = load_preset_bundle(tmp_path / "memory" / "presets" / "rezero.json")
    assert result.bundle is not None
    assert [entry.source for entry in result.bundle.entries] == ["Subaru"]


def test_bootstrap_memory_preset_writes_draft_preset(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path / "artifacts"),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )

    class FakeClient:
        def translate_request(self, _req):
            return type(
                "Response",
                (),
                {
                    "raw_text": (
                        '{"chunk_ids":["bootstrap"],"actions":[{"action":"upsert",'
                        '"source":"Subaru","target":"斯巴鲁","category":"name",'
                        '"status":"confirmed","confidence":0.9,"evidence_ids":[1]}]}'
                    )
                },
            )()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())

    payload = bootstrap_memory_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        config=config,
        options=MemoryPresetBootstrapOptions(
            segments=[Segment(id=1, start=0, end=1, text_src="Subaru arrives")],
            source_lang="en",
            target_lang="zh-CN",
            preset_id="show",
            name="Show",
            default_status="locked",
        ),
    )

    assert payload["ok"] is True
    assert payload["report"]["exported"] == 1
    result = load_preset_bundle(tmp_path / "memory" / "presets" / "show.json")
    assert result.bundle is not None
    assert result.bundle.default_status == "locked"
    assert result.bundle.scope.language_pairs == ["en->zh-cn"]
    assert result.bundle.entries[0].source == "Subaru"
    assert result.bundle.entries[0].status == "locked"


def test_bootstrap_memory_preset_dry_run_does_not_write(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path / "artifacts"),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )

    class FakeClient:
        def translate_request(self, _req):
            return type("Response", (), {"raw_text": '{"chunk_ids":["bootstrap"],"actions":[]}'})()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())

    payload = bootstrap_memory_preset(
        root_dir=tmp_path,
        artifacts_dir=tmp_path / "artifacts",
        config=config,
        options=MemoryPresetBootstrapOptions(
            segments=[Segment(id=1, start=0, end=1, text_src="Nothing")],
            source_lang="en",
            target_lang="zh-CN",
            preset_id="empty",
            dry_run=True,
        ),
    )

    assert payload["dry_run"] is True
    assert payload["report"]["exported"] == 0
    assert payload["preset"]["entries"] == []
    assert not (tmp_path / "memory" / "presets" / "empty.json").exists()


def test_scope_matches_accepts_pair_or_wildcards(tmp_path: Path) -> None:
    path = _write_preset(
        tmp_path,
        "anime_honorifics",
        """
{
  "id": "anime_honorifics",
  "scope": {"language_pairs": ["ja->*"]},
  "entries": [
    {"source": "さん", "target": "先生"}
  ]
}
        """.strip(),
    )
    bundle = load_preset_bundle(path).bundle
    assert bundle is not None
    assert scope_matches(bundle, source_lang="ja", target_lang="zh-CN") is True
    assert scope_matches(bundle, source_lang="en", target_lang="zh-CN") is False


def test_scope_matches_returns_true_when_unspecified(tmp_path: Path) -> None:
    path = _write_preset(
        tmp_path,
        "global",
        """
{"id": "global", "entries": [{"source": "AI", "target": "人工智能"}]}
        """.strip(),
    )
    bundle = load_preset_bundle(path).bundle
    assert bundle is not None
    assert scope_matches(bundle, source_lang="en", target_lang="zh-CN") is True


def test_materialize_entries_applies_default_status_and_tags_preset(tmp_path: Path) -> None:
    path = _write_preset(
        tmp_path,
        "nold",
        """
{
  "id": "nold",
  "default_status": "locked",
  "entries": [
    {"source": "Tom", "target": "汤姆", "category": "name"},
    {"source": "Cooper", "target": "库珀", "category": "name", "status": "confirmed"}
  ]
}
        """.strip(),
    )
    bundle = load_preset_bundle(path).bundle
    assert bundle is not None
    entries = materialize_entries(bundle)
    statuses = {entry.source: entry.status for entry in entries}
    assert statuses == {"Tom": "locked", "Cooper": "confirmed"}
    constraints = {entry.source: entry.constraint for entry in entries}
    assert constraints == {"Tom": "must_use", "Cooper": "must_use"}
    assert all(entry.source_preset == "nold" for entry in entries)


def test_materialize_entries_override_status_takes_precedence(tmp_path: Path) -> None:
    path = _write_preset(
        tmp_path,
        "soft_glossary",
        """
{
  "id": "soft_glossary",
  "default_status": "proposed",
  "entries": [
    {"source": "X", "target": "X1", "status": "confirmed"}
  ]
}
        """.strip(),
    )
    bundle = load_preset_bundle(path).bundle
    assert bundle is not None
    promoted = materialize_entries(bundle, override_status="locked")
    assert promoted[0].status == "locked"


def test_build_selected_presets_snapshot_filters_scope_and_records_hash(tmp_path: Path) -> None:
    _write_preset(
        tmp_path,
        "rezero",
        """
{
  "id": "rezero",
  "scope": {"language_pairs": ["ja->zh-CN"]},
  "default_status": "confirmed",
  "entries": [
    {"source": "スバル", "target": "昴", "category": "name"}
  ]
}
        """.strip(),
    )
    _write_preset(
        tmp_path,
        "nold",
        """
{
  "id": "nold",
  "scope": {"language_pairs": ["en->zh-CN"]},
  "default_status": "locked",
  "entries": [
    {"source": "Tom", "target": "汤姆"}
  ]
}
        """.strip(),
    )
    presets = [MemoryPresetRef(id="rezero"), MemoryPresetRef(id="nold")]
    snapshot = build_selected_presets_snapshot(
        presets=presets,
        root_dir=tmp_path,
        source_lang="ja",
        target_lang="zh-CN",
    )
    sources = [entry["source"] for entry in snapshot["entries"]]
    assert sources == ["スバル"]
    applied_ids = {row["preset"] for row in snapshot["report"]["applied"]}
    skipped_ids = {row["preset"] for row in snapshot["report"]["skipped"]}
    assert applied_ids == {"rezero"}
    assert skipped_ids == {"nold"}
    applied = snapshot["report"]["applied"][0]
    assert applied["hash"].startswith("sha256:")
    assert snapshot["source_lang"] == "ja"
    assert snapshot["target_lang"] == "zh-CN"


def test_build_selected_presets_snapshot_records_normalized_duplicate_source(tmp_path: Path) -> None:
    _write_preset(
        tmp_path,
        "first",
        """
{"id": "first", "default_status": "locked", "entries": [{"source": "The   Order", "target": "教团"}]}
        """.strip(),
    )
    _write_preset(
        tmp_path,
        "second",
        """
{"id": "second", "default_status": "locked", "entries": [{"source": "the order", "target": "结社"}]}
        """.strip(),
    )
    snapshot = build_selected_presets_snapshot(
        presets=[MemoryPresetRef(id="first"), MemoryPresetRef(id="second")],
        root_dir=tmp_path,
        source_lang="en",
        target_lang="zh-CN",
    )
    targets = [entry["target"] for entry in snapshot["entries"]]
    assert targets == ["教团"]
    duplicate_errors = [row for row in snapshot["report"]["errors"] if row.get("reason") == "duplicate_source"]
    assert duplicate_errors and duplicate_errors[0]["preset"] == "second"


def test_build_selected_presets_snapshot_returns_empty_when_no_presets(tmp_path: Path) -> None:
    snapshot = build_selected_presets_snapshot(
        presets=[],
        root_dir=tmp_path,
        source_lang="en",
        target_lang="zh-CN",
    )
    assert snapshot["entries"] == []
    assert snapshot["report"]["entries"] == 0
    assert snapshot["report"]["applied"] == []
    assert snapshot["report"]["skipped"] == []
    assert snapshot["report"]["errors"] == []


def test_build_selected_presets_snapshot_fails_missing_preset_id(tmp_path: Path) -> None:
    try:
        build_selected_presets_snapshot(
            presets=[MemoryPresetRef(id="ghost")],
            root_dir=tmp_path,
            source_lang="en",
            target_lang="zh-CN",
        )
    except MemoryPresetError as exc:
        assert "ghost" in str(exc)
    else:  # pragma: no cover - assertion branch
        raise AssertionError("expected missing preset to fail")


def test_discover_preset_bundles_lists_only_valid_files(tmp_path: Path) -> None:
    _write_preset(
        tmp_path,
        "ok",
        """
{"id": "ok", "entries": [{"source": "X", "target": "X1"}]}
        """.strip(),
    )
    (tmp_path / "memory" / "presets" / "broken.json").write_text("not json", encoding="utf-8")
    bundles = discover_preset_bundles(tmp_path)
    assert [bundle.id for bundle in bundles] == ["ok"]
