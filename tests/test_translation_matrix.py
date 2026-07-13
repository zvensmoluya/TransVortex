from __future__ import annotations

import json
from pathlib import Path

import yaml

from transvortex.experiments.translation_matrix import (
    ExperimentCase,
    _build_case_providers,
    _case_summary,
    _memory_cli_args,
    _parse_chunk_specs,
)


def test_parse_chunk_specs_supports_whole_sample() -> None:
    assert _parse_chunk_specs("120,all,whole", 418) == [("120", 120), ("all", 418)]


def test_memory_cli_args_use_selected_presets_without_bootstrap_or_patch() -> None:
    case = ExperimentCase(
        case_id="low_chunk120",
        reasoning="low",
        chunk_lines=120,
        chunk_spec="120",
        model="gpt-5.6-terra",
        memory_presets=("rezero", "honorifics:locked"),
        memory_intensity="auto",
    )

    args = _memory_cli_args(case)

    assert args == [
        "--memory-enabled",
        "true",
        "--memory-bootstrap-enabled",
        "false",
        "--memory-inject-enabled",
        "true",
        "--memory-patch-enabled",
        "false",
        "--memory-intensity",
        "auto",
        "--memory-preset",
        "rezero,honorifics:locked",
    ]


def test_build_case_providers_overrides_model_and_reasoning(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        yaml.safe_dump(
            {
                "providers": [
                    {
                        "name": "gateway",
                        "api_type": "openai-compatible",
                        "base_url": "https://example.invalid/v1",
                        "credential_id": "gateway",
                        "models": ["old-model"],
                        "request_mapping": {
                            "body_overrides": {"reasoning": {"effort": "medium"}}
                        },
                    }
                ]
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    case = ExperimentCase(
        case_id="high_chunkall",
        reasoning="high",
        chunk_lines=418,
        chunk_spec="all",
        model="gpt-5.6-terra",
        omit_temperature=True,
        omit_output_token_limit=True,
    )

    path = _build_case_providers(tmp_path, "gateway", case, tmp_path / "out", 60, 90)

    payload = yaml.safe_load(path.read_text(encoding="utf-8"))
    provider = payload["providers"][0]
    assert provider["models"] == ["gpt-5.6-terra"]
    assert provider["model_configs"]["gpt-5.6-terra"]["max_batch_lines"] == 418
    assert provider["capabilities"]["supports_temperature"] is False
    assert provider["capabilities"]["output_token_param"] == "none"
    assert provider["request_mapping"]["body_overrides"]["reasoning"] == {"effort": "high"}
    assert payload["routing"]["primary"]["model"] == "gpt-5.6-terra"


def test_case_summary_captures_latency_recovery_and_reasoning_usage(tmp_path: Path) -> None:
    translate_dir = tmp_path / "translate"
    translate_dir.mkdir()
    rows = [
        {
            "line_count": 120,
            "raw_text_chars": 1500,
            "usage": {
                "input_tokens": 500,
                "output_tokens": 300,
                "output_tokens_details": {"reasoning_tokens": 100},
            },
            "provider_meta": {
                "request_started_at": 10.0,
                "first_byte_at": 10.25,
                "elapsed_ms": 900,
            },
            "validation": {"issue_count": 1},
            "repairs": 2,
            "protocol_recovered": True,
            "batch_recovery_requests": 1,
            "memory_entries": 8,
            "memory_prompt_chars": 1200,
        },
        {
            "line_count": 80,
            "raw_text_chars": 900,
            "usage": {
                "input_tokens": 400,
                "output_tokens": 200,
                "output_tokens_details": {"reasoning_tokens": 50},
            },
            "provider_meta": {
                "request_started_at": 20.0,
                "first_byte_at": 20.35,
                "elapsed_ms": 700,
            },
            "validation": {"issue_count": 0},
            "repairs": 0,
            "protocol_recovered": False,
            "batch_recovery_requests": 0,
            "memory_entries": 6,
            "memory_prompt_chars": 900,
        },
    ]
    (translate_dir / "metrics.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )
    memory_dir = tmp_path / "memory"
    memory_dir.mkdir()
    (memory_dir / "consistency_issues.jsonl").write_text(
        json.dumps({"id": 2, "source": "スバル"}) + "\n",
        encoding="utf-8",
    )
    case = ExperimentCase(
        case_id="high_chunk120",
        reasoning="high",
        chunk_lines=120,
        chunk_spec="120",
        model="gpt-5.6-terra",
    )

    summary = _case_summary(case, "task-1", tmp_path, 2000)

    assert summary["lines"] == 200
    assert summary["elapsed_ms_wall"] == 2000
    assert summary["provider_elapsed_ms_sum"] == 1600
    assert summary["first_byte_ms_avg"] == 300
    assert summary["first_byte_ms_p50"] == 300
    assert summary["repair_requests"] == 2
    assert summary["recovered_chunks"] == 1
    assert summary["batch_recovery_requests"] == 1
    assert summary["memory_entries_total"] == 14
    assert summary["memory_entries_avg"] == 7
    assert summary["memory_prompt_chars_total"] == 2100
    assert summary["consistency_issues"] == 1
    assert summary["usage"]["input_tokens"] == 900
    assert summary["usage"]["output_tokens_details.reasoning_tokens"] == 150
