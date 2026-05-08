from __future__ import annotations

from transvortex.models import (
    AuthConfig,
    CapabilityConfig,
    EndpointConfig,
    MappingConfig,
    NormalizedRequest,
    ProviderConfig,
    ProviderLimits,
)
from transvortex.providers.factory import (
    _build_payload,
    _build_url_and_headers,
    _extract_numbered_lines,
    _extract_text_by_paths,
)


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
    assert "You are a subtitle translation engine." in text
    assert "Fixed output constraints:" in text
