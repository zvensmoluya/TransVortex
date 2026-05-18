from __future__ import annotations

from pathlib import Path

from transvortex.app.models import Chunk, MemoryInjectConfig, Segment
from transvortex.app.models import AppConfig, PipelineConfig, ProviderConfig, RouteTarget, RoutingConfig
from transvortex.core.translate import iter_translate_all_chunks
from transvortex.memory.checker import check_consistency
from transvortex.memory.injector import build_memory_prompt
from transvortex.memory.merger import merge_patch, patch_from_payload
from transvortex.memory.schema import MemoryAlias, MemoryDocument, MemoryEntry, MemoryTargetVariant
from transvortex.memory.selector import select_memory_entries
from transvortex.memory.store import MemoryStore
from transvortex.memory.bootstrapper import bootstrap_memory


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


def test_memory_store_load_effective_combines_presets_and_runtime_with_preset_priority(tmp_path: Path) -> None:
    store = MemoryStore(tmp_path / "memory")
    store.save_selected_presets(
        {
            "version": 1,
            "source_lang": "en",
            "target_lang": "zh-CN",
            "report": {"applied": [], "skipped": [], "errors": [], "entries": 2},
            "entries": [
                {
                    "id": "preset_subaru",
                    "source": "Subaru",
                    "target": "斯巴鲁",
                    "status": "locked",
                    "source_preset": "anime",
                },
                {
                    "id": "preset_order",
                    "source": "The Order",
                    "target": "教团",
                    "status": "confirmed",
                    "source_preset": "anime",
                },
            ],
        }
    )
    store.save(
        MemoryDocument(
            entries=[
                MemoryEntry(id="runtime_subaru", source="subaru", target="昴", status="confirmed"),
                MemoryEntry(id="runtime_alpha", source="Alpha", target="阿尔法", status="proposed"),
            ]
        )
    )

    effective = store.load_effective()
    assert [(entry.source, entry.target) for entry in effective.entries] == [
        ("Subaru", "斯巴鲁"),
        ("The Order", "教团"),
        ("Alpha", "阿尔法"),
    ]
    assert [entry.source for entry in store.load_runtime().entries] == ["subaru", "Alpha"]


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
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="matched", max_entries_per_chunk=3))
    assert [entry.source for entry in selected] == ["Subaru", "The Order", "Mercury"]
    prompt = build_memory_prompt(selected)
    assert "LOCKED TERMS" in prompt
    assert "Subaru => 斯巴鲁" in prompt
    assert "CONFIRMED MEMORY" in prompt
    assert "PROPOSED HINTS" in prompt


def test_memory_v2_selector_and_injector_group_variants_by_use() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="1",
                source="エミリア",
                target="爱蜜莉雅",
                status="locked",
                alias_details=[MemoryAlias(source="エミリア様", kind="honorific")],
                target_variants=[
                    MemoryTargetVariant(source="エミリアタン", target="爱蜜莉雅碳", kind="nickname"),
                ],
                memory_type="entity",
                constraint="must_use",
                priority=100,
            ),
            MemoryEntry(
                id="2",
                source="スバル",
                target="昴",
                status="locked",
                alias_details=[MemoryAlias(source="スヴァル", kind="asr_error")],
                memory_type="entity",
                constraint="must_use",
                priority=90,
            ),
            MemoryEntry(
                id="3",
                source="死者の書",
                target="死者之书",
                status="proposed",
                alias_details=[MemoryAlias(source="死者の過去を追体験する本", kind="broad_hint")],
                memory_type="concept_hint",
                constraint="hint",
            ),
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] エミリアタンとスヴァルは死者の過去を追体験する本を見た"],
    )

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="matched", max_entries_per_chunk=10))
    prompt = build_memory_prompt(selected)

    assert [entry.source for entry in selected] == ["エミリア", "スバル", "死者の書"]
    assert "LOCKED TERMS" in prompt
    assert "ADDRESS VARIANTS" in prompt
    assert "エミリアタン => 爱蜜莉雅碳; canonical: エミリア => 爱蜜莉雅; kind: nickname" in prompt
    assert "ASR CORRECTION HINTS" in prompt
    assert "スヴァル => 昴; canonical: スバル; kind: asr_error" in prompt
    assert "CONCEPT HINTS" in prompt
    assert "死者の過去を追体験する本 => 死者之书; canonical: 死者の書; kind: broad_hint" in prompt


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
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="matched", max_entries_per_chunk=10))
    assert [entry.source for entry in selected] == ["The Order"]


