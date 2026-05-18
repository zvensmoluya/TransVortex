from __future__ import annotations

import json
import socket
from types import SimpleNamespace
from urllib.error import URLError

from transvortex.app.models import AsrProviderConfig
from transvortex.core.asr import (
    AsrEngine,
    OpenAITranscriptionsAsrClient,
    _build_cloud_asr_url,
    _normalize_whisper_language,
    _prepare_local_cuda_runtime,
)


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
        captured["url"] = req.full_url
        captured["headers"] = dict(req.header_items())
        captured["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            base_url="https://api.example.com/v1",
            endpoint="/v1/audio/transcriptions",
            timeout_seconds=12,
        )
    )

    assert client._call_openai_transcriptions(audio, api_key="secret") == {"text": "ok"}

    assert captured["url"] == "https://api.example.com/v1/audio/transcriptions"
    assert captured["headers"]["Accept"] == "application/json"
    assert captured["headers"]["User-agent"] == "TransVortex/0.1.0"
    assert captured["headers"]["Content-type"].startswith("multipart/form-data; boundary=")
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["timeout"] == 12


def test_cloud_asr_request_sends_configured_form_fields(tmp_path, monkeypatch) -> None:
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
        captured["body"] = req.data.decode("utf-8", errors="replace")
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
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
    body = captured["body"]
    assert 'name="model"' in body
    assert "whisper-1" in body
    assert 'name="response_format"' in body
    assert "verbose_json" in body
    assert 'name="temperature"' in body
    assert "0.25" in body
    assert body.count('name="timestamp_granularities[]"') == 2
    assert body.count('name="include[]"') == 1
    assert 'name="language"' in body
    assert "\r\nja\r\n" in body
    assert "Names: Subaru, Emilia" in body
    assert 'name="custom_flag"' in body
    assert "\r\ntrue\r\n" in body
    assert body.count('name="custom_list"') == 2


def test_cloud_asr_request_can_send_array_fields_as_repeated_plain_names(tmp_path, monkeypatch) -> None:
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
        captured["body"] = req.data.decode("utf-8", errors="replace")
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
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
    body = captured["body"]
    assert body.count('name="timestamp_granularities"') == 2
    assert 'name="timestamp_granularities[]"' not in body
    assert body.count('name="include"') == 1
    assert 'name="include[]"' not in body


def test_cloud_asr_retries_retryable_request_errors(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return json.dumps({"text": "ok"}).encode("utf-8")

    def fake_urlopen(req, timeout):
        attempts["count"] += 1
        if attempts["count"] == 1:
            raise TimeoutError("The read operation timed out")
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    monkeypatch.setattr("transvortex.core.asr.time.sleep", lambda _seconds: None)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            timeout_seconds=12,
            retry=2,
        )
    )

    assert client._call_openai_transcriptions(audio, api_key="secret") == {"text": "ok"}
    assert attempts["count"] == 2


def test_cloud_asr_does_not_retry_non_retryable_request_errors(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    def fake_urlopen(req, timeout):
        attempts["count"] += 1
        raise ValueError("bad request body")

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    client = OpenAITranscriptionsAsrClient(
        AsrProviderConfig(
            name="openai",
            timeout_seconds=12,
            retry=3,
        )
    )

    try:
        client._call_openai_transcriptions(audio, api_key="secret")
    except ValueError as exc:
        assert "bad request body" in str(exc)
    else:
        raise AssertionError("expected non-retryable request error")
    assert attempts["count"] == 1


def test_cloud_asr_retries_url_timeout_reason(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return json.dumps({"text": "ok"}).encode("utf-8")

    def fake_urlopen(req, timeout):
        attempts["count"] += 1
        if attempts["count"] == 1:
            raise socket.timeout("timed out")
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    monkeypatch.setattr("transvortex.core.asr.time.sleep", lambda _seconds: None)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai", retry=2))

    assert client._call_openai_transcriptions(audio, api_key="secret") == {"text": "ok"}
    assert attempts["count"] == 2


def test_cloud_asr_retries_ssl_eof_upload_failure(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    attempts = {"count": 0}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return json.dumps({"text": "ok"}).encode("utf-8")

    def fake_urlopen(req, timeout):
        attempts["count"] += 1
        if attempts["count"] == 1:
            raise URLError("[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol")
        return FakeResponse()

    monkeypatch.setattr("transvortex.core.asr.urllib.request.urlopen", fake_urlopen)
    monkeypatch.setattr("transvortex.core.asr.time.sleep", lambda _seconds: None)
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai", retry=2))

    assert client._call_openai_transcriptions(audio, api_key="secret") == {"text": "ok"}
    assert attempts["count"] == 2


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


def test_openai_transcriptions_maps_segments_and_fallback(tmp_path, monkeypatch) -> None:
    audio = tmp_path / "sample.wav"
    audio.write_bytes(b"RIFF")
    client = OpenAITranscriptionsAsrClient(AsrProviderConfig(name="openai"))

    monkeypatch.setattr(
        client,
        "_call_openai_transcriptions",
        lambda _audio, *, api_key, source_lang=None, prompt="": {
            "segments": [{"start": 0.2, "end": 1.8, "text": "Hello", "avg_logprob": -0.2}]
        },
    )
    monkeypatch.setattr(
        "transvortex.core.asr.resolve_credential",
        lambda **_kwargs: SimpleNamespace(found=True, key="secret", credential_id="openai", env_key="KEY"),
    )
    rows = client.transcribe_segment(audio, 10.0, source_lang="en").rows
    assert rows == [
        {
            "start": 10.2,
            "end": 11.8,
            "text": "Hello",
            "confidence": -0.2,
            "meta": {"provider": "openai", "protocol": "openai_transcriptions", "source": "asr"},
        }
    ]

    monkeypatch.setattr(
        client,
        "_call_openai_transcriptions",
        lambda _audio, *, api_key, source_lang=None, prompt="": {"text": "Whole file"},
    )
    fallback = client.transcribe_segment(audio, 5.0).rows
    assert fallback[0]["meta"]["warning"] == "missing_timestamps"
    assert fallback[0]["start"] == 5.0
    assert fallback[0]["end"] == 5.1


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
    )
    engine._model = FakeModel()

    rows = engine.transcribe_segment(audio, 10.0)

    assert captured["path"] == str(audio)
    assert captured["kwargs"] == {
        "vad_filter": False,
        "language": "ja",
        "max_initial_timestamp": 30.0,
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
