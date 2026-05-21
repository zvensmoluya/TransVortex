from __future__ import annotations

from pathlib import Path

from transvortex.app.models import Chunk, MemoryInjectConfig, Segment
from transvortex.app.models import AppConfig, PipelineConfig, ProviderConfig, RouteTarget, RoutingConfig
from transvortex.core.translate import _memory_prompt_entry_count, iter_translate_all_chunks
from transvortex.memory.checker import check_consistency
from transvortex.memory.injector import build_memory_prompt
from transvortex.memory.json_utils import json_object_from_model_text
from transvortex.memory.merger import merge_patch, patch_from_payload
from transvortex.memory.schema import MemoryAlias, MemoryDocument, MemoryEntry, MemoryTargetVariant
from transvortex.memory.schema import entry_from_dict
from transvortex.memory.selector import select_memory_entries
from transvortex.memory.store import MemoryStore
from transvortex.memory.validator import MemoryEvidence, validate_memory_payload
from transvortex.memory.bootstrapper import bootstrap_memory
from transvortex.memory.bootstrap_input import build_bootstrap_input_view, render_bootstrap_input_text


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

    effective = store.load_effective(("presets", "runtime"))
    assert [(entry.source, entry.target) for entry in effective.entries] == [
        ("Subaru", "斯巴鲁"),
        ("The Order", "教团"),
        ("Alpha", "阿尔法"),
    ]
    assert [entry.source for entry in store.load_runtime().entries] == ["subaru", "Alpha"]


def test_memory_schema_v11_roundtrip_optional_fields() -> None:
    entry = entry_from_dict(
        {
            "id": "mem_beatrice",
            "source": "ベアトリス",
            "target": "碧翠丝",
            "status": "proposed",
            "confidence_breakdown": {"source": 0.9, "target": "0.7", "bad": "x"},
            "provenance": [{"kind": "bootstrap", "source_evidence": "source_only"}],
            "scope": {"source_lang": "ja", "target_lang": "zh-CN"},
            "variant_of": "",
            "variant_of_entry_id": "mem_parent",
            "enforcement_policy": {"translation": "preferred", "qa": "warning"},
            "target_variants": [
                {
                    "source": "ベア子",
                    "target": "贝子",
                    "kind": "nickname",
                    "confidence": 0.86,
                    "speaker_scope": {"speaker": "スバル"},
                    "notes": "affectionate",
                }
            ],
        }
    )

    assert entry.confidence_breakdown == {"source": 0.9, "target": 0.7}
    assert entry.provenance[0]["kind"] == "bootstrap"
    assert entry.scope["target_lang"] == "zh-CN"
    assert entry.variant_of_entry_id == "mem_parent"
    assert entry.enforcement_policy["translation"] == "preferred"
    assert entry.target_variants[0].speaker_scope == {"speaker": "スバル"}
    assert entry.target_variants[0].notes == "affectionate"


def test_memory_prompt_entry_count_supports_v1_and_v2_rows() -> None:
    v2_prompt = (
        "TRANSLATION MEMORY\n"
        "Use according to policy.\n\n"
        "MUST_USE\n"
        "- Subaru -> 昴 | policy: exact\n"
        "- Emilia -> 爱蜜莉雅 | policy: preferred\n\n"
        "WEAK_HINTS\n"
        "- hint: ロズっち | canonical: ロズワール | target: 罗兹亲"
    )
    v1_prompt = (
        "LOCKED TERMS\n"
        "- Subaru => 昴\n"
        "- Emilia => 爱蜜莉雅\n\n"
        "ADDRESS VARIANTS\n"
        "- エミリアタン => 爱蜜莉雅碳; canonical: エミリア => 爱蜜莉雅"
    )

    assert _memory_prompt_entry_count(v2_prompt) == 3
    assert _memory_prompt_entry_count(v1_prompt) == 3


