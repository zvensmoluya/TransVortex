from __future__ import annotations

from pathlib import Path

from transvortex.app.models import MemoryPresetRef
from transvortex.memory.presets import (
    MemoryPresetError,
    build_selected_presets_snapshot,
    discover_preset_bundles,
    load_preset_bundle,
    materialize_entries,
    scope_matches,
)


def _write_preset(root: Path, name: str, payload: str) -> Path:
    presets_dir = root / "memory" / "presets"
    presets_dir.mkdir(parents=True, exist_ok=True)
    path = presets_dir / f"{name}.json"
    path.write_text(payload, encoding="utf-8")
    return path


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