def test_selector_matches_cjk_terms_without_word_boundaries() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="スバル", target="昴", status="locked", priority=100),
            MemoryEntry(id="2", source="エミリア", target="爱蜜莉雅", status="locked", priority=90, aliases=["エミリア様"]),
            MemoryEntry(id="3", source="足", target="脚力", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] スバルはエミリア様を見た"],
    )

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="matched", max_entries_per_chunk=10))

    assert [entry.source for entry in selected] == ["スバル", "エミリア"]


def test_selector_balanced_injects_strong_memory_without_match() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Unseen Proposed", target="候选", status="proposed", priority=100),
            MemoryEntry(id="4", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="balanced", max_entries_per_chunk=10))
    assert [entry.source for entry in selected] == ["Unseen Locked", "Unseen Confirmed", "Mercury"]


def test_selector_matched_requires_match_for_strong_memory() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="matched", max_entries_per_chunk=10))
    assert [entry.source for entry in selected] == ["Mercury"]


def test_selector_full_keeps_proposed_matched_only() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Unseen Proposed", target="候选", status="proposed", priority=100),
            MemoryEntry(id="4", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="full", max_entries_per_chunk=10))
    assert [entry.source for entry in selected] == ["Unseen Locked", "Unseen Confirmed", "Mercury"]


def test_selector_balanced_filters_confirmed_when_over_limit() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Alpha", target="阿尔法", status="confirmed", priority=100),
            MemoryEntry(id="2", source="Beta", target="贝塔", status="confirmed", priority=90),
            MemoryEntry(id="3", source="Gamma", target="伽马", status="confirmed", priority=80),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Alpha arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="balanced", max_entries_per_chunk=2))
    assert [entry.source for entry in selected] == ["Alpha"]


def test_selector_strategy_fallback_and_limit() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Locked A", target="A", status="locked", priority=100),
            MemoryEntry(id="2", source="Locked B", target="B", status="locked", priority=90),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Nothing relevant"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="unknown", max_entries_per_chunk=1))
    assert [entry.source for entry in selected] == ["Locked A"]
    assert select_memory_entries(doc, chunk, MemoryInjectConfig(strategy="full", max_entries_per_chunk=0)) == []


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


def test_merger_protects_preset_entries_without_writing_runtime_duplicate(tmp_path: Path) -> None:
    store = MemoryStore(tmp_path / "memory")
    runtime_doc = MemoryDocument(entries=[MemoryEntry(id="runtime_subaru", source="subaru", target="昴", status="confirmed")])
    preset_entries = [MemoryEntry(id="preset_subaru", source="Subaru", target="斯巴鲁", status="locked", source_preset="anime")]
    same_patch = patch_from_payload(
        {"chunk_ids": ["c1"], "actions": [{"action": "upsert", "source": "Subaru", "target": "斯巴鲁"}]}
    )
    merged, conflicts = merge_patch(runtime_doc, same_patch, store=store, protected_entries=preset_entries)
    assert [entry.target for entry in merged.entries] == ["昴"]
    assert conflicts == []

    conflict_patch = patch_from_payload(
        {"chunk_ids": ["c2"], "actions": [{"action": "upsert", "source": "Subaru", "target": "昴"}]}
    )
    merged, conflicts = merge_patch(runtime_doc, conflict_patch, store=store, protected_entries=preset_entries)
    assert [entry.target for entry in merged.entries] == ["昴"]
    assert conflicts[0].reason == "preset entry cannot be overwritten"
    assert "preset entry cannot be overwritten" in store.conflicts_file.read_text(encoding="utf-8")


