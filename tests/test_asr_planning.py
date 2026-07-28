from __future__ import annotations

from pathlib import Path

import pytest

from transvortex.app.asr_resolution import (
    build_active_asr_intent_snapshot,
    restore_asr_intent_snapshot,
)
from transvortex.app.config import load_app_config
from transvortex.core.orchestrator import (
    _apply_resolved_asr_plan,
    _asr_allows_split_retry,
    _resolved_asr_plan,
)
from transvortex.utils import to_plain


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
        short_audio_bypass_seconds: {window_seconds}
        """.strip(),
        encoding="utf-8",
    )


def _manifest(root: Path) -> list[dict]:
    return [
        {
            "segment_index": 0,
            "start": 0.0,
            "duration": 300.0,
            "trusted_start": 0.0,
            "trusted_end": 298.5,
            "estimated_upload_bytes": 9_600_044,
            "cut_reason": "hard_limit",
            "path": str(root / "part_00000.wav"),
        },
        {
            "segment_index": 1,
            "start": 297.0,
            "duration": 293.0,
            "trusted_start": 298.5,
            "trusted_end": 590.0,
            "estimated_upload_bytes": 9_376_044,
            "cut_reason": "end_of_audio",
            "path": str(root / "part_00001.wav"),
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
    assert restored.runtime.chunking.max_upload_mb == 2048.0


def test_resolved_asr_plan_records_actual_windows_and_drives_execution(tmp_path: Path) -> None:
    _write_config(tmp_path)
    config = load_app_config(root_dir=tmp_path)
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio-content")
    asr_dir = tmp_path / "task" / "asr"
    asr_dir.mkdir(parents=True)
    manifest = _manifest(tmp_path)
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
    assert plan.plan_schema_version == 2
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
    _apply_resolved_asr_plan(config, payload, manifest, audio_full=audio)
    assert config.asr_providers["openrouter_asr"].execution.concurrency == 2

    audio.write_bytes(b"different-audio")
    with pytest.raises(RuntimeError, match="asr_plan_audio_mismatch"):
        _apply_resolved_asr_plan(config, payload, manifest, audio_full=audio)
    audio.write_bytes(b"audio-content")

    tampered = dict(payload)
    tampered["execution"] = dict(payload["execution"], actual_concurrency=1)
    with pytest.raises(RuntimeError, match="asr_plan_integrity_mismatch"):
        _apply_resolved_asr_plan(config, tampered, manifest)

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
        _apply_resolved_asr_plan(config, payload, manifest)

    broken_manifest = [dict(item) for item in manifest]
    broken_manifest[1]["start"] = 298.0
    with pytest.raises(RuntimeError, match="asr_plan_manifest_mismatch"):
        _apply_resolved_asr_plan(config, to_plain(sequential_plan), broken_manifest)
