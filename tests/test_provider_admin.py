from __future__ import annotations

import os
from pathlib import Path

import yaml

from transvortex.http import HttpTransportError
from transvortex.providers.admin import (
    custom_adapter_template_payload,
    delete_provider_config,
    draft_to_provider_config,
    fetch_provider_models,
    providers_file_version,
    protocol_templates_payload,
    provider_presets_payload,
    provider_templates_payload,
    run_provider_connection_test,
    save_provider_config,
)


def _write_provider_admin_config(root: Path) -> None:
    (root / "providers.local.yaml").write_text(
        """
custom_top: keep-me
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: KEY
    models: [m1]
  - name: p2
    api_type: openai
    base_url: https://fallback.example/v1
    env_key: KEY
    models: [m2]
routing:
  active_profile: route_2
  next_profile_seq: 3
  primary: {provider: p2, model: m2}
  fallback: []
routing_profiles:
  - id: route_1
    name: 配置 1
    primary: {provider: p1, model: m1}
    fallback: []
  - id: route_2
    name: 配置 2
    primary: {provider: p2, model: m2}
    fallback:
      - {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (root / "pipeline.yaml").write_text("{}", encoding="utf-8")


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
        "vertex_express",
        "vertex_openai_compatible",
        "custom_json",
    }.issubset(ids)
    protocol_ids = {row["id"] for row in protocol_templates_payload()}
    assert "custom_json" not in protocol_ids
    assert {"openai_chat", "openai_responses", "vertex_native", "vertex_express"}.issubset(protocol_ids)
    preset_ids = {row["id"] for row in provider_presets_payload()}
    assert {"openai_official", "google_ai_studio", "google_vertex_gemini"}.issubset(preset_ids)
    assert custom_adapter_template_payload()["id"] == "custom_json"
    templates_by_id = {row["id"]: row for row in provider_templates_payload()}
    assert templates_by_id["openai_responses"]["capabilities"]["max_output_tokens"] == 65536
    assert "max_tokens" not in templates_by_id["anthropic_messages"]["request_mapping"]
    assert "maxOutputTokens" not in templates_by_id["gemini_ai_studio_native"]["request_mapping"]["body_overrides"]["generationConfig"]
    assert templates_by_id["vertex_express"]["auth"]["type"] == "query"
    assert templates_by_id["vertex_express"]["endpoint"]["path_template"] == "/publishers/google/models/{model}:generateContent"
    assert templates_by_id["vertex_express"]["model_list"]["path_template"] == ""
    assert templates_by_id["vertex_express"]["models"]
    assert "gemini-3.1-pro-preview" in templates_by_id["vertex_express"]["models"]
    assert "gemini-2.0-flash-001" not in templates_by_id["vertex_express"]["models"]
    presets_by_id = {row["id"]: row for row in provider_presets_payload()}
    assert presets_by_id["google_vertex_gemini"]["compat_mode"] == "vertex_express"


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


def test_fetch_vertex_express_models_reports_manual_fallback() -> None:
    report = fetch_provider_models(
        provider_draft={
            "name": "vertex",
            "compat_mode": "vertex_express",
            "env_key": "KEY",
        },
        api_key="secret",
    )
    assert report["status"] == "WARN"
    assert report["code"] == "provider_model_list_unsupported"
    assert report["models"]
    assert "Vertex 的模型列表" in report["hint_zh"]


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


def test_provider_connection_retries_transient_upstream_error(monkeypatch) -> None:
    calls = 0

    def fake_request_json(url, payload, headers, timeout, method="POST"):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise HttpTransportError("bad_gateway", "provider upstream returned HTTP 502: Bad Gateway", status_code=502)
        return {"choices": [{"message": {"content": "[1] pong"}}]}

    monkeypatch.setattr("transvortex.providers.admin.time.sleep", lambda seconds: None)
    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
    report = run_provider_connection_test(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
            "limits": {"retry": 3},
        },
        model="model-a",
        api_key="secret",
    )
    assert report["status"] == "PASS"
    assert calls == 2
    assert report["checks"][0]["details"]["attempts"] == 2


def test_provider_connection_reports_upstream_error_hint(monkeypatch) -> None:
    def fake_request_json(url, payload, headers, timeout, method="POST"):
        raise HttpTransportError("bad_gateway", "provider upstream returned HTTP 502: Bad Gateway", status_code=502)

    monkeypatch.setattr("transvortex.providers.admin.time.sleep", lambda seconds: None)
    monkeypatch.setattr("transvortex.providers.admin._request_json", fake_request_json)
    report = run_provider_connection_test(
        provider_draft={
            "name": "openai_like",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
            "limits": {"retry": 2},
        },
        model="model-a",
        api_key="secret",
    )
    assert report["status"] == "FAIL"
    assert report["checks"][0]["code"] == "provider_upstream_error"
    assert report["checks"][0]["details"] == {"status": 502, "attempts": 2}
    assert "网关或上游服务" in report["checks"][0]["hint_zh"]


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


def test_save_provider_config_preserves_output_token_capabilities(tmp_path: Path) -> None:
    save_provider_config(
        root_dir=tmp_path,
        provider_draft={
            "name": "advanced",
            "compat_mode": "openai_chat",
            "base_url": "https://example.com/v1",
            "env_key": "KEY",
            "models": ["model-a"],
            "capabilities": {
                "max_batch_lines": 500,
                "max_context_tokens": 300000,
                "max_output_tokens": 65536,
                "recommended_output_tokens": 32768,
                "output_token_param": "max_completion_tokens",
            },
        },
    )
    data = yaml.safe_load((tmp_path / "providers.local.yaml").read_text(encoding="utf-8"))
    capabilities = data["providers"][0]["capabilities"]
    assert capabilities["max_batch_lines"] == 500
    assert capabilities["max_context_tokens"] == 300000
    assert capabilities["max_output_tokens"] == 65536
    assert capabilities["recommended_output_tokens"] == 32768
    assert capabilities["output_token_param"] == "max_completion_tokens"


def test_draft_to_provider_config_preserves_camel_case_output_token_capabilities() -> None:
    provider = draft_to_provider_config(
        {
            "name": "advanced",
            "compat_mode": "openai_chat",
            "models": ["model-a"],
            "capabilities": {
                "maxBatchLines": 500,
                "maxContextTokens": 300000,
                "maxOutputTokens": 65536,
                "recommendedOutputTokens": 32768,
                "outputTokenParam": "max_completion_tokens",
            },
        }
    )
    assert provider.capabilities.max_batch_lines == 500
    assert provider.capabilities.max_context_tokens == 300000
    assert provider.capabilities.max_output_tokens == 65536
    assert provider.capabilities.recommended_output_tokens == 32768
    assert provider.capabilities.output_token_param == "max_completion_tokens"


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


def test_delete_provider_blocks_when_route_profile_references_provider(tmp_path: Path) -> None:
    _write_provider_admin_config(tmp_path)
    payload = delete_provider_config(root_dir=tmp_path, name="p1")
    assert payload["deleted"] is False
    assert payload["blocked"] is True
    assert payload["code"] == "provider_in_use"
    assert {ref["route"] for ref in payload["references"]} == {"primary", "fallback[0]"}


def test_delete_provider_preserves_profiles_next_seq_and_unknown_fields(tmp_path: Path) -> None:
    _write_provider_admin_config(tmp_path)
    data = yaml.safe_load((tmp_path / "providers.local.yaml").read_text(encoding="utf-8"))
    data["routing_profiles"][1]["primary"] = {"provider": "p1", "model": "m1"}
    data["routing_profiles"][1]["fallback"] = []
    data["routing"]["active_profile"] = "route_1"
    data["routing"]["primary"] = {"provider": "p1", "model": "m1"}
    (tmp_path / "providers.local.yaml").write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")

    payload = delete_provider_config(root_dir=tmp_path, name="p2")
    assert payload["deleted"] is True
    saved = yaml.safe_load((tmp_path / "providers.local.yaml").read_text(encoding="utf-8"))
    assert saved["custom_top"] == "keep-me"
    assert saved["routing"]["next_profile_seq"] == 3
    assert saved["routing_profiles"][1]["id"] == "route_2"


def test_provider_save_rejects_stale_expected_version(tmp_path: Path) -> None:
    _write_provider_admin_config(tmp_path)
    version = providers_file_version(tmp_path / "providers.local.yaml")
    raw = (tmp_path / "providers.local.yaml").read_text(encoding="utf-8")
    (tmp_path / "providers.local.yaml").write_text(raw + "\n# changed\n", encoding="utf-8")
    try:
        save_provider_config(
            root_dir=tmp_path,
            provider_draft={
                "name": "p3",
                "compat_mode": "openai_chat",
                "base_url": "https://p3.example/v1",
                "env_key": "KEY",
                "models": ["m3"],
            },
            expected_version=version,
        )
    except ValueError as exc:
        assert "provider_config_conflict" in str(exc)
    else:  # pragma: no cover - assertion branch
        raise AssertionError("expected stale version to fail")
