from __future__ import annotations

from transvortex.app.models import (
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    NormalizedRequest,
    ProviderConfig,
    ProviderLimits,
)
from transvortex.providers.factory import (
    ConfigurableProtocolClient,
    _build_payload,
    _build_url_and_headers,
    _extract_numbered_lines,
    _extract_text_by_paths,
    response_shape_summary,
)


def test_provider_client_uses_dotenv_fallback(tmp_path, monkeypatch) -> None:
    cfg = ProviderConfig(
        name="openai_like",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["model-a"],
        credential_root_dir=tmp_path,
        mapping=MappingConfig(request={"style": "openai_chat"}, response={"text_paths": ["choices[0].message.content"]}),
    )
    (tmp_path / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")

    def fake_post_json(url, payload, headers, timeout, method="POST"):
        assert headers["Authorization"] == "Bearer from-dotenv"
        return {"choices": [{"message": {"content": "[1] pong"}}]}

    monkeypatch.setattr("transvortex.providers.factory._post_json", fake_post_json)
    client = ConfigurableProtocolClient(config=cfg, timeout=30)
    response = client.translate_request(
        NormalizedRequest(model="model-a", lines=["[1] ping"], source_lang="en", target_lang="zh-CN")
    )
    assert response.numbered_lines == ["[1] pong"]


def test_response_mapping_multi_shape() -> None:
    data = {"content": [{"text": "a"}, {"text": "b"}]}
    out = _extract_text_by_paths(data, ["choices[0].message.content", "content[].text"])
    assert out == "a\nb"


def test_extract_numbered_lines_normalizes_common_model_formats() -> None:
    text = "Here you go:\n1. 你好\n2) 世界\n（3）：再见\nnot a numbered row"
    assert _extract_numbered_lines(text) == ["[1] 你好", "[2] 世界", "[3] 再见"]


def test_query_auth_builds_url() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="GEMINI_KEY",
        models=["m1"],
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/models/{model}:generateContent", method="POST"),
        mapping=MappingConfig(request={"style": "gemini_generate_content"}, response={}),
        limits=ProviderLimits(),
    )
    url, headers = _build_url_and_headers(cfg, "abc", "m1")
    assert "key=abc" in url
    assert headers == {}


def test_anthropic_url_v1_dedup_and_header_auth() -> None:
    cfg = ProviderConfig(
        name="vector",
        api_type="anthropic",
        compat_mode="anthropic_messages",
        base_url="https://api.vectorengine.ai/v1",
        env_key="TVX_MODEL_API_KEY",
        models=["claude-haiku-4-5-20251001"],
        auth=AuthConfig(type="header", header_name="x-api-key", prefix=""),
        endpoint=EndpointConfig(path_template="/v1/messages", method="POST"),
        mapping=MappingConfig(request={"style": "anthropic_messages"}, response={"text_paths": ["content[].text"]}),
        limits=ProviderLimits(),
    )
    url, headers = _build_url_and_headers(cfg, "secret", "claude-haiku-4-5-20251001")
    assert url == "https://api.vectorengine.ai/v1/messages"
    assert headers["x-api-key"] == "secret"


