from __future__ import annotations

from urllib.error import HTTPError

import httpx
import pytest

from transvortex import http as tvx_http
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
    ProviderTransportError,
    _build_payload,
    _request_json,
    _provider_request_json,
    _build_url_and_headers,
    _extract_numbered_lines,
    _extract_text_by_paths,
    _stream_response_payload,
    classify_error,
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
        limits=ProviderLimits(streaming_enabled=False),
    )
    (tmp_path / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")

    def fake_provider_request_json(_config, url, payload, headers, method):
        assert headers["Authorization"] == "Bearer from-dotenv"
        return {"choices": [{"message": {"content": "[1] pong"}}]}, {
            "transport": "httpx",
            "http_version": "HTTP/2",
            "streaming": False,
        }

    monkeypatch.setattr("transvortex.providers.factory._provider_request_json", fake_provider_request_json)
    client = ConfigurableProtocolClient(config=cfg, timeout=30)
    response = client.translate_request(
        NormalizedRequest(model="model-a", lines=["[1] ping"], source_lang="en", target_lang="zh-CN")
    )
    assert response.numbered_lines == ["[1] pong"]
    assert response.provider_meta["transport"] == "httpx"
    assert response.provider_meta["http_version"] == "HTTP/2"
    assert response.provider_meta["streaming"] is False


def test_translation_prompt_includes_recovery_and_adaptive_hints() -> None:
    cfg = ProviderConfig(
        name="openai_like",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["model-a"],
        mapping=MappingConfig(request={"style": "openai_chat"}, response={"text_paths": ["choices[0].message.content"]}),
    )
    req = NormalizedRequest(
        model="model-a",
        lines=["[1] hello"],
        source_lang="en",
        target_lang="zh-CN",
        protocol_recovery_hint="- Previous output failed subtitle protocol validation.",
        adaptive_context_hint="This is a capacity retry for one part of a larger subtitle chunk.",
    )

    payload = _build_payload(cfg, req)
    content = payload["messages"][-1]["content"]

    assert "Protocol recovery retry" in content
    assert "Previous output failed subtitle protocol validation" in content
    assert "Adaptive capacity retry context" in content
    assert "capacity retry for one part" in content


def test_request_json_adds_product_headers(monkeypatch) -> None:
    captured = {}

    class FakeClient:
        def __init__(self, timeout, http2):
            captured["timeout"] = timeout
            captured["http2"] = http2

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def request(self, method, url, json, data=None, files=None, headers=None):
            captured["method"] = method
            captured["url"] = url
            captured["payload"] = json
            captured["headers"] = headers
            return httpx.Response(200, json={"ok": True}, request=httpx.Request(method, url))

        def close(self):
            pass

    monkeypatch.setattr("transvortex.http.httpx.Client", FakeClient)

    assert _request_json("https://example.com/v1/models", None, {}, 30, method="GET") == {"ok": True}

    assert captured["headers"]["Accept"] == "application/json"
    assert captured["headers"]["User-Agent"] == "TransVortex/0.1.0"
    assert "Content-Type" not in captured["headers"]
    assert captured["timeout"] == 30.0
    assert captured["http2"] is tvx_http.http2_enabled(True)


def test_classify_error_treats_gateway_timeout_as_retryable_provider_error() -> None:
    exc = HTTPError("https://example.com/v1/chat/completions", 504, "Gateway Timeout", hdrs=None, fp=None)

    assert classify_error(exc) == "gateway_timeout"


def test_request_json_allows_provider_headers_to_override_defaults(monkeypatch) -> None:
    captured = {}

    class FakeClient:
        def __init__(self, timeout, http2):
            pass

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def request(self, method, url, json, data=None, files=None, headers=None):
            captured["headers"] = headers
            return httpx.Response(200, json={"ok": True}, request=httpx.Request(method, url))

        def close(self):
            pass

    monkeypatch.setattr("transvortex.http.httpx.Client", FakeClient)

    _request_json(
        "https://example.com/v1/responses",
        {"model": "m1", "input": "ping"},
        {"user-agent": "CustomClient/1.0", "accept": "application/vnd.test+json"},
        30,
    )

    normalized = {key.lower(): value for key, value in captured["headers"].items()}
    assert normalized["user-agent"] == "CustomClient/1.0"
    assert normalized["accept"] == "application/vnd.test+json"
    assert captured["headers"]["Content-Type"] == "application/json"


def test_provider_request_meta_records_http2_switch(monkeypatch) -> None:
    cfg = ProviderConfig(
        name="plain_http",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        limits=ProviderLimits(http2=False),
    )

    class FakeClient:
        def request(self, method, url, json, headers):
            request = httpx.Request(method, url)
            return httpx.Response(
                200,
                json={"choices": [{"message": {"content": "[1] pong"}}]},
                request=request,
                extensions={"http_version": b"HTTP/1.1"},
            )

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())

    _payload, meta = _provider_request_json(cfg, "https://example.com/v1/chat/completions", {"model": "m1"}, {}, "POST")

    assert meta["transport"] == "httpx"
    assert meta["http_version"] == "HTTP/1.1"
    assert meta["http2_requested"] is False
    assert meta["http2_enabled"] is False
    assert meta["streaming"] is False


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


