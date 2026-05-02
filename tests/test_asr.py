from __future__ import annotations

from transvortex.asr import _build_url_and_auth_headers, _normalize_whisper_language
from transvortex.models import AuthConfig, CapabilityConfig, EndpointConfig, MappingConfig, ProviderConfig, ProviderLimits


def test_normalize_whisper_language() -> None:
    assert _normalize_whisper_language("ja") == "ja"
    assert _normalize_whisper_language("zh-CN") == "zh"
    assert _normalize_whisper_language("EN-us") == "en"
    assert _normalize_whisper_language("") is None


def test_build_url_and_auth_headers_query_auth() -> None:
    provider = ProviderConfig(
        name="asr",
        api_type="openai-compatible",
        base_url="https://api.example.com/v1",
        env_key="ASR_KEY",
        models=["whisper-1"],
        compat_mode="openai_chat",
        auth=AuthConfig(type="query", query_name="key", prefix=""),
        endpoint=EndpointConfig(path_template="/v1/audio/transcriptions", method="POST"),
        mapping=MappingConfig(),
        capabilities=CapabilityConfig(),
        limits=ProviderLimits(),
    )
    url, headers = _build_url_and_auth_headers(provider, "abc123", model="whisper-1")
    assert headers == {}
    assert url == "https://api.example.com/v1/audio/transcriptions?key=abc123"
