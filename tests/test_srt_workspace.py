from __future__ import annotations

from pathlib import Path

from transvortex.app.models import NormalizedResponse
from transvortex.core.orchestrator import run_pipeline
from transvortex.providers.admin import save_provider_routing
from transvortex.artifacts.result_workspace import open_task_result, reexport_task, save_task_segments, update_task_memory_entry
from transvortex.formats.srt import parse_srt_text
from transvortex.artifacts.task_store import TaskStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
translation_batch_size: 2
default_concurrency: 1
max_cps: 40
providers:
        """.strip(),
        encoding="utf-8",
    )
    (root / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
  - name: p2
    api_type: openai
    base_url: https://fallback.example/v1
    env_key: PROVIDER_KEY
    models: [m2]
routing:
  primary: {provider: p1, model: m1}
  fallback: []
        """.strip(),
        encoding="utf-8",
    )


def test_parse_srt_text_multiline_and_commas() -> None:
    rows = parse_srt_text(
        """
1
00:00:01,000 --> 00:00:02,500
Hello
world

2
00:00:03.000 --> 00:00:04.000
Next
        """.strip()
    )
    assert len(rows) == 2
    assert rows[0].start == 1.0
    assert rows[0].end == 2.5
    assert rows[0].text_src == "Hello\nworld"


def test_srt_translate_skips_asr_and_result_workspace(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    monkeypatch.setenv("PROVIDER_KEY", "key")
    srt_file = root / "中文 路径.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:02,000
Hello

2
00:00:03,000 --> 00:00:04,000
World
        """.strip(),
        encoding="utf-8",
    )

    def fake_translate_all_chunks(config, chunks, source_lang: str, target_lang: str, already_done=None):
        assert source_lang == "en"
        assert target_lang == "zh-CN"
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": f"译文 {seg_id}"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in chunks
            if chunk.chunk_id not in (already_done or set())
        ]

    def fail_asr(*_args, **_kwargs):
        raise AssertionError("ASR should not run for srt_translate")

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)
    monkeypatch.setattr("transvortex.core.orchestrator.AsrEngine", fail_asr)

    task_id = run_pipeline(
        root_dir=root,
        input_file=srt_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=True,
        input_type="srt_translate",
        cli_overrides={"output_format": "both"},
    )

    store = TaskStore(root / "artifacts")
    task = store.load_task(task_id)
    assert task.status == "DONE"
    assert task.settings["input_type"] == "srt_translate"
    assert set(task.output_paths) == {"srt", "ass"}
    external_base = root / "fixture" / "demo.zh-CN"
    store.update_task_status(
        task_id,
        task.status,
        output_path=str(external_base.with_suffix(".srt")),
        output_paths={
            "srt": str(external_base.with_suffix(".srt")),
            "ass": str(external_base.with_suffix(".ass")),
        },
    )
    assert (store.task_dir(task_id) / "source" / "segments.normalized.jsonl").exists()
    assert not (store.task_dir(task_id) / "media" / "audio_full.m4a").exists()

    result = open_task_result(root_dir=root, task_id=task_id)
    assert result["segments"][0]["provider"] == "p1"
    assert result["segments"][0]["model"] == "m1"
    assert "quality" in result
    assert "quality_issues" in result["segments"][0]

    edited = result["segments"]
    edited[0]["text_tgt"] = "改过的译文"
    saved = save_task_segments(root_dir=root, task_id=task_id, segments_payload=edited)
    assert saved["segments"][0]["text_tgt"] == "改过的译文"
    reexported = reexport_task(root_dir=root, task_id=task_id, output_format="srt")
    assert reexported["output_paths"]["srt"] == str(external_base.with_suffix(".srt"))
    assert Path(reexported["output_paths"]["srt"]).read_text(encoding="utf-8").find("改过的译文") >= 0
    reexported_plain = reexport_task(root_dir=root, task_id=task_id, output_format="srt", bilingual=False)
    plain_body = Path(reexported_plain["output_paths"]["srt"]).read_text(encoding="utf-8")
    assert "Hello" not in plain_body
    assert reexported_plain["bilingual"] is False
    reexported_lrc = reexport_task(root_dir=root, task_id=task_id, output_format="lrc", bilingual=False)
    assert reexported_lrc["output_paths"]["lrc"] == str(external_base.with_suffix(".lrc"))
    lrc_body = Path(reexported_lrc["output_paths"]["lrc"]).read_text(encoding="utf-8")
    assert "[00:01.00]改过的译文" in lrc_body
    assert "Hello" not in lrc_body
    recovery_dir = root / "fixed-output"
    store.update_task_status(
        task_id,
        "FAILED",
        error="output path is not writable",
        error_info={"code": "output_not_writable", "hint_zh": "输出目录不可写。"},
    )
    reexported_elsewhere = reexport_task(
        root_dir=root,
        task_id=task_id,
        output_format="srt",
        output_dir=str(recovery_dir),
    )
    assert reexported_elsewhere["output_paths"]["srt"] == str(recovery_dir / f"{srt_file.stem}.zh-CN.srt")
    recovered_task = store.load_task(task_id)
    assert recovered_task.status == "DONE"
    assert recovered_task.error is None
    assert recovered_task.error_info is None
    events = store.read_events(task_id)
    assert any(event["type"] == "edited" for event in events)
    assert any(event["type"] == "reexported" for event in events)


def test_srt_translate_can_export_lrc_on_first_run(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    monkeypatch.setenv("PROVIDER_KEY", "key")
    srt_file = root / "song.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:02,000
Hello
        """.strip(),
        encoding="utf-8",
    )

    def fake_translate_all_chunks(config, chunks, source_lang: str, target_lang: str, already_done=None):
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [{"id": seg_id, "text_tgt": "你好"} for seg_id in chunk.segment_ids],
                "errors": [],
            }
            for chunk in chunks
        ]

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)

    task_id = run_pipeline(
        root_dir=root,
        input_file=srt_file,
        source_lang="en",
        target_lang="zh-CN",
        bilingual=False,
        input_type="srt_translate",
        cli_overrides={"output_format": "lrc"},
    )

    task = TaskStore(root / "artifacts").load_task(task_id)
    assert task.status == "DONE"
    assert task.settings["output_format"] == "lrc"
    assert set(task.output_paths) == {"lrc"}
    assert task.output_path == task.output_paths["lrc"]
    assert Path(task.output_paths["lrc"]).read_text(encoding="utf-8") == "[00:01.00]你好\n"