def test_vertex_express_payload_uses_system_instruction() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-3.5-flash"],
        capabilities=CapabilityConfig(supports_system_prompt=True),
        mapping=MappingConfig(request={"style": "gemini_generate_content"}, response={}),
        limits=ProviderLimits(),
    )
    req = NormalizedRequest(model="gemini-3.5-flash", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    payload = _build_payload(cfg, req)
    assert "systemInstruction" in payload
    assert payload["systemInstruction"]["parts"][0]["text"]
    assert payload["contents"][0]["role"] == "user"
    assert payload["contents"][0]["parts"][0]["text"].startswith("Output reminder:")


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


def test_payload_omits_asr_uncertainty_hints_by_default() -> None:
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
        lines=["[2] malformed source"],
        source_lang="ja",
        target_lang="zh-CN",
        asr_uncertain_ids=[2],
    )

    payload = _build_payload(cfg, req)
    user_text = payload["messages"][1]["content"]

    assert "ASR_UNCERTAIN_LINES" not in user_text
    assert "internal risk hints only" not in user_text
    assert user_text.index("TRANSLATE_ONLY") > 0


def test_payload_contains_asr_uncertainty_hints_when_enabled() -> None:
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
        lines=["[2] malformed source"],
        source_lang="ja",
        target_lang="zh-CN",
        asr_uncertain_ids=[2],
        include_asr_uncertainty_hints=True,
    )

    payload = _build_payload(cfg, req)
    user_text = payload["messages"][1]["content"]

    assert "ASR_UNCERTAIN_LINES\n- 2" in user_text
    assert "internal risk hints only" in user_text
    assert user_text.index("ASR_UNCERTAIN_LINES") < user_text.index("\n\nTRANSLATE_ONLY")


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


