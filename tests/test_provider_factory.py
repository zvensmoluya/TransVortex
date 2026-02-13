from __future__ import annotations

from transvortex.models import AuthConfig, EndpointConfig, MappingConfig, ProviderConfig, ProviderLimits
from transvortex.providers.factory import _build_url_and_headers, _extract_text_by_paths


def test_response_mapping_multi_shape() -> None:
    data = {"content": [{"text": "a"}, {"text": "b"}]}
    out = _extract_text_by_paths(data, ["choices[0].message.content", "content[].text"])
    assert out == "a\nb"


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
        env_key="VECTORENGINE_API_KEY",
        models=["claude-haiku-4-5-20251001"],
        auth=AuthConfig(type="header", header_name="x-api-key", prefix=""),
        endpoint=EndpointConfig(path_template="/v1/messages", method="POST"),
        mapping=MappingConfig(request={"style": "anthropic_messages"}, response={"text_paths": ["content[].text"]}),
        limits=ProviderLimits(),
    )
    url, headers = _build_url_and_headers(cfg, "secret", "claude-haiku-4-5-20251001")
    assert url == "https://api.vectorengine.ai/v1/messages"
    assert headers["x-api-key"] == "secret"
