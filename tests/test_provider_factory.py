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