def test_json_object_from_model_text_accepts_fence_and_wrapped_json() -> None:
    assert json_object_from_model_text('{"actions":[]}') == {"actions": []}
    assert json_object_from_model_text('```json\n{"actions":[]}\n```') == {"actions": []}
    assert json_object_from_model_text('Here:\n{"actions":[]}\nDone') == {"actions": []}


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
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))
    assert [entry.source for entry in selected] == ["Subaru", "Mercury"]
    prompt = build_memory_prompt(selected)
    assert "MATCHED_IN_TRANSLATE_ONLY" in prompt
    assert "matched: Subaru" in prompt
    assert "target: 斯巴鲁" in prompt
    assert "matched: Mercury" in prompt
    assert "target: 墨丘利" in prompt
    assert "The Order" not in prompt


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

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))
    prompt = build_memory_prompt(selected)

    assert [entry.source for entry in selected] == ["エミリア", "スバル"]
    assert "MATCHED_IN_TRANSLATE_ONLY" in prompt
    assert "matched: エミリアタン" in prompt
    assert "target: 爱蜜莉雅碳" in prompt
    assert "matched: スヴァル" in prompt
    assert "target: 昴" in prompt
    assert "WEAK_HINTS" not in prompt
    assert "matched: 死者の過去を追体験する本" not in prompt


def test_selector_does_not_reuse_same_kind_variant_target_for_alias() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="1",
                source="エミリア",
                target="爱蜜莉雅",
                status="locked",
                alias_details=[MemoryAlias(source="エミリア様", kind="honorific")],
                target_variants=[
                    MemoryTargetVariant(
                        source="エミリア殿",
                        target="爱蜜莉雅大人",
                        kind="honorific",
                        notes="respectful address",
                    )
                ],
                constraint="must_use",
                notes="main heroine",
            )
        ]
    )

    alias_chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] エミリア様が来た"])
    alias_prompt = build_memory_prompt(
        select_memory_entries(doc, alias_chunk, MemoryInjectConfig(intensity="low"))
    )

    assert "matched: エミリア様" in alias_prompt
    assert "canonical_target: 爱蜜莉雅" in alias_prompt
    assert "policy: style_sensitive_unresolved" in alias_prompt
    assert "target_variant: missing" in alias_prompt
    assert "infer natural Chinese address flavor from source/context" in alias_prompt
    assert "note: main heroine" in alias_prompt
    assert "爱蜜莉雅大人" not in alias_prompt
    assert "target_variant: true" not in alias_prompt

    variant_chunk = Chunk(chunk_id="c2", segment_ids=[2], lines=["[2] エミリア殿が来た"])
    variant_prompt = build_memory_prompt(
        select_memory_entries(doc, variant_chunk, MemoryInjectConfig(intensity="low"))
    )

    assert "matched: エミリア殿" in variant_prompt
    assert "target: 爱蜜莉雅大人" in variant_prompt
    assert "target_variant: true" in variant_prompt
    assert "variant_note: respectful address" in variant_prompt


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
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))
    assert [entry.source for entry in selected] == ["The Order"]


def test_selector_demotes_generic_aliases() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="1",
                source="大図書館プレイアデス",
                target="普雷阿得斯大图书馆",
                status="proposed",
                alias_details=[MemoryAlias(source="この塔", kind="broad_hint")],
                constraint="hint",
            ),
            MemoryEntry(id="2", source="スバル", target="昴", status="locked"),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] この塔でスバルを待つ"])

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))

    assert [entry.source for entry in selected] == ["スバル"]


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

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))

    assert {entry.source for entry in selected} == {"スバル", "エミリア"}


def test_selector_high_injects_strong_memory_without_match() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Unseen Proposed", target="候选", status="proposed", priority=100),
            MemoryEntry(id="4", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="high"))
    assert [entry.source for entry in selected] == ["Unseen Locked", "Unseen Confirmed", "Mercury"]


def test_selector_low_requires_direct_translate_match_for_strong_memory() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))
    assert [entry.source for entry in selected] == ["Mercury"]


def test_selector_low_skips_weak_direct_hints() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="1",
                source="WeakTerm",
                target="弱提示",
                status="proposed",
                constraint="hint",
                priority=100,
                enforcement_policy={"translation": "context_only"},
            ),
            MemoryEntry(id="2", source="StrongTerm", target="强术语", status="confirmed", priority=90),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] WeakTerm and StrongTerm appear"])

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="low"))

    assert [entry.source for entry in selected] == ["StrongTerm"]


