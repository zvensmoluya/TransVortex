from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from transvortex.app.models import TaskRecord
from transvortex.app.asr_resolution import (
    build_active_asr_intent_snapshot,
    recommended_asr_policy,
    restore_asr_intent_snapshot,
)
from transvortex.app.config import load_app_config
from transvortex.artifacts.task_store import TaskStore
from transvortex.asr_domain import CapabilityLimit, resolve_asr_policy
from transvortex.core.orchestrator import (
    _apply_resolved_asr_plan,
    _asr_allows_split_retry,
    _asr_plan_id,
    _ensure_resolved_asr_plan,
    _portable_asr_manifest,
    _resolved_asr_plan,
)
from transvortex.utils import read_json, to_plain


def _write_config(root: Path, *, window_seconds: int = 300) -> None:
    (root / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (root / "pipeline.yaml").write_text(
        f"""
config_schema_version: 2
artifacts_dir: artifacts
asr: {{engine: openrouter_asr}}
asr_engines:
  - id: openrouter_asr
    type: openrouter_asr
    model: openai/whisper-large-v3
    policy_overrides:
      chunking:
        window_target_seconds: {window_seconds}
        window_floor_seconds: 8
        overlap_seconds: 3
        """.strip(),
        encoding="utf-8",
    )


def _manifest(task_dir: Path) -> list[dict]:
    windows_dir = task_dir / "asr" / "windows"
    windows_dir.mkdir(parents=True, exist_ok=True)
    first = windows_dir / "part_00000.wav"
    second = windows_dir / "part_00001.wav"
    first.write_bytes(b"window-zero")
    second.write_bytes(b"window-one")
    return [
        {
            "segment_index": 0,
            "start": 0.0,
            "duration": 300.0,
            "trusted_start": 0.0,
            "trusted_end": 298.5,
            "estimated_upload_bytes": 9_600_044,
            "cut_reason": "hard_limit",
            "path": str(first),
        },
        {
            "segment_index": 1,
            "start": 297.0,
            "duration": 293.0,
            "trusted_start": 298.5,
            "trusted_end": 590.0,
            "estimated_upload_bytes": 9_376_044,
            "cut_reason": "end_of_audio",
            "path": str(second),
        },
    ]


def test_task_asr_intent_freezes_the_effective_policy(
    tmp_path: Path,
    monkeypatch,
) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    _write_config(tmp_path, window_seconds=300)
    original = load_app_config(root_dir=tmp_path)
    snapshot = build_active_asr_intent_snapshot(original, root_dir=tmp_path)

    _write_config(tmp_path, window_seconds=60)
    changed = load_app_config(root_dir=tmp_path)
    assert changed.asr_providers["openrouter_asr"].chunking.window_seconds == 60

    restored = restore_asr_intent_snapshot(changed, snapshot, root_dir=tmp_path)

    assert restored is not None
    assert changed.pipeline.asr_provider == "openrouter_asr"
    assert changed.asr_providers["openrouter_asr"].chunking.window_seconds == 300
    assert snapshot["capabilities"]["availability"]["state"] == "needs_action"
    assert "effective_policy" in snapshot

    snapshot["effective_policy"]["chunking"]["upload_soft_limit_bytes"] = None
    restored = restore_asr_intent_snapshot(changed, snapshot, root_dir=tmp_path)
    assert restored is not None
    assert restored.policy.policy.chunking.upload_soft_limit_bytes is None
    assert restored.runtime.chunking.max_upload_mb is None


def test_resolved_asr_plan_records_actual_windows_and_drives_execution(tmp_path: Path) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    asr_dir = tmp_path / "task" / "asr"
    asr_dir.mkdir(parents=True)
    task_dir = asr_dir.parent
    manifest = _manifest(task_dir)
    planning_metadata = {
        "mode": "silence",
        "silence_ranges": [{"start": 296.0, "end": 298.0, "duration": 2.0}],
    }

    plan = _resolved_asr_plan(
        config,
        audio_full=audio,
        media_meta={
            "duration_seconds": 590.0,
            "audio_codec": "aac",
            "audio_stream_index": 2,
            "audio_stream_language": "jpn",
            "audio_stream_sample_rate_hz": 48000,
            "audio_stream_channels": 2,
        },
        manifest=manifest,
        planning_metadata=planning_metadata,
        paths={"asr": asr_dir},
    )

    assert plan is not None
    assert plan.plan_schema_version == 4
    assert plan.windows[0].segment_id == "segment-00000"
    assert plan.windows[0].segment_index == 0
    assert plan.windows[0].artifact_path == "asr/windows/part_00000.wav"
    assert len(plan.windows[0].content_sha256) == 64
    assert plan.windows[0].encoded_size_bytes == len(b"window-zero")
    assert plan.windows[0].cut_reason == "hard_limit"
    assert plan.windows[1].source_end == 590.0
    assert plan.execution.actual_concurrency == 2
    assert plan.execution.split_retry is True
    assert _asr_allows_split_retry(config) is True
    assert plan.timeline.strategy_id == "trusted_midpoint_segment_merge"
    assert plan.audio_facts.selected_stream.sample_rate_hz == 48000
    assert plan.audio_facts.silence_analysis.range_count == 1
    assert (asr_dir / "silence_analysis.json").is_file()

    payload = to_plain(plan)
    portable_manifest = _portable_asr_manifest(list(payload["windows"]))
    runtime_manifest = [dict(item) for item in portable_manifest]
    _apply_resolved_asr_plan(
        config,
        payload,
        runtime_manifest,
        task_dir=task_dir,
        audio_full=audio,
    )
    assert config.asr_providers["openrouter_asr"].execution.concurrency == 2
    assert Path(runtime_manifest[0]["path"]).is_absolute()

    incompatible = dict(payload, plan_schema_version=4.5)
    with pytest.raises(RuntimeError, match="unsupported_asr_plan_schema"):
        _apply_resolved_asr_plan(
            config,
            incompatible,
            [dict(item) for item in portable_manifest],
            task_dir=task_dir,
        )

    audio.write_bytes(b"different-audio")
    with pytest.raises(RuntimeError, match="asr_plan_audio_mismatch"):
        _apply_resolved_asr_plan(
            config,
            payload,
            [dict(item) for item in portable_manifest],
            task_dir=task_dir,
            audio_full=audio,
        )
    audio.write_bytes(b"audio-content")

    tampered = dict(payload)
    tampered["execution"] = dict(payload["execution"], actual_concurrency=1)
    with pytest.raises(RuntimeError, match="asr_plan_integrity_mismatch"):
        _apply_resolved_asr_plan(
            config,
            tampered,
            [dict(item) for item in portable_manifest],
            task_dir=task_dir,
        )

    config.pipeline.asr_prompt.include_previous_text = True
    sequential_plan = _resolved_asr_plan(
        config,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=manifest,
        planning_metadata=planning_metadata,
        paths={"asr": asr_dir},
    )
    assert sequential_plan is not None
    assert sequential_plan.execution.actual_concurrency == 1
    with pytest.raises(RuntimeError, match="asr_plan_execution_mismatch"):
        _apply_resolved_asr_plan(
            config,
            payload,
            [dict(item) for item in portable_manifest],
            task_dir=task_dir,
        )

    sequential_payload = to_plain(sequential_plan)
    sequential_manifest = _portable_asr_manifest(list(sequential_payload["windows"]))
    broken_manifest = [dict(item) for item in sequential_manifest]
    broken_manifest[1]["start"] = 298.0
    with pytest.raises(RuntimeError, match="asr_plan_manifest_mismatch"):
        _apply_resolved_asr_plan(
            config,
            sequential_payload,
            broken_manifest,
            task_dir=task_dir,
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("segment_id", "different-segment"),
        ("segment_index", 7),
        ("path", "../outside.wav"),
        ("content_sha256", "0" * 64),
        ("cut_reason", "whole_audio"),
        ("trusted_start", 1.0),
    ],
)
def test_resolved_asr_plan_rejects_manifest_field_tampering(
    tmp_path: Path,
    field: str,
    value: object,
) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    task_dir = tmp_path / "task"
    asr_dir = task_dir / "asr"
    asr_dir.mkdir(parents=True)
    manifest = _manifest(task_dir)
    plan = _resolved_asr_plan(
        config,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=manifest,
        planning_metadata={},
        paths={"asr": asr_dir},
    )
    assert plan is not None
    payload = to_plain(plan)
    portable_manifest = _portable_asr_manifest(list(payload["windows"]))
    portable_manifest[0][field] = value

    with pytest.raises(RuntimeError, match="asr_plan_manifest_mismatch"):
        _apply_resolved_asr_plan(
            config,
            payload,
            portable_manifest,
            task_dir=task_dir,
            audio_full=audio,
        )


