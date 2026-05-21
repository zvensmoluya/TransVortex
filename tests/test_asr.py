from __future__ import annotations

from types import SimpleNamespace

import httpx

from transvortex.app.models import AsrProviderConfig
from transvortex.core.asr import (
    AsrEngine,
    OpenAITranscriptionsAsrClient,
    _build_cloud_asr_url,
    _normalize_whisper_language,
    _prepare_local_cuda_runtime,
)
from transvortex.http import HttpTransportError


def test_normalize_whisper_language() -> None:
    assert _normalize_whisper_language("ja") == "ja"
    assert _normalize_whisper_language("zh-CN") == "zh"
    assert _normalize_whisper_language("EN-us") == "en"
    assert _normalize_whisper_language("") is None


def test_build_cloud_asr_url_dedupes_version_path() -> None:
    assert (
        _build_cloud_asr_url("https://api.example.com/v1", "/v1/audio/transcriptions")
        == "https://api.example.com/v1/audio/transcriptions"
    )
    assert (
        _build_cloud_asr_url("https://api.example.com", "/v1/audio/transcriptions")
        == "https://api.example.com/v1/audio/transcriptions"
    )
    assert (
        _build_cloud_asr_url("https://api.example.com/v1/", "audio/transcriptions")
        == "https://api.example.com/v1/audio/transcriptions"
    )


def test_cloud_asr_request_uses_product_headers_and_http2(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    captured = {}

    def fake_request_json_with_retry(method, url, **kwargs):
        captured["method"] = method
        captured["url"] = url
        captured.update(kwargs)
        return {"text": "ok"}, {
            "transport": "httpx",
            "http_version": "HTTP/2",
            "http2_requested": kwargs["http2"],
            "http2_enabled": True,
            "streaming": False,
            "attempts": 1,
        }

    monkeypatch.setattr("transvortex.core.asr.request_json_with_retry", fake_request_json_with_retry)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            base_url="https://api.example.com/v1",
            endpoint="/v1/audio/transcriptions",
            timeout_seconds=12,
            http2=True,
        )
    )

    payload, meta = client._call_openai_transcriptions(audio, api_key="secret")

    assert payload == {"text": "ok"}
    assert meta["transport"] == "httpx"
    assert captured["method"] == "POST"
    assert captured["url"] == "https://api.example.com/v1/audio/transcriptions"
    assert captured["headers"]["Accept"] == "application/json"
    assert captured["headers"]["User-Agent"] == "TransVortex/0.1.0"
    assert "Content-Type" not in captured["headers"]
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["timeout"] == 12.0
    assert captured["http2"] is True
    assert captured["retry"] == 2


def test_cloud_asr_request_sends_configured_form_fields(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    captured = {}

    def fake_request_json_with_retry(method, url, **kwargs):
        captured.update(kwargs)
        return {"text": "ok"}, {"transport": "httpx"}

    monkeypatch.setattr("transvortex.core.asr.request_json_with_retry", fake_request_json_with_retry)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            model="whisper-1",
            request=SimpleNamespace(
                response_format="verbose_json",
                temperature=0.25,
                timestamp_granularities=["segment", "word"],
                include=["logprobs"],
                extra_form_fields={"custom_flag": True, "custom_list": ["a", "b"]},
                array_format="brackets",
            ),
        )
    )

    client._call_openai_transcriptions(
        audio,
        api_key="secret",
        source_lang="ja-JP",
        prompt="Names: Subaru, Emilia",
    )
    data = captured["data"]
    assert data["model"] == "whisper-1"
    assert data["response_format"] == "verbose_json"
    assert data["temperature"] == "0.25"
    assert data["timestamp_granularities[]"] == ["segment", "word"]
    assert data["include[]"] == "logprobs"
    assert data["language"] == "ja"
    assert data["prompt"] == "Names: Subaru, Emilia"
    assert data["custom_flag"] == "true"
    assert data["custom_list"] == ["a", "b"]
    assert captured["files"] == [("file", ("sample.wav", b"RIFF", "audio/wav"))]


def test_cloud_asr_request_can_send_array_fields_as_repeated_plain_names(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    captured = {}

    def fake_request_json_with_retry(method, url, **kwargs):
        captured.update(kwargs)
        return {"text": "ok"}, {"transport": "httpx"}

    monkeypatch.setattr("transvortex.core.asr.request_json_with_retry", fake_request_json_with_retry)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            request=SimpleNamespace(
                response_format="verbose_json",
                temperature=0,
                timestamp_granularities=["segment", "word"],
                include=["logprobs"],
                extra_form_fields={},
                array_format="repeat",
            ),
        )
    )

    client._call_openai_transcriptions(audio, api_key="secret")
    data = captured["data"]
    assert data["timestamp_granularities"] == ["segment", "word"]
    assert "timestamp_granularities[]" not in data
    assert data["include"] == "logprobs"
    assert "include[]" not in data