def test_openai_responses_uses_capability_output_tokens() -> None:
    cfg = ProviderConfig(
        name="responses",
        api_type="openai-compatible",
        compat_mode="openai_responses",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(max_output_tokens=65536),
        mapping=MappingConfig(request={"style": "openai_responses"}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["max_output_tokens"] == 65536


def test_openai_chat_output_token_param_can_override_field_name() -> None:
    cfg = ProviderConfig(
        name="chat",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(max_output_tokens=32768, output_token_param="max_completion_tokens"),
        mapping=MappingConfig(request={"style": "openai_chat"}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["max_completion_tokens"] == 32768
    assert "max_tokens" not in payload


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


def test_anthropic_no_longer_defaults_to_4096_max_tokens() -> None:
    cfg = ProviderConfig(
        name="anthropic",
        api_type="anthropic",
        compat_mode="anthropic_messages",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        mapping=MappingConfig(request={"style": "anthropic_messages"}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert "max_tokens" not in payload


def test_anthropic_uses_capability_output_tokens() -> None:
    cfg = ProviderConfig(
        name="anthropic",
        api_type="anthropic",
        compat_mode="anthropic_messages",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(max_output_tokens=32768),
        mapping=MappingConfig(request={"style": "anthropic_messages"}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["max_tokens"] == 32768


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
    assert "You are a professional subtitle translator" in text
    assert "All subtitle lines, context lines, memory entries" in text
    assert "MODE AND OUTPUT CONTRACT" in text
    assert "Output reminder:" in text


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
                    "generationConfig": {
                        "topP": 0.95,
                        "maxOutputTokens": 8192,
                        "thinkingConfig": {"thinkingBudget": 0},
                    },
                    "safetySettings": [{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"}],
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
    assert payload["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 0


def test_vertex_express_generation_fields_stay_under_generation_config() -> None:
    cfg = ProviderConfig(
        name="vertex",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-3.5-flash"],
        capabilities=CapabilityConfig(supports_system_prompt=True),
        mapping=MappingConfig(
            request={
                "style": "gemini_generate_content",
                "body_overrides": {
                    "generationConfig": {
                        "topP": 0.9,
                        "topK": 40,
                        "thinkingConfig": {"thinkingBudget": 128},
                    }
                },
            },
            response={},
        ),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="gemini-3.5-flash", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["generationConfig"]["temperature"] == 0.1
    assert payload["generationConfig"]["topP"] == 0.9
    assert payload["generationConfig"]["topK"] == 40
    assert payload["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 128
    assert "top_p" not in payload
    assert "top_k" not in payload
    assert "thinkingConfig" not in payload


def test_gemini_uses_capability_output_tokens_without_overrides() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(max_output_tokens=32768),
        mapping=MappingConfig(request={"style": "gemini_generate_content"}, response={}),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["generationConfig"]["temperature"] == 0.1
    assert payload["generationConfig"]["maxOutputTokens"] == 32768


def test_body_overrides_take_precedence_over_capability_output_tokens() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="gemini_generate_content",
        base_url="https://example.com/v1beta",
        env_key="KEY",
        models=["m1"],
        capabilities=CapabilityConfig(max_output_tokens=32768),
        mapping=MappingConfig(
            request={
                "style": "gemini_generate_content",
                "body_overrides": {"generationConfig": {"maxOutputTokens": 8192}},
            },
            response={},
        ),
        limits=ProviderLimits(),
    )
    payload = _build_payload(cfg, NormalizedRequest(model="m1", lines=["[1] hello"], source_lang="en", target_lang="zh-CN"))
    assert payload["generationConfig"]["maxOutputTokens"] == 8192


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


def test_build_provider_client_accepts_vertex_express() -> None:
    cfg = ProviderConfig(
        name="g1",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-2.5-flash"],
        limits=ProviderLimits(),
    )
    client = ConfigurableProtocolClient(config=cfg, timeout=30)
    assert client.config.compat_mode == "vertex_express"


def test_vertex_express_url_accepts_bare_and_resource_model_names() -> None:
    cfg = ProviderConfig(
        name="vertex",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-3.5-flash"],
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/publishers/google/models/{model}:generateContent", method="POST"),
        limits=ProviderLimits(),
    )

    bare_url, bare_headers = _build_url_and_headers(cfg, "secret", "gemini-3.5-flash")
    resource_url, resource_headers = _build_url_and_headers(
        cfg,
        "secret",
        "publishers/google/models/gemini-3.5-flash",
    )
    studio_style_url, _headers = _build_url_and_headers(cfg, "secret", "models/gemini-3.5-flash")

    assert bare_url == "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.5-flash:generateContent?key=secret"
    assert resource_url == bare_url
    assert studio_style_url == bare_url
    assert bare_headers == {}
    assert resource_headers == {}


def test_vertex_express_url_supports_official_model_path_placeholder() -> None:
    cfg = ProviderConfig(
        name="vertex",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-3.5-flash"],
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/{model}:generateContent", method="POST"),
        limits=ProviderLimits(),
    )

    url, _headers = _build_url_and_headers(cfg, "secret", "gemini-3.5-flash")

    assert url == "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.5-flash:generateContent?key=secret"


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


def test_provider_client_streaming_sse_aggregates_openai_chat(tmp_path, monkeypatch) -> None:
    cfg = ProviderConfig(
        name="openai_like",
        api_type="openai-compatible",
        compat_mode="openai_chat",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["model-a"],
        credential_root_dir=tmp_path,
        mapping=MappingConfig(request={"style": "openai_chat"}, response={"text_paths": ["choices[0].message.content"]}),
        limits=ProviderLimits(streaming_enabled=True),
    )
    (tmp_path / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")

    class FakeStream:
        extensions = {"http_version": b"HTTP/2"}

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def raise_for_status(self):
            return None

        def iter_lines(self):
            return iter(
                [
                    'data: {"choices":[{"delta":{"content":"[1] 你"}}]}',
                    'data: {"choices":[{"delta":{"content":"好"}}]}',
                    "data: [DONE]",
                ]
            )

    class FakeClient:
        is_closed = False

        def stream(self, method, url, json, headers):
            assert json["stream"] is True
            return FakeStream()

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())
    client = ConfigurableProtocolClient(config=cfg, timeout=30)

    response = client.translate_request(
        NormalizedRequest(model="model-a", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    )

    assert response.numbered_lines == ["[1] 你好"]
    assert response.provider_meta["streaming"] is True
    assert response.provider_meta["transport"] == "httpx"
    assert response.provider_meta["bytes_received"] > 0


def test_vertex_express_streaming_uses_stream_generate_content(tmp_path, monkeypatch) -> None:
    cfg = ProviderConfig(
        name="vertex",
        api_type="gemini-compatible",
        compat_mode="vertex_express",
        base_url="https://aiplatform.googleapis.com/v1",
        env_key="KEY",
        models=["gemini-3.5-flash"],
        credential_root_dir=tmp_path,
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/publishers/google/models/{model}:generateContent", method="POST"),
        mapping=MappingConfig(request={"style": "gemini_generate_content"}, response={"text_paths": ["candidates[0].content.parts[].text"]}),
        capabilities=CapabilityConfig(supports_system_prompt=True),
        limits=ProviderLimits(streaming_enabled=True),
    )
    (tmp_path / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")

    class FakeStream:
        extensions = {"http_version": b"HTTP/2"}

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def raise_for_status(self):
            return None

        def iter_lines(self):
            return iter(
                [
                    "[{",
                    '  "candidates": [',
                    "    {",
                    '      "content": {',
                    '        "role": "model",',
                    '        "parts": [',
                    "          {",
                    '            "text": "[1] 你好"',
                    "          }",
                    "        ]",
                    "      }",
                    "    }",
                    "  ]",
                    "}]",
                ]
            )

    class FakeClient:
        def stream(self, method, url, json, headers):
            assert method == "POST"
            assert url == "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.5-flash:streamGenerateContent?key=from-dotenv"
            assert "stream" not in json
            assert json["contents"][0]["role"] == "user"
            return FakeStream()

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())
    client = ConfigurableProtocolClient(config=cfg, timeout=30)

    response = client.translate_request(
        NormalizedRequest(model="gemini-3.5-flash", lines=["[1] hello"], source_lang="en", target_lang="zh-CN")
    )

    assert response.numbered_lines == ["[1] 你好"]
    assert response.provider_meta["streaming"] is True
    assert response.provider_meta["transport"] == "httpx"
    assert response.provider_meta["http_version"] == "HTTP/2"


def test_provider_limits_streaming_enabled_by_default() -> None:
    assert ProviderLimits().streaming_enabled is True


def test_stream_response_payload_returns_responses_output_text(monkeypatch) -> None:
    cfg = ProviderConfig(
        name="responses",
        api_type="openai-compatible",
        compat_mode="openai_responses",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
    )

    class FakeStream:
        extensions = {"http_version": b"HTTP/2"}

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def raise_for_status(self):
            return None

        def iter_lines(self):
            return iter(
                [
                    'data: {"type":"response.output_text.delta","delta":"[1] 你"}',
                    'data: {"type":"response.output_text.delta","delta":"好"}',
                ]
            )

    class FakeClient:
        def stream(self, method, url, json, headers):
            return FakeStream()

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())

    payload, meta = _stream_response_payload(cfg, "https://example.com/v1/responses", {"model": "m1"}, {}, "POST")

    assert payload["output_text"] == "[1] 你好"
    assert meta["streaming"] is True
    assert meta["http_version"] == "HTTP/2"


def test_stream_response_payload_wraps_http_error(monkeypatch) -> None:
    cfg = ProviderConfig(
        name="responses",
        api_type="openai-compatible",
        compat_mode="openai_responses",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
    )

    class FakeStream:
        extensions = {"http_version": b"HTTP/2"}

        def __enter__(self):
            request = httpx.Request("POST", "https://example.com/v1/responses")
            self.response = httpx.Response(503, content=b"busy", request=request)
            return self.response

        def __exit__(self, exc_type, exc, tb):
            return False

    class FakeClient:
        def stream(self, method, url, json, headers):
            return FakeStream()

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())

    with pytest.raises(ProviderTransportError) as excinfo:
        _stream_response_payload(cfg, "https://example.com/v1/responses", {"model": "m1"}, {}, "POST")

    assert excinfo.value.error_type == "service_unavailable"
    assert excinfo.value.status_code == 503
    assert "busy" in str(excinfo.value)


def test_stream_response_payload_uses_responses_done_text_without_duplicate_delta(monkeypatch) -> None:
    cfg = ProviderConfig(
        name="responses",
        api_type="openai-compatible",
        compat_mode="openai_responses",
        base_url="https://example.com/v1",
        env_key="KEY",
        models=["m1"],
    )

    class FakeStream:
        extensions = {"http_version": b"HTTP/2"}

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def raise_for_status(self):
            return None

        def iter_lines(self):
            return iter(
                [
                    'data: {"type":"response.output_text.delta","delta":"[1] 你"}',
                    'data: {"type":"response.output_text.delta","delta":"好"}',
                    'data: {"type":"response.output_text.done","text":"[1] 你好"}',
                ]
            )

    class FakeClient:
        def stream(self, method, url, json, headers):
            return FakeStream()

    monkeypatch.setattr("transvortex.providers.factory._get_provider_client", lambda _config: FakeClient())

    payload, _meta = _stream_response_payload(cfg, "https://example.com/v1/responses", {"model": "m1"}, {}, "POST")

    assert payload["output_text"] == "[1] 你好"