def test_resolved_asr_plan_rejects_window_content_tampering(tmp_path: Path) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    task_dir = tmp_path / "task"
    asr_dir = task_dir / "asr"
    asr_dir.mkdir(parents=True)
    manifest = _manifest(task_dir)
    plan = _resolved_asr_plan(
        config,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=manifest,
        planning_metadata={},
        paths={"asr": asr_dir},
    )
    assert plan is not None
    payload = to_plain(plan)
    portable_manifest = _portable_asr_manifest(list(payload["windows"]))
    (task_dir / portable_manifest[0]["path"]).write_bytes(b"tampered-window")

    with pytest.raises(RuntimeError, match="asr_plan_artifact_size_mismatch|asr_plan_content_hash_mismatch"):
        _apply_resolved_asr_plan(
            config,
            payload,
            portable_manifest,
            task_dir=task_dir,
            audio_full=audio,
        )


def test_resolved_asr_plan_rejects_rehashed_path_escape(tmp_path: Path) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    task_dir = tmp_path / "task"
    asr_dir = task_dir / "asr"
    asr_dir.mkdir(parents=True)
    plan = _resolved_asr_plan(
        config,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=_manifest(task_dir),
        planning_metadata={},
        paths={"asr": asr_dir},
    )
    assert plan is not None
    payload = to_plain(plan)
    portable_manifest = _portable_asr_manifest(list(payload["windows"]))
    malicious = dict(payload)
    malicious["windows"] = [dict(item) for item in payload["windows"]]
    malicious["windows"][0]["artifact_path"] = "../outside.wav"
    identity_fields = (
        "engine",
        "capabilities",
        "effective_policy",
        "audio_facts",
        "windows",
        "execution",
        "timeline",
    )
    malicious["plan_id"] = _asr_plan_id(
        {field: malicious.get(field) for field in identity_fields}
    )

    with pytest.raises(RuntimeError, match="asr_plan_artifact_path_invalid"):
        _apply_resolved_asr_plan(
            config,
            malicious,
            portable_manifest,
            task_dir=task_dir,
            audio_full=audio,
        )