def test_cloud_asr_retries_retryable_request_errors(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        attempts["count"] += 1
        if attempts["count"] == 1:
            raise httpx.ReadTimeout("The read operation timed out", request=request)
        return httpx.Response(200, json={"text": "ok"}, request=request)

    transport = httpx.MockTransport(handler)

    def fake_build_httpx_client(**kwargs):
        return httpx.Client(transport=transport, timeout=kwargs["timeout"], http2=kwargs["http2"])

    monkeypatch.setattr("transvortex.http.build_httpx_client", fake_build_httpx_client)
    monkeypatch.setattr("transvortex.http.time.sleep", lambda _seconds: None)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai", timeout_seconds=12, retry=2))

    payload, meta = client._call_openai_transcriptions(audio, api_key="secret")

    assert payload == {"text": "ok"}
    assert attempts["count"] == 2
    assert meta["attempts"] == 2


def test_cloud_asr_does_not_retry_non_retryable_request_errors(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    def fake_request_json_with_retry(method, url, **kwargs):
        attempts["count"] += 1
        raise ValueError("bad request body")

    monkeypatch.setattr("transvortex.core.asr.request_json_with_retry", fake_request_json_with_retry)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai", timeout_seconds=12, retry=3))

    try:
        client._call_openai_transcriptions(audio, api_key="secret")
    except ValueError as exc:
        assert "bad request body" in str(exc)
    else:
        raise AssertionError("expected non-retryable request error")
    assert attempts["count"] == 1


def test_cloud_asr_retries_remote_protocol_upload_failure(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        attempts["count"] += 1
        if attempts["count"] == 1:
            raise httpx.RemoteProtocolError("remote end closed connection", request=request)
        return httpx.Response(200, json={"text": "ok"}, request=request)

    transport = httpx.MockTransport(handler)

    def fake_build_httpx_client(**kwargs):
        return httpx.Client(transport=transport, timeout=kwargs["timeout"], http2=kwargs["http2"])

    monkeypatch.setattr("transvortex.http.build_httpx_client", fake_build_httpx_client)
    monkeypatch.setattr("transvortex.http.time.sleep", lambda _seconds: None)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai", retry=2))

    payload, meta = client._call_openai_transcriptions(audio, api_key="secret")

    assert payload == {"text": "ok"}
    assert attempts["count"] == 2
    assert meta["attempts"] == 2


def test_cloud_asr_raises_bad_schema_for_non_object_response(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")

    def fake_request_json_with_retry(method, url, **kwargs):
        return ["not", "object"], {"transport": "httpx"}

    monkeypatch.setattr("transvortex.core.asr.request_json_with_retry", fake_request_json_with_retry)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai"))

    try:
        client._call_openai_transcriptions(audio, api_key="secret")
    except RuntimeError as exc:
        assert "bad_schema" in str(exc)
    else:
        raise AssertionError("expected bad schema error")


def test_cloud_asr_rejects_unsupported_response_format_and_reserved_extra_field(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(
        "transvortex.core.asr.resolve_credential",
        lambda **_kwargs: SimpleNamespace(found=True, key="secret", credential_id="openai", env_key="KEY"),
    )
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            request=SimpleNamespace(
                response_format="json",
                temperature=0,
                timestamp_granularities=[],
                include=[],
                extra_form_fields={},
                array_format="repeat",
            ),
        )
    )
    try:
        client.transcribe_segment(audio, 0.0)
    except RuntimeError as exc:
        assert "unsupported_asr_response_format_for_segments" in str(exc)
    else:
        raise AssertionError("expected unsupported response format")

    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            request=SimpleNamespace(
                response_format="verbose_json",
                temperature=0,
                timestamp_granularities=[],
                include=[],
                extra_form_fields={"model": "override"},
                array_format="repeat",
            ),
        )
    )
    try:
        client.transcribe_segment(audio, 0.0)
    except RuntimeError as exc:
        assert "reserved_asr_form_field: model" in str(exc)
    else:
        raise AssertionError("expected reserved field error")


def test_openai_transcriptions_maps_segments_and_fallback_with_transport_meta(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai"))
    transport_meta = {
        "transport": "httpx",
        "http_version": "HTTP/2",
        "http2_requested": True,
        "http2_enabled": True,
    }

    monkeypatch.setattr(
        client,
        "_call_openai_transcriptions",
        lambda _audio, *, api_key, source_lang=None, prompt="": (
            {"segments": [{"start": 0.2, "end": 1.8, "text": "Hello", "avg_logprob": -0.2}]},
            transport_meta,
        ),
    )
    monkeypatch.setattr(
        "transvortex.core.asr.resolve_credential",
        lambda **_kwargs: SimpleNamespace(found=True, key="secret", credential_id="openai", env_key="KEY"),
    )
    result = client.transcribe_segment(audio, 10.0, source_lang="en")
    rows = result.rows
    assert result.transport_meta == transport_meta
    assert rows == [
        {
            "start": 10.2,
            "end": 11.8,
            "text": "Hello",
            "confidence": -0.2,
            "meta": {
                "provider": "openai",
                "protocol": "openai_transcriptions",
                "source": "asr",
                "transport": "httpx",
                "http_version": "HTTP/2",
                "http2_requested": True,
                "http2_enabled": True,
            },
        }
    ]

    monkeypatch.setattr(
        client,
        "_call_openai_transcriptions",
        lambda _audio, *, api_key, source_lang=None, prompt="": ({"text": "Whole file"}, transport_meta),
    )
    fallback = client.transcribe_segment(audio, 5.0)
    assert fallback.transport_meta == transport_meta
    assert fallback.rows[0]["meta"]["warning"] == "missing_timestamps"
    assert fallback.rows[0]["meta"]["transport"] == "httpx"
    assert fallback.rows[0]["start"] == 5.0
    assert fallback.rows[0]["end"] == 5.1


def test_cloud_asr_transcribe_propagates_transport_error(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai"))

    monkeypatch.setattr(
        "transvortex.core.asr.resolve_credential",
        lambda **_kwargs: SimpleNamespace(found=True, key="secret", credential_id="openai", env_key="KEY"),
    )
    monkeypatch.setattr(
        client,
        "_call_openai_transcriptions",
        lambda _audio, *, api_key, source_lang=None, prompt="": (_ for _ in ()).throw(
            HttpTransportError("gateway_timeout", "cloud ASR upstream returned HTTP 504", status_code=504)
        ),
    )

    try:
        client.transcribe_segment(audio, 0.0)
    except HttpTransportError as exc:
        assert exc.error_type == "gateway_timeout"
        assert exc.status_code == 504
    else:
        raise AssertionError("expected transport error")


def test_local_asr_uses_selected_language_and_initial_timestamp(tmp_path) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    captured = {}

    class FakeModel:
        def transcribe(self, path, **kwargs):
            captured["path"] = path
            captured["kwargs"] = kwargs
            return [SimpleNamespace(start=3.2, end=4.4, text="やったわ", avg_logprob=-0.1)], object()

    engine = AsrEngine(
        model_size="small",
        device="cpu",
        compute_type="int8",
        mode="local",
        source_lang="ja-JP",
        local_max_initial_timestamp=30.0,
        local_beam_size=7,
        local_temperature=0.2,
        local_condition_on_previous_text=False,
        local_hotwords="Subaru, Emilia",
        prompt="Names: Subaru, Emilia",
    )
    engine._model = FakeModel()

    rows = engine.transcribe_segment(audio, 10.0)

    assert captured["path"] == str(audio)
    assert captured["kwargs"] == {
        "vad_filter": False,
        "beam_size": 7,
        "temperature": 0.2,
        "condition_on_previous_text": False,
        "language": "ja",
        "max_initial_timestamp": 30.0,
        "initial_prompt": "Names: Subaru, Emilia",
        "hotwords": "Subaru, Emilia",
    }
    assert rows == [
        {
            "start": 13.2,
            "end": 14.4,
            "text": "やったわ",
            "confidence": -0.1,
            "meta": {"source": "asr", "provider": "local", "protocol": "faster_whisper"},
        }
    ]


def test_prepare_local_cuda_runtime_registers_nvidia_wheel_dirs(tmp_path, monkeypatch) -> None:
    package_root = tmp_path / "nvidia"
    expected = []
    for relative in (
        ("cuda_runtime", "bin"),
        ("cuda_nvrtc", "bin"),
        ("cublas", "bin"),
        ("cudnn", "bin"),
    ):
        path = package_root.joinpath(*relative)
        path.mkdir(parents=True)
        expected.append(path)

    added = []
    monkeypatch.setattr("transvortex.core.asr.os.name", "nt")
    monkeypatch.setattr("transvortex.core.asr._CUDA_DLL_DIRECTORIES_REGISTERED", False)
    monkeypatch.setattr("transvortex.core.asr._CUDA_DLL_DIRECTORY_PATHS", set())
    monkeypatch.setattr("transvortex.core.asr._CUDA_DLL_DIRECTORY_HANDLES", [])
    monkeypatch.setattr("transvortex.core.asr._candidate_nvidia_package_roots", lambda: [package_root])
    monkeypatch.setattr("transvortex.core.asr._add_dll_directory", lambda path: added.append(path))

    _prepare_local_cuda_runtime("cuda")

    assert added == expected


def test_prepare_local_cuda_runtime_skips_cpu(monkeypatch) -> None:
    monkeypatch.setattr("transvortex.core.asr.os.name", "nt")
    monkeypatch.setattr("transvortex.core.asr._CUDA_DLL_DIRECTORIES_REGISTERED", False)
    monkeypatch.setattr(
        "transvortex.core.asr._candidate_nvidia_package_roots",
        lambda: (_ for _ in ()).throw(AssertionError("should not inspect CUDA roots")),
    )

    _prepare_local_cuda_runtime("cpu")