def test_srt_translate_reflow_artifacts_and_result_summary(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    pipeline = root / "pipeline.yaml"
    pipeline.write_text(
        pipeline.read_text(encoding="utf-8")
        + """
subtitle:
  quality:
    min_duration_seconds: 0.8
    hard_max_cps: 10
    target_cps: 8
  reflow:
    enabled: true
    max_window_segments: 3
    batch_windows: 10
memory:
  presets:
    - reflow_hello
  bootstrap:
    enabled: false
  inject:
    enabled: true
    intensity: high
        """,
        encoding="utf-8",
    )
    monkeypatch.setenv("PROVIDER_KEY", "key")
    presets_dir = root / "memory" / "presets"
    presets_dir.mkdir(parents=True)
    (presets_dir / "reflow_hello.json").write_text(
        """
{
  "id": "reflow_hello",
  "scope": {"language_pairs": ["en->zh-CN"]},
  "default_status": "locked",
  "entries": [
    {"source": "Hello", "target": "你好", "category": "term"}
  ]
}
        """.strip(),
        encoding="utf-8",
    )
    srt_file = root / "demo.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:01,100
Hello

2
00:00:01,500 --> 00:00:02,600
World
        """.strip(),
        encoding="utf-8",
    )

    def fake_translate_all_chunks(_config, chunks, source_lang: str, target_lang: str, already_done=None, memory_dir=None):
        return [
            {
                "chunk_id": chunk.chunk_id,
                "provider": "p1",
                "model": "m1",
                "compat_mode": "openai_chat",
                "base_url": "https://example.com/v1",
                "rows": [
                    {"id": seg_id, "text_tgt": "这是一条非常非常长的字幕" if seg_id == 1 else "下一句"}
                    for seg_id in chunk.segment_ids
                ],
                "errors": [],
            }
            for chunk in chunks
        ]

    class FakeReflowClient:
        def __init__(self, _provider):
            pass

        def translate_request(self, req):
            assert req.prompt_mode == "reflow"
            assert "matched: Hello" in req.memory_prompt
            assert "target: 你好" in req.memory_prompt
            return NormalizedResponse(
                numbered_lines=[],
                raw_text='{"windows":[{"window_id":1,"replacements":[{"source_ids":[1,2],"text_tgt":"短句合并","reason":"merge"}]}]}',
            )

    monkeypatch.setattr("transvortex.core.orchestrator.translate_all_chunks", fake_translate_all_chunks)
    monkeypatch.setattr("transvortex.core.subtitle_reflow.build_provider_client", lambda provider: FakeReflowClient(provider))

    task_id = run_pipeline(root_dir=root, input_file=srt_file, source_lang="en", target_lang="zh-CN", input_type="srt_translate")

    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    assert (task_dir / "quality" / "reflow.jsonl").exists()
    assert (task_dir / "final" / "segments.reflowed.json").exists()
    result = open_task_result(root_dir=root, task_id=task_id)
    assert result["reflow"]["reflowed"] == 1
    assert [segment["id"] for segment in result["segments"]] == [1]
    assert result["segments"][0]["text_tgt"] == "短句合并"
    assert not (task_dir / "memory" / "memory_patches.jsonl").read_text(encoding="utf-8").strip()


def test_srt_translate_memory_artifacts_and_result_summary(tmp_path: Path, monkeypatch) -> None:
    root = tmp_path
    _write_config(root)
    pipeline = root / "pipeline.yaml"
    pipeline.write_text(
        pipeline.read_text(encoding="utf-8")
        + """
memory:
  presets:
    - subaru
  bootstrap:
    enabled: false
  inject:
    enabled: true
    intensity: high
  patch:
    enabled: true
    window_chunks: 1
  consistency_check:
    enabled: true
        """,
        encoding="utf-8",
    )
    monkeypatch.setenv("PROVIDER_KEY", "key")
    presets_dir = root / "memory" / "presets"
    presets_dir.mkdir(parents=True)
    (presets_dir / "subaru.json").write_text(
        """
{
  "id": "subaru",
  "scope": {"language_pairs": ["en->zh-CN"]},
  "default_status": "locked",
  "entries": [
    {"source": "Subaru", "target": "斯巴鲁", "category": "character"}
  ]
}
        """.strip(),
        encoding="utf-8",
    )
    srt_file = root / "demo.srt"
    srt_file.write_text(
        """
1
00:00:01,000 --> 00:00:02,000
Subaru arrives
        """.strip(),
        encoding="utf-8",
    )

    def fake_translate_chunk(_config, chunk, source_lang: str, target_lang: str, memory_prompt: str = ""):
        assert "matched: Subaru" in memory_prompt
        assert "target: 斯巴鲁" in memory_prompt
        return {
            "chunk_id": chunk.chunk_id,
            "provider": "p1",
            "model": "m1",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "rows": [{"id": seg_id, "text_tgt": "斯巴鲁来了"} for seg_id in chunk.segment_ids],
            "errors": [],
        }

    def fake_generate_memory_patch(_config, chunks, translated_rows, *, source_lang: str, target_lang: str):
        payload = {
            "chunk_ids": [chunk.chunk_id for chunk in chunks],
            "actions": [
                {
                    "action": "upsert",
                    "source": "The Order",
                    "target": "教团",
                    "category": "organization",
                    "status": "proposed",
                    "confidence": 0.8,
                    "evidence_ids": [1],
                }
            ],
            "provider": "p1",
            "model": "m1",
            "raw_text": "{}",
        }
        from transvortex.memory.merger import patch_from_payload

        return patch_from_payload(payload), payload

    monkeypatch.setattr("transvortex.core.translate.translate_chunk", fake_translate_chunk)
    monkeypatch.setattr("transvortex.core.translate.generate_memory_patch", fake_generate_memory_patch)

    task_id = run_pipeline(
        root_dir=root,
        input_file=srt_file,
        source_lang="en",
        target_lang="zh-CN",
        input_type="srt_translate",
    )
    store = TaskStore(root / "artifacts")
    task_dir = store.task_dir(task_id)
    memory_dir = task_dir / "memory"
    memory_file = memory_dir / "translation_memory.json"
    payload = memory_file.read_text(encoding="utf-8")
    assert "The Order" in payload
    assert "Subaru" not in payload
    selected_payload = (memory_dir / "selected_presets.json").read_text(encoding="utf-8")
    assert "Subaru" in selected_payload
    assert (memory_dir / "memory_patches.jsonl").read_text(encoding="utf-8").strip()
    assert list((memory_dir / "snapshots").glob("memory_*.json"))
    result = open_task_result(root_dir=root, task_id=task_id)
    assert result["memory"]["enabled"] is True
    assert result["memory"]["entries"] >= 1
    runtime_entry = result["memory"]["entry_items"][0]

    updated = update_task_memory_entry(
        root_dir=root,
        task_id=task_id,
        entry_id=runtime_entry["id"],
        status="locked",
    )

    assert updated["memory"]["entry_items"][0]["status"] == "locked"
    assert "memory_updated" in (task_dir / "events.jsonl").read_text(encoding="utf-8")


def test_save_provider_routing_writes_primary_and_fallback(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    payload = save_provider_routing(
        root_dir=root,
        routing={
            "primary": {"provider": "p1", "model": "m1"},
            "fallback": [{"provider": "p2", "model": "m2"}],
        },
    )
    assert payload["routing"]["primary"]["provider"] == "p1"
    assert payload["routing"]["fallback"][0]["model"] == "m2"
    assert payload["active_routing_profile"] == "default"
    raw = (root / "providers.local.yaml").read_text(encoding="utf-8")
    assert "fallback" in raw
    assert "routing_profiles" in raw


def test_save_provider_routing_writes_named_profiles(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    payload = save_provider_routing(
        root_dir=root,
        routing={
            "active_profile": "route_2",
            "profiles": [
                {"id": "route_1", "name": "配置 1", "primary": {"provider": "p1", "model": "m1"}, "fallback": []},
                {
                    "id": "route_2",
                    "name": "配置 2",
                    "primary": {"provider": "p2", "model": "m2"},
                    "fallback": [{"provider": "p1", "model": "m1"}],
                },
            ],
        },
    )
    assert payload["active_routing_profile"] == "route_2"
    assert payload["routing"]["primary"] == {"provider": "p2", "model": "m2"}
    assert payload["routing_profiles"][1]["name"] == "配置 2"
    raw = (root / "providers.local.yaml").read_text(encoding="utf-8")
    assert "active_profile: route_2" in raw
    assert "routing_profiles" in raw


def test_save_provider_routing_legacy_payload_updates_default_without_switching_active(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    save_provider_routing(
        root_dir=root,
        routing={
            "active_profile": "route_2",
            "profiles": [
                {"id": "default", "name": "Default", "primary": {"provider": "p1", "model": "m1"}, "fallback": []},
                {"id": "route_2", "name": "配置 2", "primary": {"provider": "p2", "model": "m2"}, "fallback": []},
            ],
            "next_profile_seq": 3,
        },
    )
    payload = save_provider_routing(
        root_dir=root,
        routing={
            "primary": {"provider": "p1", "model": "m1"},
            "fallback": [{"provider": "p2", "model": "m2"}],
        },
    )
    assert payload["active_routing_profile"] == "route_2"
    assert payload["routing"]["primary"] == {"provider": "p2", "model": "m2"}
    default = payload["routing_profiles"][0]
    assert default["id"] == "default"
    assert default["fallback"][0]["model"] == "m2"


def test_save_provider_routing_rejects_duplicate_or_empty_names(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    for name in ["", "配置 1"]:
        try:
            save_provider_routing(
                root_dir=root,
                routing={
                    "active_profile": "route_1",
                    "profiles": [
                        {"id": "route_1", "name": "配置 1", "primary": {"provider": "p1", "model": "m1"}, "fallback": []},
                        {"id": "route_2", "name": name, "primary": {"provider": "p2", "model": "m2"}, "fallback": []},
                    ],
                },
            )
        except ValueError as exc:
            assert "routing_profile_name" in str(exc)
        else:  # pragma: no cover - assertion branch
            raise AssertionError("expected invalid profile name to fail")


def test_save_provider_routing_rejects_missing_provider_or_model(tmp_path: Path) -> None:
    root = tmp_path
    _write_config(root)
    cases = [
        ({"provider": "missing", "model": "m1"}, "routing_provider_missing"),
        ({"provider": "p1", "model": "missing"}, "routing_model_missing"),
    ]
    for route, code in cases:
        try:
            save_provider_routing(
                root_dir=root,
                routing={
                    "active_profile": "route_1",
                    "profiles": [{"id": "route_1", "name": "配置 1", "primary": route, "fallback": []}],
                },
            )
        except ValueError as exc:
            assert code in str(exc)
        else:  # pragma: no cover - assertion branch
            raise AssertionError("expected invalid route to fail")