def test_resolved_asr_plan_persists_portable_manifest_and_rehydrates_execution_paths(
    tmp_path: Path,
) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    store = TaskStore(tmp_path / "artifacts")
    task = TaskRecord(
        task_id="task-plan-roundtrip",
        input_file=str(tmp_path / "input.mp4"),
        source_lang="ja",
        target_lang="en",
        bilingual=False,
        status="INGEST",
        created_at="2026-01-01T00:00:00Z",
        updated_at="2026-01-01T00:00:00Z",
    )
    store.save_task(task)
    task_dir = store.task_dir(task.task_id)
    paths = {"base": task_dir, "asr": task_dir / "asr"}
    paths["asr"].mkdir(parents=True)
    audio = tmp_path / "cache" / "audio.m4a"
    audio.parent.mkdir(parents=True)
    audio.write_bytes(b"audio-content")
    manifest = _manifest(task_dir)

    created = _ensure_resolved_asr_plan(
        config,
        store,
        task,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=manifest,
        planning_metadata={},
        paths=paths,
    )

    assert created is not None
    portable_path = paths["asr"] / "segments_manifest.json"
    portable = read_json(portable_path)
    assert portable[0]["path"] == "asr/windows/part_00000.wav"
    assert Path(manifest[0]["path"]).is_absolute()
    assert store.load_task(task.task_id).settings["asr_plan"]["plan_id"] == created["plan_id"]

    recovered_config = load_app_config(root_dir=tmp_path)
    recovered_task = store.load_task(task.task_id)
    recovered_manifest = read_json(portable_path)
    recovered = _ensure_resolved_asr_plan(
        recovered_config,
        store,
        recovered_task,
        audio_full=audio,
        media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
        manifest=recovered_manifest,
        planning_metadata={},
        paths=paths,
    )

    assert recovered == created
    assert Path(recovered_manifest[0]["path"]).is_absolute()
    assert recovered_manifest[0]["content_sha256"] == created["windows"][0]["content_sha256"]


def test_resolved_asr_plan_checks_actual_windows_against_hard_capabilities(
    tmp_path: Path,
) -> None:
    _write_config(tmp_path, window_seconds=180)
    config = load_app_config(root_dir=tmp_path)
    engine_id = config.pipeline.asr_provider
    capabilities = config.asr_capabilities[engine_id]
    capabilities = replace(
        capabilities,
        audio_input=replace(
            capabilities.audio_input,
            max_duration_seconds=CapabilityLimit(
                hard_max=180.0,
                knowledge="verified",
                source="test_probe",
            ),
        ),
    )
    config.asr_capabilities[engine_id] = capabilities
    config.asr_policy_resolutions[engine_id] = resolve_asr_policy(
        recommended_asr_policy(config.asr_engine_specs[engine_id]),
        config.asr_user_overrides[engine_id],
        capabilities,
    )
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    task_dir = tmp_path / "task"
    asr_dir = task_dir / "asr"
    asr_dir.mkdir(parents=True)

    with pytest.raises(
        RuntimeError,
        match="asr_plan_window_duration_capability_exceeded",
    ):
        _resolved_asr_plan(
            config,
            audio_full=audio,
            media_meta={"duration_seconds": 590.0, "audio_codec": "aac"},
            manifest=_manifest(task_dir),
            planning_metadata={},
            paths={"asr": asr_dir},
        )