def test_merger_preserves_v2_alias_details_and_target_variants() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_emilia",
                source="エミリア",
                target="爱蜜莉雅",
                status="proposed",
                alias_details=[MemoryAlias(source="エミリア様", kind="honorific")],
            )
        ]
    )
    patch = patch_from_payload(
        {
            "chunk_ids": ["c1"],
            "actions": [
                {
                    "action": "upsert",
                    "source": "エミリア",
                    "target": "爱蜜莉雅",
                    "status": "proposed",
                    "memory_type": "entity",
                    "constraint": "preferred",
                    "alias_details": [{"source": "エミリアたん", "kind": "nickname"}],
                    "target_variants": [{"source": "エミリアたん", "target": "爱蜜莉雅碳", "kind": "nickname"}],
                    "evidence_ids": [1],
                }
            ],
        }
    )

    merged, conflicts = merge_patch(doc, patch)
    entry = merged.entries[0]

    assert conflicts == []
    assert [(alias.source, alias.kind) for alias in entry.alias_details] == [
        ("エミリア様", "honorific"),
        ("エミリアたん", "nickname"),
    ]
    assert [(variant.source, variant.target, variant.kind) for variant in entry.target_variants] == [
        ("エミリアたん", "爱蜜莉雅碳", "nickname")
    ]
    assert entry.memory_type == "entity"
    assert entry.constraint == "preferred"


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


def test_consistency_check_matches_cjk_terms_without_word_boundaries() -> None:
    doc = MemoryDocument(entries=[MemoryEntry(id="mem_subaru", source="スバル", target="昴", status="locked")])

    issues = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="スバルは来た", text_tgt="斯巴鲁来了")],
    )

    assert len(issues) == 1
    assert issues[0].expected_target == "昴"


def test_consistency_check_accepts_target_variants_for_address_forms() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_emilia",
                source="エミリア",
                target="爱蜜莉雅",
                status="locked",
                target_variants=[MemoryTargetVariant(source="エミリアタン", target="爱蜜莉雅碳", kind="nickname")],
                constraint="must_use",
            )
        ]
    )

    issues = check_consistency(
        doc,
        [
            Segment(id=1, start=0, end=1, text_src="エミリアタンだよ", text_tgt="爱蜜莉雅碳来了"),
            Segment(id=2, start=1, end=2, text_src="エミリアタンだよ", text_tgt="爱蜜莉雅来了"),
            Segment(id=3, start=2, end=3, text_src="エミリアタンだよ", text_tgt="艾米莉娅来了"),
        ],
    )

    assert len(issues) == 1
    assert issues[0].issue_type == "variant_miss"
    assert issues[0].level == "suggestion"
    assert issues[0].matched_source == "エミリアタン"
    assert issues[0].expected_variants == ["爱蜜莉雅", "爱蜜莉雅碳"]


def test_consistency_check_asr_alias_uses_canonical_target_without_literal_alias_pressure() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_subaru",
                source="スバル",
                target="昴",
                status="locked",
                alias_details=[MemoryAlias(source="スヴァル", kind="asr_error")],
                constraint="must_use",
            )
        ]
    )

    ok = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="スヴァルは来た", text_tgt="昴来了")],
    )
    missing = check_consistency(
        doc,
        [Segment(id=2, start=1, end=2, text_src="スヴァルは来た", text_tgt="斯巴鲁来了")],
    )

    assert ok == []
    assert len(missing) == 1
    assert missing[0].issue_type == "hint_miss"
    assert missing[0].level == "suggestion"
    assert missing[0].matched_kind == "asr_error"


def test_consistency_check_asr_alias_accepts_known_entity_variants() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_emilia",
                source="エミリア",
                target="爱蜜莉雅",
                status="locked",
                alias_details=[MemoryAlias(source="エミリヤ", kind="asr_error")],
                target_variants=[MemoryTargetVariant(source="エミリアタン", target="爱蜜莉雅碳", kind="nickname")],
                constraint="must_use",
            )
        ]
    )

    issues = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="エミリヤが来た", text_tgt="爱蜜莉雅碳来了")],
    )

    assert issues == []