def test_selector_max_keeps_strong_background_and_matched_proposed_only() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Unseen Locked", target="锁定", status="locked", priority=100),
            MemoryEntry(id="2", source="Unseen Confirmed", target="确认", status="confirmed", priority=50),
            MemoryEntry(id="3", source="Unseen Proposed", target="候选", status="proposed", priority=100),
            MemoryEntry(id="4", source="Mercury", target="墨丘利", status="proposed", priority=10),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Mercury arrives"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="max"))
    assert [entry.source for entry in selected] == ["Unseen Locked", "Unseen Confirmed", "Mercury"]


def test_selector_max_keeps_preferred_and_must_use_background() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Preferred Background", target="优先背景", status="proposed", constraint="preferred", priority=100),
            MemoryEntry(id="2", source="Must Background", target="必须背景", status="proposed", constraint="must_use", priority=90),
            MemoryEntry(id="3", source="Hint Background", target="提示背景", status="proposed", constraint="hint", priority=80),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] no direct term"])

    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="max"))

    assert [entry.source for entry in selected] == ["Must Background", "Preferred Background"]


def test_selector_keeps_all_direct_matches_without_entry_cap() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id=str(i), source=f"Term{i}", target=f"术语{i}", status="proposed", priority=100 - i)
            for i in range(1, 35)
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] " + " ".join(f"Term{i}" for i in range(1, 35))])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="high"))
    assert len(selected) == 34
    assert {entry.source for entry in selected} == {f"Term{i}" for i in range(1, 35)}


def test_selector_and_injector_none_intensity_disable_memory() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id="1", source="Locked A", target="A", status="locked", priority=100),
            MemoryEntry(id="2", source="Locked B", target="B", status="locked", priority=90),
        ]
    )
    chunk = Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Locked A"])
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="none"))
    assert selected == []
    assert build_memory_prompt(select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="none")), MemoryInjectConfig(intensity="none")) == ""


def test_injector_intensity_controls_context_row_budget() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id=str(i), source=f"CtxTerm{i}", target=f"上下文{i}", status="confirmed", priority=100 - i)
            for i in range(1, 61)
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] no direct term"],
        context_before=["[0] " + " ".join(f"CtxTerm{i}" for i in range(1, 61))],
    )
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="max", max_prompt_tokens=20000))

    auto_prompt = build_memory_prompt(selected, MemoryInjectConfig(intensity="auto", max_prompt_tokens=20000))
    high_prompt = build_memory_prompt(selected, MemoryInjectConfig(intensity="high", max_prompt_tokens=20000))
    max_prompt = build_memory_prompt(selected, MemoryInjectConfig(intensity="max", max_prompt_tokens=20000))

    assert auto_prompt.count("- matched: CtxTerm") == 16
    assert high_prompt.count("- matched: CtxTerm") == 48
    assert max_prompt.count("- matched: CtxTerm") == 60


def test_injector_max_intensity_still_respects_prompt_budget() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(id=str(i), source=f"BudgetTerm{i}", target=f"预算{i}", status="confirmed", priority=100 - i)
            for i in range(1, 30)
        ]
    )
    chunk = Chunk(
        chunk_id="c1",
        segment_ids=[1],
        lines=["[1] no direct term"],
        context_before=["[0] " + " ".join(f"BudgetTerm{i}" for i in range(1, 30))],
    )
    selected = select_memory_entries(doc, chunk, MemoryInjectConfig(intensity="max", max_prompt_tokens=20000))
    full_prompt = build_memory_prompt(selected, MemoryInjectConfig(intensity="max", max_prompt_tokens=20000))
    budgeted_prompt = build_memory_prompt(selected, MemoryInjectConfig(intensity="max", max_prompt_tokens=160))

    assert full_prompt.count("- matched: BudgetTerm") == 29
    assert 0 < budgeted_prompt.count("- matched: BudgetTerm") < 29


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
                    "confidence_breakdown": {"source": 0.9},
                    "provenance": [{"kind": "patch"}],
                    "scope": {"episode_id": "s04e05"},
                    "enforcement_policy": {"translation": "preferred", "qa": "warning"},
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
    assert entry.confidence_breakdown == {"source": 0.9}
    assert entry.provenance == [{"kind": "patch"}]
    assert entry.scope == {"episode_id": "s04e05"}
    assert entry.enforcement_policy == {"translation": "preferred", "qa": "warning"}


