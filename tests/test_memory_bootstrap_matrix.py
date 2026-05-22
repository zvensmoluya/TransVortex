from __future__ import annotations

import pytest

from transvortex.experiments.memory_bootstrap_matrix import (
    _provider_with_reasoning,
    _provider_without_reasoning,
)


def test_bootstrap_matrix_keeps_openai_reasoning_override() -> None:
    provider = {
        "name": "openai",
        "api_type": "openai-compatible",
        "compat_mode": "openai_responses",
        "models": ["gpt-5.5"],
        "request_mapping": {
            "style": "openai_responses",
            "body_overrides": {"reasoning": {"effort": "high"}},
        },
    }

    out = _provider_with_reasoning(provider, "medium")

    assert out["request_mapping"]["body_overrides"]["reasoning"] == {"effort": "medium"}
    assert provider["request_mapping"]["body_overrides"]["reasoning"] == {"effort": "high"}


def test_bootstrap_matrix_uses_gemini_3_thinking_level() -> None:
    provider = {
        "name": "vertex",
        "api_type": "gemini-compatible",
        "compat_mode": "vertex_express",
        "models": ["gemini-3.5-flash"],
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {"generationConfig": {"topP": 0.95}},
        },
    }

    out = _provider_with_reasoning(provider, "medium")

    body_overrides = out["request_mapping"]["body_overrides"]
    assert body_overrides["generationConfig"]["topP"] == 0.95
    assert body_overrides["generationConfig"]["thinkingConfig"] == {"thinkingLevel": "MEDIUM"}
    assert "reasoning" not in body_overrides
    assert "reasoning_effort" not in body_overrides


def test_bootstrap_matrix_removes_existing_thinking_for_none_case() -> None:
    provider = {
        "name": "vertex",
        "api_type": "gemini-compatible",
        "compat_mode": "vertex_express",
        "models": ["gemini-3.5-flash"],
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {
                "reasoning": {"effort": "high"},
                "reasoning_effort": "high",
                "generationConfig": {
                    "topP": 0.95,
                    "thinkingConfig": {"thinkingLevel": "HIGH"},
                },
            },
        },
    }

    out = _provider_without_reasoning(provider)

    body_overrides = out["request_mapping"]["body_overrides"]
    assert body_overrides == {"generationConfig": {"topP": 0.95}}


def test_bootstrap_matrix_uses_gemini_25_thinking_budget() -> None:
    provider = {
        "name": "vertex",
        "api_type": "gemini-compatible",
        "compat_mode": "vertex_express",
        "models": ["gemini-2.5-flash"],
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {"generationConfig": {"topP": 0.95}},
        },
    }

    out = _provider_with_reasoning(provider, "high")

    thinking = out["request_mapping"]["body_overrides"]["generationConfig"]["thinkingConfig"]
    assert thinking == {"thinkingBudget": 24576}


def test_bootstrap_matrix_rejects_invalid_gemini_3_thinking_level() -> None:
    provider = {
        "name": "vertex",
        "api_type": "gemini-compatible",
        "compat_mode": "vertex_express",
        "models": ["gemini-3.5-flash"],
        "request_mapping": {
            "style": "gemini_generate_content",
            "body_overrides": {"generationConfig": {"topP": 0.95}},
        },
    }

    with pytest.raises(RuntimeError, match="Unsupported Gemini thinking level"):
        _provider_with_reasoning(provider, "budget:1024")
