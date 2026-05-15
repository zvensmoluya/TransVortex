from __future__ import annotations

import json

from transvortex.core.asr import AsrEngine, _build_url_and_auth_headers, _normalize_whisper_language
from transvortex.app.models import AuthConfig, CapabilityConfig, EndpointConfig, MappingConfig, ProviderConfig, ProviderLimits


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


def test_cloud_asr_request_uses_product_headers(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    captured = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return json.dumps({"text": "ok"}).encode("utf-8")

    def fake_urlopen(req, timeout):
        captured["headers"] = dict(req.header_items())
        captured["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    engine = AsrEngine(
        model_size="small",
        device="cpu",
        compute_type="int8",
        mode="cloud",
        cloud_timeout_seconds=12,
    )

    assert engine._call_openai_transcriptions(audio, api_key="secret") == {"text": "ok"}

    assert captured["headers"]["Accept"] == "application/json"
    assert captured["headers"]["User-agent"] == "TransVortex/0.1.0"
    assert captured["headers"]["Content-type"].startswith("multipart/form-data; boundary=")
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["timeout"] == 12