def test_merger_does_not_auto_confirm_from_llm_confidence() -> None:
    doc = MemoryDocument()
    patch = patch_from_payload(
        {
            "chunk_ids": ["c1"],
            "actions": [{"action": "upsert", "source": "Alpha", "target": "阿尔法", "status": "proposed", "confidence": 0.99}],
        }
    )

    merged, conflicts = merge_patch(doc, patch, auto_confirm_high_confidence=True)

    assert conflicts == []
    assert merged.entries[0].status == "proposed"


def test_memory_validator_filters_patch_without_matching_evidence() -> None:
    payload = {
        "actions": [
            {"source": "Alpha", "target": "阿尔法", "status": "confirmed", "constraint": "must_use", "evidence_ids": [1]},
            {"source": "Beta", "target": "贝塔", "evidence_ids": [2]},
            {"source": "Gamma", "target": "伽马", "evidence_ids": [9]},
        ]
    }
    evidence = MemoryEvidence(source_by_id={1: "Alpha appears", 2: "Beta appears"}, target_by_id={1: "阿尔法出现", 2: "错误译文"})

    out = validate_memory_payload(payload, mode="patch", evidence=evidence)

    assert [row["source"] for row in out["actions"]] == ["Alpha"]
    assert out["actions"][0]["status"] == "proposed"
    assert out["actions"][0]["constraint"] == "hint"


def test_memory_validator_scopes_patch_evidence_to_cited_ids() -> None:
    payload = {
        "actions": [
            {"source": "Alpha", "target": "阿尔法", "evidence_ids": [1]},
            {"source": "Alpha", "target": "合并译文", "evidence_ids": [1]},
            {"source": "Alpha", "target": "合并译文", "evidence_ids": [1, 2]},
        ]
    }
    evidence = MemoryEvidence(
        source_by_id={1: "Alpha appears", 2: "continued line"},
        target_by_id={1: "阿尔法出现", 2: "合并译文"},
    )

    out = validate_memory_payload(payload, mode="patch", evidence=evidence)

    assert [(row["target"], row["evidence_ids"]) for row in out["actions"]] == [
        ("阿尔法", [1]),
        ("合并译文", [1, 2]),
    ]


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


def test_consistency_check_does_not_reuse_same_kind_variant_for_alias() -> None:
    doc = MemoryDocument(
        entries=[
            MemoryEntry(
                id="mem_emilia",
                source="エミリア",
                target="爱蜜莉雅",
                status="locked",
                alias_details=[MemoryAlias(source="エミリア様", kind="honorific")],
                target_variants=[MemoryTargetVariant(source="エミリア殿", target="爱蜜莉雅大人", kind="honorific")],
                constraint="must_use",
            )
        ]
    )

    ok = check_consistency(
        doc,
        [Segment(id=1, start=0, end=1, text_src="エミリア様が来た", text_tgt="爱蜜莉雅来了")],
    )
    missing = check_consistency(
        doc,
        [Segment(id=2, start=1, end=2, text_src="エミリア様が来た", text_tgt="艾米莉娅来了")],
    )

    assert len(ok) == 1
    assert ok[0].issue_type == "unresolved_address_form"
    assert ok[0].severity == "info"
    assert ok[0].blocking is False
    assert ok[0].expected_variants == ["爱蜜莉雅"]
    assert len(missing) == 1
    assert missing[0].issue_type == "variant_miss"
    assert missing[0].expected_target == "爱蜜莉雅"
    assert missing[0].expected_variants == ["爱蜜莉雅"]


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

    assert len(issues) == 2
    assert issues[0].issue_type == "address_variant_flattened"
    assert issues[0].severity == "warning"
    assert issues[0].blocking is False
    assert issues[0].matched_source == "エミリアタン"
    assert issues[0].expected_variants == ["爱蜜莉雅", "爱蜜莉雅碳"]
    assert issues[1].issue_type == "variant_miss"


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


