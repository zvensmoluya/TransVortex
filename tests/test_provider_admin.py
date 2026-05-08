from __future__ import annotations

import os
from pathlib import Path

import yaml

from transvortex.provider_admin import (
    draft_to_provider_config,
    fetch_provider_models,
    provider_templates_payload,
    run_provider_connection_test,
    save_provider_config,
)


def test_provider_templates_include_core_compat_modes() -> None:
    modes = {row["compat_mode"] for row in provider_templates_payload()}
    assert {
        "openai_chat",
        "openai_responses",
        "openai_completions",
        "anthropic_messages",
        "gemini_generate_content",
    }.issubset(modes)


def test_save_provider_config_writes_yaml_without_api_key(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("TVX_PROVIDER_MY_GATEWAY_API_KEY", raising=False)
    payload = save_provider_config(
        root_dir=tmp_path,
        provider_draft={
            "name": "my_gateway",
            "compat_mode": "openai_chat",
            "base_url": "https://gateway.example/v1",
            "env_key": "TVX_PROVIDER_MY_GATEWAY_API_KEY",
            "models": ["model-a"],
        },
        api_key="secret-key",
    )
    assert payload["has_key"] is True
    raw = (tmp_path / "providers.local.yaml").read_text(encoding="utf-8")
    assert "secret-key" not in raw
    assert "TVX_PROVIDER_MY_GATEWAY_API_KEY" in raw
    assert os.getenv("TVX_PROVIDER_MY_GATEWAY_API_KEY") == "secret-key"
    data = yaml.safe_load(raw)
    assert data["providers"][0]["name"] == "my_gateway"
    assert data["providers"][0]["model_list"]["path_template"] == "/models"


def test_draft_to_provider_config_uses_template_defaults() -> None:
    provider = draft_to_provider_config(
        {
            "name": "responses",
            "compat_mode": "openai_responses",
            "models": ["gpt-x"],
        }
    )
    assert provider.api_type == "openai-compatible"
    assert provider.endpoint.path_template == "/responses"
    assert provider.mapping.response["text_paths"][0] == "output_text"


def test_fetch_provider_models_parses_openai_shape(monkeypatch) -> None:
    def fake_request_json(url, payload, headers, timeout, method="GET"):
        assert url == "https://example.com/v1/models"
        assert method == "GET"
        return {"data": [{"id": "model-a"}, {"id": "model-b"}]}

    monkeypatch.setattr("transvortex.provider_admin._request_json", fake_request_json)
    report = fetch_provider_models(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
        },
        api_key="secret",
    )
    assert report["status"] == "PASS"
    assert report["models"] == ["model-a", "model-b"]


def test_fetch_provider_models_missing_key_fails() -> None:
    report = fetch_provider_models(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "MISSING_KEY",
            "models": ["model-a"],
        }
    )
    assert report["status"] == "FAIL"
    assert report["code"] == "provider_key_missing"


def test_provider_connection_maps_response(monkeypatch) -> None:
    def fake_request_json(url, payload, headers, timeout, method="POST"):
        assert payload["messages"][-1]["content"]
        return {"choices": [{"message": {"content": "[1] pong"}}]}

    monkeypatch.setattr("transvortex.provider_admin._request_json", fake_request_json)
    report = run_provider_connection_test(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
        },
        model="model-a",
        api_key="secret",
    )
    assert report["status"] == "PASS"
    assert report["checks"][0]["code"] == "provider_connection_ok"