def test_consistency_check_concept_hint_is_suggestion_only() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_book",
                source="死者の書",
                target="死者之书",
                status="locked",
                memory_type="concept_hint",
                constraint="hint",
            )
        ]
    )

    issues = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="死者の書を読んだ", text_tgt="读了那本书")],
    )

    assert len(issues) == 1
    assert issues[0].issue_type == "hint_miss"
    assert issues[0].level == "suggestion"


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
        assert [chunk.chunk_id for chunk in window] == ["c1"]
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


def test_memory_bootstrap_writes_artifacts_and_merges_memory(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    segments = [Segment(id=1, start=0, end=1, text_src="Subaru arrives")]

    class FakeClient:
        def translate_request(self, req):
            assert req.prompt_mode == "memory_patch"
            assert "FULL SOURCE SUBTITLES" in req.style_prompt
            return type(
                "Response",
                (),
                {
                    "raw_text": (
                        '{"chunk_ids":["bootstrap"],"actions":[{"action":"upsert",'
                        '"source":"Subaru","target":"斯巴鲁","category":"name",'
                        '"status":"proposed","confidence":0.95,"evidence_ids":[1]}]}'
                    )
                },
            )()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())

    payload = bootstrap_memory(
        config,
        segments,
        source_lang="en",
        target_lang="zh-CN",
        memory_dir=tmp_path / "memory",
    )

    assert payload["status"] == "completed"
    assert (tmp_path / "memory" / "bootstrap.json").exists()
    assert (tmp_path / "memory" / "memory_patches.jsonl").read_text(encoding="utf-8").strip()
    doc = MemoryStore(tmp_path / "memory").load()
    assert any(entry.source == "Subaru" and entry.target == "斯巴鲁" for entry in doc.entries)


def test_memory_bootstrap_resume_skips_existing_artifact(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    memory_dir = tmp_path / "memory"
    memory_dir.mkdir()
    (memory_dir / "bootstrap.json").write_text('{"status":"completed","actions":[]}', encoding="utf-8")
    called = False

    def fake_build_provider_client(_provider):
        nonlocal called
        called = True

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", fake_build_provider_client)

    payload = bootstrap_memory(
        config,
        [Segment(id=1, start=0, end=1, text_src="Subaru")],
        source_lang="en",
        target_lang="zh-CN",
        memory_dir=memory_dir,
    )

    assert payload["status"] == "completed"
    assert called is False


def test_memory_patch_batches_by_window_chunks(tmp_path: Path, monkeypatch) -> None:
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
    config.pipeline.memory.patch.window_chunks = 3
    chunks = [Chunk(chunk_id=f"c{i}", segment_ids=[i], lines=[f"[{i}] Term {i}"]) for i in range(5)]
    patch_windows: list[list[str]] = []

    def fake_translate_chunk(_config, chunk, source_lang: str, target_lang: str, memory_prompt: str = ""):
        return {
            "chunk_id": chunk.chunk_id,
            "provider": "p1",
            "model": "m1",
            "rows": [{"id": chunk.segment_ids[0], "text_tgt": f"译文 {chunk.segment_ids[0]}"}],
            "errors": [],
        }

    def fake_generate_memory_patch(_config, window, translated_rows, *, source_lang: str, target_lang: str):
        patch_windows.append([chunk.chunk_id for chunk in window])
        payload = {"chunk_ids": [chunk.chunk_id for chunk in window], "actions": []}
        from transvortex.memory.merger import patch_from_payload

        return patch_from_payload(payload), payload

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)
    monkeypatch.setattr("transvortex.core.translate.generate_memory_patch", fake_generate_memory_patch)

    list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))

    assert patch_windows == [["c0", "c1", "c2"], ["c3", "c4"]]