def test_payload_contains_style_and_context_sections() -> None:
    cfg = ProviderConfig(
        name="p1",
        api_type="openai",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(request={"style": "openai_chat"}, response={}),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(
        model="m1",
        lines=["[2] hello"],
        source_lang="en",
        target_lang="zh-CN",
        context_before=["[1] before"],
        context_after=["[3] after"],
        style_prompt="Keep it concise.",
    )
    payload = _build_payload(cfg, req)
    messages = payload["messages"]
    assert messages[0]["role"] == "system"
    user_text = messages[1]["content"]
    assert "User style preferences:\nKeep it concise." in user_text
    assert "CONTEXT_BEFORE\n[1] before" in user_text
    assert "TRANSLATE_ONLY\n[2] hello" in user_text
    assert "CONTEXT_AFTER\n[3] after" in user_text


def test_payload_contains_memory_prompt_between_style_and_context() -> None:
    cfg = ProviderConfig(
        name="p1",
        api_type="openai",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(request={"style": "openai_chat"}, response={}),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(
        model="m1",
        lines=["[1] Subaru"],
        source_lang="en",
        target_lang="zh-CN",
        style_prompt="Keep it concise.",
        memory_prompt="LOCKED GLOSSARY\n- Subaru => 斯巴鲁",
    )
    payload = _build_payload(cfg, req)
    user_text = payload["messages"][1]["content"]
    assert user_text.index("User style preferences") < user_text.index("LOCKED GLOSSARY")
    assert user_text.index("LOCKED GLOSSARY") < user_text.index("\n\nTRANSLATE_ONLY")


def test_openai_responses_payload_and_mapping() -> None:
    cfg = ProviderConfig(
        name="responses",
        api_type="openai-compatible",
        compat_mode="openai_responses",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(
            request={"style": "openai_responses"},
            response={"text_paths": ["output_text", "output[].content[].text"]},
        ),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    payload = _build_payload(cfg, req)
    assert payload["model"] == "m1"
    assert payload["input"][0]["role"] == "system"
    assert payload["input"][-1]["role"] == "user"
    assert _extract_text_by_paths({"output_text": "[1] 你好"}, cfg.mapping.response["text_paths"]) == "[1] 你好"


def test_openai_completions_payload_and_mapping() -> None:
    cfg = ProviderConfig(
        name="completions",
        api_type="openai-compatible",
        compat_mode="openai_completions",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(
            request={"style": "openai_completions", "max_tokens": 128},
            response={"text_paths": ["choices[0].text"]},
        ),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    payload = _build_payload(cfg, req)
    assert payload["prompt"]
    assert payload["max_tokens"] == 128
    assert _extract_text_by_paths({"choices": [{"text": "[1] 你好"}]}, cfg.mapping.response["text_paths"]) == "[1] 你好"


def test_payload_inlines_fixed_constraints_when_system_prompt_not_supported() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(supports_system_prompt=False),
        mapping=MappingConfig(request={"style": "gemini_generate_content"}, response={}),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    payload = _build_payload(cfg, req)
    text = payload["contents"][0]["parts"][0]["text"]
    assert "You are a professional subtitle translator for film and TV dialogue." in text
    assert "Fixed output constraints:" in text


def test_body_overrides_add_openai_special_fields() -> None:
    cfg = ProviderConfig(
        name="p1",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(
            request={
                "style": "openai_chat",
                "body_overrides": {
                    "reasoning_effort": "low",
                    "extra_body": {"google": {"thinking_config": {"thinking_budget": 0}}},
                },
            },
            response={},
        ),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["reasoning_effort"] == "low"
    assert payload["extra_body"]["google"]["thinking_config"]["thinking_budget"] == 0


def test_body_overrides_add_gemini_generation_fields() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(supports_system_prompt=False),
        mapping=MappingConfig(
            request={
                "style": "gemini_generate_content",
                "body_overrides": {
                    "generationConfig": {"topP": 0.95, "maxOutputTokens": 8192},
                    "safetySettings": [{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"}],
                    "thinkingConfig": {"thinkingBudget": 0},
                },
            },
            response={},
        ),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["generationConfig"]["temperature"] == 0.1
    assert payload["generationConfig"]["topP"] == 0.95
    assert payload["generationConfig"]["maxOutputTokens"] == 8192
    assert payload["safetySettings"][0]["threshold"] == "BLOCK_NONE"
    assert payload["thinkingConfig"]["thinkingBudget"] == 0


def test_body_remove_paths_removes_default_payload_fields() -> None:
    cfg = ProviderConfig(
        name="p1",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(request={"style": "openai_chat", "body_remove_paths": ["temperature"]}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert "temperature" not in payload


def test_query_params_coexist_with_query_auth() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="KEY",
        models=["m1"],
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/models/{model}:generateContent", method="POST"),
        mapping=MappingConfig(
            request={"style": "gemini_generate_content", "query_params": {"api-version": "2024-01-01", "model_hint": "{{model}}"}},
            response={},
        ),
        limits=ProviderLimits(),
    )
    url, _headers = _build_url_and_headers(cfg, "secret", "m1")
    assert "api-version=2024-01-01" in url
    assert "model_hint=m1" in url
    assert "key=secret" in url


def test_custom_json_renders_body_template_and_extracts_text() -> None:
    cfg = ProviderConfig(
        name="custom",
        api_type="custom",
        compat_mode="custom_json",
        base_url="https://example.com",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(
            request={
                "style": "custom_json",
                "body_template": {
                    "model": "{{model}}",
                    "input": "{{prompt}}",
                    "lines": "{{lines}}",
                    "meta": {"source": "{{source_lang}}", "target": "{{target_lang}}"},
                },
            },
            response={"text_paths": ["result.text"]},
        ),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["model"] == "m1"
    assert payload["lines"] == ["[1] hello"]
    assert payload["meta"] == {"source": "en", "target": "zh-CN"}
    assert _extract_text_by_paths({"result": {"text": "[1] 你好"}}, cfg.mapping.response["text_paths"]) == "[1] 你好"
    assert response_shape_summary({"result": {"text": "[1] 你好"}}) == {"result": {"text": "str"}}