def test_consistency_check_concept_hint_is_not_exact_enforced() -> None:
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
    config.pipeline.memory.patch.enabled = True
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
    segments = [
        Segment(id=1, start=0, end=1, text_src="Subaru arrives"),
        Segment(id=2, start=4, end=4.5, text_src="uh, yeah", confidence=-1.2),
    ]
    seen_prompt = ""
    prompts: list[str] = []

    class FakeClient:
        def translate_request(self, req):
            nonlocal seen_prompt
            assert req.prompt_mode == "memory_patch"
            prompts.append(req.style_prompt)
            seen_prompt = req.style_prompt
            if len(prompts) == 1:
                assert "FULL SOURCE SUBTITLES" in req.style_prompt
                assert "flags=" in req.style_prompt
                assert "raw: Subaru arrives" in req.style_prompt
                assert "clean: yeah" in req.style_prompt
                return type(
                    "Response",
                    (),
                    {
                        "raw_text": '{"candidates":[{"surface":"Subaru","occurrence_ids":[1],"candidate_kind":"name","asr_risk":0.0,"recurrence":1}]}'
                    },
                )()
            assert "SOURCE-SIDE CANDIDATE EVIDENCE" in req.style_prompt
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
    assert payload["bootstrap_pipeline"] == "staged"
    assert payload["extract_candidates"] == 1
    assert len(prompts) == 2
    assert "SOURCE-SIDE CANDIDATE EVIDENCE" in seen_prompt
    assert (tmp_path / "memory" / "bootstrap.json").exists()
    assert (tmp_path / "memory" / "bootstrap_input.json").exists()
    assert (tmp_path / "memory" / "bootstrap_input.txt").exists()
    input_text = (tmp_path / "memory" / "bootstrap_input.txt").read_text(encoding="utf-8")
    assert "flags=possible_term" in input_text
    assert "flags=scene_gap,filler,low_info,low_confidence,uncertain" in input_text
    assert (tmp_path / "memory" / "memory_patches.jsonl").read_text(encoding="utf-8").strip()
    doc = MemoryStore(tmp_path / "memory").load()
    assert any(entry.source == "Subaru" and entry.target == "斯巴鲁" for entry in doc.entries)


def test_memory_bootstrap_validator_filters_generic_and_downgrades_hard_targets(tmp_path: Path, monkeypatch) -> None:
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

    class FakeClient:
        def __init__(self):
            self.calls = 0

        def translate_request(self, _req):
            self.calls += 1
            if self.calls == 1:
                return type(
                    "Response",
                    (),
                    {
                        "raw_text": (
                            '{"candidates":['
                            '{"surface":"この塔","occurrence_ids":[1],"candidate_kind":"unknown","asr_risk":0.0,"recurrence":1},'
                            '{"surface":"ベア子","occurrence_ids":[2],"candidate_kind":"address_form","asr_risk":0.0,"recurrence":1}'
                            ']}'
                        )
                    },
                )()
            return type(
                "Response",
                (),
                {
                    "raw_text": (
                        '{"chunk_ids":["bootstrap"],"actions":['
                        '{"action":"upsert","source":"この塔","target":"普雷阿得斯监视塔","status":"confirmed","constraint":"must_use","evidence_ids":[1]},'
                        '{"action":"upsert","source":"ベアトリス","target":"","status":"locked","constraint":"must_use",'
                        '"alias_details":[{"source":"ベア子","kind":"nickname"}],"evidence_ids":[2]}'
                        ']}'
                    )
                },
            )()

    monkeypatch.setattr("transvortex.memory.bootstrapper.build_provider_client", lambda _provider: FakeClient())

    payload = bootstrap_memory(
        config,
        [Segment(id=1, start=0, end=1, text_src="この塔"), Segment(id=2, start=1, end=2, text_src="ベア子")],
        source_lang="ja",
        target_lang="zh-CN",
        memory_dir=tmp_path / "memory",
    )

    assert [row["source"] for row in payload["actions"]] == ["ベアトリス"]
    assert payload["actions"][0]["status"] == "proposed"
    assert payload["actions"][0]["constraint"] == "hint"
    doc = MemoryStore(tmp_path / "memory").load()
    assert doc.entries[0].source == "ベアトリス"
    assert doc.entries[0].target == ""
    assert doc.entries[0].alias_details[0].source == "ベア子"


