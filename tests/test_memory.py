from __future__ import annotations

from pathlib import Path

from transvortex.app.models import Chunk, MemoryInjectConfig, Segment
from transvortex.app.models import AppConfig, PipelineConfig, ProviderConfig, RouteTarget, RoutingConfig
from transvortex.core.translate import iter_translate_all_chunks
from transvortex.memory.checker import check_consistency
from transvortex.memory.injector import build_memory_prompt
from transvortex.memory.merger import merge_patch, patch_from_payload
from transvortex.memory.schema import MemoryDocument, MemoryEntry
from transvortex.memory.selector import select_memory_entries
from transvortex.memory.store import MemoryStore


def test_memory_store_reads_empty_and_preserves_locked(tmp_path: Path) -> None:
    store = MemoryStore(tmp_path / "memory")
    doc = store.load()
    assert doc.entries == []
    locked = MemoryEntry(
        id="mem_subaru",
        source="Subaru",
        target="斯巴鲁",
        status="locked",
        origin="user_glossary",
        aliases=["Sibaru"],
    )
    store.save(MemoryDocument(entries=[locked]))
    loaded = store.load()
    assert loaded.entries[0].status == "locked"
    assert loaded.entries[0].aliases == ["Sibaru"]
    snapshot = store.write_snapshot(loaded, 1)
    assert snapshot.exists()


def test_selector_and_injector_group_relevant_entries() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Subaru", target="斯巴鲁", status="locked", priority=100),
            MemoryEntry(id="2", source="The Order", target="教团", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Mercury", target="墨丘利", status="proposed", priority=10),
            MemoryEntry(id="4", source="Unrelated", target="无关", status="locked", priority=100),
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] Subaru meets Mercury"],
        context_before=[],
        context_after=["[2] The Order appears"],
    )
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(max_entries_per_chunk=3))
    assert [entry.source for entry in selected] == ["Subaru", "The Order", "Mercury"]
    prompt = build_memory_prompt(selected)
    assert "LOCKED GLOSSARY" in prompt
    assert "Subaru => 斯巴鲁" in prompt
    assert "CONFIRMED MEMORY" in prompt
    assert "PROPOSED HINTS" in prompt


def test_selector_avoids_short_or_embedded_false_matches() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="AI", target="人工智能", status="locked", priority=100),
            MemoryEntry(id="2", source="May", target="梅", status="locked", priority=100),
            MemoryEntry(id="3", source="The Order", target="教团", status="locked", priority=100),
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] The mayor joined The Order"],
    )
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(max_entries_per_chunk=10))
    assert [entry.source for entry in selected] == ["The Order"]


def test_merger_protects_locked_and_records_conflict(tmp_path: Path) -> None:
    store = MemoryStore(tmp_path / "memory")
    doc = MemoryDocument(entries=[MemoryEntry(id="mem_subaru", source="Subaru", target="斯巴鲁", status="locked")])
    patch = patch_from_payload(
        {
            "chunk_ids": ["c1"],
            "actions": [
                {"action": "upsert", "source": "Subaru", "target": "昴", "category": "character"},
                {"action": "upsert", "source": "The Order", "target": "教团", "category": "organization", "evidence_ids": [2]},
            ],
        }
    )
    merged, conflicts = merge_patch(doc, patch, store=store)
    assert next(entry for entry in merged.entries if entry.source == "Subaru").target == "斯巴鲁"
    assert next(entry for entry in merged.entries if entry.source == "The Order").target == "教团"
    assert conflicts[0].source == "Subaru"
    assert store.conflicts_file.read_text(encoding="utf-8").strip()


def test_consistency_check_reports_missing_locked_translation() -> None:
    doc = MemoryDocument(entries=[MemoryEntry(id="mem_subaru", source="Subaru", target="斯巴鲁", status="locked")])
    issues = check_consistency(
        doc,
        [
            Segment(id=1, start=0, end=1, text_src="Subaru is here", text_tgt="昴来了"),
            Segment(id=2, start=1, end=2, text_src="Hello", text_tgt="你好"),
        ],
    )
    assert len(issues) == 1
    assert issues[0].expected_target == "斯巴鲁"


def test_consistency_check_avoids_embedded_false_matches() -> None:
    doc = MemoryDocument(entries=[MemoryEntry(id="mem_may", source="May", target="梅", status="locked")])
    issues = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="The mayor is here", text_tgt="市长来了")],
    )
    assert issues == []


def test_memory_patch_runs_for_successful_results_when_window_later_fails(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path, default_concurrency=1),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    config.pipeline.memory.enabled = True
    config.pipeline.memory.mode = "balanced"
    chunks = [
        Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Alpha"]),
        Chunk(chunk_id="c2", segment_ids=[2], lines=["[2] Beta"]),
    ]

    def fake_translate_chunk(_config, chunk, source_lang: str, target_lang: str, memory_prompt: str = ""):
        if chunk.chunk_id == "c2":
            raise RuntimeError("translation failed")
        return {
            "chunk_id": chunk.chunk_id,
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": 1, "text_tgt": "阿尔法"}],
            "errors": [],
        }

    def fake_generate_memory_patch(_config, window, translated_rows, *, source_lang: str, target_lang: str):
        assert [row["chunk_id"] for row in translated_rows] == ["c1"]
        payload = {
            "chunk_ids": ["c1"],
            "actions": [{"action": "upsert", "source": "Alpha", "target": "阿尔法"}],
        }
        from transvortex.memory.merger import patch_from_payload

        return patch_from_payload(payload), payload

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)
    monkeypatch.setattr("transvortex.core.translate.generate_memory_patch", fake_generate_memory_patch)
    try:
        list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))
    except RuntimeError as exc:
        assert "translation failed" in str(exc)
    else:
        raise AssertionError("expected translation failure")
    doc = MemoryStore(tmp_path / "memory").load()
    assert any(entry.source == "Alpha" for entry in doc.entries)
