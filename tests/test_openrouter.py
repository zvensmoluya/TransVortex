from __future__ import annotations

import httpx
import pytest

from transvortex.openrouter import (
    OpenRouterTransportError,
    request_openrouter_json_with_retry,
)


def test_openrouter_maps_typed_payment_error_and_safe_diagnostics() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            402,
            headers={"X-Generation-Id": "gen_failed"},
            json={
                "error": {
                    "code": 402,
                    "message": "Insufficient credits",
                    "metadata": {
                        "error_type": "payment_required",
                        "provider_code": "insufficient_credits",
                    },
                }
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(OpenRouterTransportError) as excinfo:
            request_openrouter_json_with_retry(
                "POST",
                "https://openrouter.ai/api/v1/audio/transcriptions",
                json_payload={"model": "openai/whisper-large-v3"},
                headers={"Authorization": "Bearer example-token"},
                retry=2,
                client=client,
                context="OpenRouter STT upstream",
            )

    error = excinfo.value
    assert error.error_type == "payment_required"
    assert error.openrouter_error_type == "payment_required"
    assert error.status_code == 402
    assert error.provider_code == "insufficient_credits"
    assert error.generation_id == "gen_failed"
    assert "openrouter_payment_required" in str(error)
    assert "example-token" not in str(error)


def test_openrouter_honors_retry_after_for_retryable_status(monkeypatch) -> None:
    attempts = 0
    delays: list[float] = []

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return httpx.Response(
                503,
                headers={"Retry-After": "3"},
                json={
                    "error": {
                        "code": 503,
                        "message": "Provider overloaded",
                        "metadata": {"error_type": "provider_overloaded"},
                    }
                },
            )
        return httpx.Response(
            200,
            headers={"X-Generation-Id": "gen_success"},
            json={"text": "ok", "usage": {"seconds": 0.25, "cost": 0.0}},
        )

    monkeypatch.setattr("transvortex.http.time.sleep", delays.append)
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        payload, meta = request_openrouter_json_with_retry(
            "POST",
            "https://openrouter.ai/api/v1/audio/transcriptions",
            json_payload={"model": "x-ai/grok-stt-1.0"},
            retry=2,
            client=client,
        )

    assert payload["text"] == "ok"
    assert attempts == 2
    assert delays == [3.0]
    assert meta["attempts"] == 2
    assert meta["generation_id"] == "gen_success"


def test_openrouter_retries_typed_error_returned_in_success_envelope(monkeypatch) -> None:
    attempts = 0
    delays: list[float] = []

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return httpx.Response(
                200,
                headers={"Retry-After": "2"},
                json={
                    "error": {
                        "code": "rate_limit_exceeded",
                        "message": "Rate limited",
                    }
                },
            )
        return httpx.Response(200, json={"text": "ok"})

    monkeypatch.setattr("transvortex.http.time.sleep", delays.append)
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        payload, meta = request_openrouter_json_with_retry(
            "POST",
            "https://openrouter.ai/api/v1/audio/transcriptions",
            json_payload={"model": "openai/whisper-large-v3"},
            retry=2,
            client=client,
        )

    assert payload == {"text": "ok"}
    assert attempts == 2
    assert delays == [2.0]
    assert meta["attempts"] == 2
