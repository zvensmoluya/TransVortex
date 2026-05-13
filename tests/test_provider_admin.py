from __future__ import annotations

import os
from pathlib import Path

import yaml

from transvortex.providers.admin import (
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
        "custom_json",
    }.issubset(modes)
    ids = {row["id"] for row in provider_templates_payload()}
    assert {
        "gemini_ai_studio_native",
        "gemini_openai_compatible",
        "vertex_native",
        "vertex_openai_compatible",
        "custom_json",
    }.issubset(ids)


def test_save_provider_config_writes_yaml_without_api_key(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
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
    assert os.getenv("TVX_PROVIDER_MY_GATEWAY_API_KEY") is None
    assert payload["credential_source"] == "auth_json"
    auth_raw = (tmp_path / "home" / "auth.json").read_text(encoding="utf-8")
    assert "secret-key" in auth_raw
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

    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
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


def test_fetch_provider_models_uses_auth_json(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    from transvortex.app.credentials import write_auth_credential

    write_auth_credential("openai_like", "secret")

    def fake_request_json(url, payload, headers, timeout, method="GET"):
        assert headers["Authorization"] == "Bearer secret"
        return {"data": [{"id": "model-a"}]}

    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
    report = fetch_provider_models(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
        },
        root_dir=tmp_path,
    )
    assert report["status"] == "PASS"
    assert report["credential_source"] == "auth_json"


def test_provider_connection_uses_dotenv_fallback(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")

    def fake_request_json(url, payload, headers, timeout, method="POST"):
        assert headers["Authorization"] == "Bearer from-dotenv"
        return {"choices": [{"message": {"content": "[1] pong"}}]}

    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
    report = run_provider_connection_test(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
        },
        model="model-a",
        root_dir=tmp_path,
    )
    assert report["status"] == "PASS"
    assert report["checks"][0]["details"]["credential_source"] == "dotenv"


def test_provider_connection_maps_response(monkeypatch) -> None:
    def fake_request_json(url, payload, headers, timeout, method="POST"):
        assert payload["messages"][-1]["content"]
        return {"choices": [{"message": {"content": "[1] pong"}}]}

    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
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


def test_save_provider_config_preserves_advanced_request_mapping(tmp_path: Path) -> None:
    save_provider_config(
        root_dir=tmp_path,
        provider_draft={
            "name": "advanced",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
            "request_mapping": {
                "style": "openai_chat",
                "body_overrides": {"reasoning_effort": "low"},
                "query_params": {"api-version": "2024-01-01"},
            },
        },
    )
    data = yaml.safe_load((tmp_path / "providers.local.yaml").read_text(encoding="utf-8"))
    mapping = data["providers"][0]["request_mapping"]
    assert mapping["body_overrides"]["reasoning_effort"] == "low"
    assert mapping["query_params"]["api-version"] == "2024-01-01"


def test_provider_connection_reports_response_shape_when_mapping_fails(monkeypatch) -> None:
    def fake_request_json(url, payload, headers, timeout, method="POST"):
        return {"unexpected": {"nested": [{"text": "[1] pong"}]}}

    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
    report = run_provider_connection_test(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
            "response_mapping": {"text_paths": ["missing.path"]},
        },
        model="model-a",
        api_key="secret",
    )
    assert report["status"] == "FAIL"
    assert report["checks"][0]["details"]["response_shape"] == {"unexpected": {"nested": [{"text": "str"}]}}