def test_memory_bootstrap_input_view_soft_cleans_noise_and_keeps_evidence() -> None:
    segments = [
        Segment(id=1, start=0.0, end=1.0, text_src="Subaru enters"),
        Segment(id=2, start=1.2, end=1.6, text_src="um, Subaru"),
        Segment(id=3, start=5.0, end=5.2, text_src="[music]"),
        Segment(id=4, start=5.4, end=5.6, text_src="Subaru enters", confidence=-1.3),
    ]

    view = build_bootstrap_input_view(segments)
    rendered = render_bootstrap_input_text(view)

    assert view.stats["segments"] == 4
    assert view.lines[0].raw == "Subaru enters"
    assert view.lines[0].clean == "Subaru enters"
    assert "possible_term" in view.lines[0].flags
    assert view.lines[1].clean == "Subaru"
    assert "filler" in view.lines[1].flags
    assert view.lines[2].clean == ""
    assert {"scene_gap", "sound_effect", "noise", "low_info"}.issubset(set(view.lines[2].flags))
    assert {"low_confidence", "uncertain", "duplicate"}.issubset(set(view.lines[3].flags))
    assert "raw: [music]" in rendered
    assert "clean: " in rendered


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
    config.pipeline.memory.patch.enabled = True
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


def test_static_memory_translates_concurrently_without_patch(tmp_path: Path, monkeypatch) -> None:
    provider = ProviderConfig(
        name="p1",
        api_type="openai",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        compat_mode="openai_chat",
    )
    config = AppConfig(
        pipeline=PipelineConfig(artifacts_dir=tmp_path, default_concurrency=2),
        providers={"p1": provider},
        routing=RoutingConfig(primary=RouteTarget(provider="p1", model="m1")),
    )
    config.pipeline.memory.bootstrap.enabled = False
    config.pipeline.memory.inject.enabled = True
    store = MemoryStore(tmp_path / "memory")
    store.save(MemoryDocument(entries=[MemoryEntry(id="mem_subaru", source="Subaru", target="斯巴鲁", status="locked")]))
    chunks = [
        Chunk(chunk_id="c1", segment_ids=[1], lines=["[1] Subaru arrives"]),
        Chunk(chunk_id="c2", segment_ids=[2], lines=["[2] Nothing"]),
    ]
    seen: list[tuple[str, str]] = []

    def fake_submit(
        _pool,
        _config,
        chunk,
        _source_lang,
        _target_lang,
        memory_prompt,
        _progress_callback,
        _already_done=None,
        _memory_prompt_builder=None,
    ):
        seen.append((chunk.chunk_id, memory_prompt))

        class Done:
            def result(self):
                return {"chunk_id": chunk.chunk_id, "rows": [{"id": chunk.segment_ids[0], "text_tgt": "ok"}]}

        return Done()

    def fail_generate_memory_patch(*_args, **_kwargs):
        raise AssertionError("dynamic memory patch should not run")

    monkeypatch.setattr("transvortex.core.translate._submit_translate_chunk", fake_submit)
    monkeypatch.setattr("transvortex.core.translate.concurrent.futures.as_completed", lambda futures: list(futures))
    monkeypatch.setattr("transvortex.core.translate.generate_memory_patch", fail_generate_memory_patch)

    list(iter_translate_all_chunks(config, chunks, "en", "zh-CN", memory_dir=tmp_path / "memory"))

    assert [item[0] for item in seen] == ["c1", "c2"]
    assert "matched: Subaru" in seen[0][1]
    assert "target: 斯巴鲁" in seen[0][1]
    assert not (tmp_path / "memory" / "memory_patches.jsonl").read_text(encoding="utf-8").strip()
