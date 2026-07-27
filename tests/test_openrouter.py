from __future__ import annotations

import httpx
import pytest

from transvortex.http import HttpTransportError
from transvortex.openrouter import (
    OpenRouterTransportError,
    fetch_openrouter_current_key_usage,
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


def test_openrouter_current_key_usage_returns_only_stable_safe_fields() -> None:
    captured: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["method"] = request.method
        captured["url"] = str(request.url)
        captured["authorization"] = request.headers["Authorization"]
        return httpx.Response(
            200,
            json={
                "data": {
                    "usage": 25.5,
                    "usage_daily": 1,
                    "usage_weekly": 7.25,
                    "usage_monthly": 20.75,
                    "byok_usage": 17.38,
                    "byok_usage_daily": 0.5,
                    "byok_usage_weekly": 3,
                    "byok_usage_monthly": 12.0,
                    "limit": 100,
                    "limit_remaining": 74.5,
                    "limit_reset": "monthly",
                    "is_free_tier": False,
                    "expires_at": "2027-12-31T23:59:59Z",
                    "label": "example-key-label",
                    "creator_user_id": "user_private",
                    "is_management_key": False,
                    "key": "example-key-material",
                }
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        result = fetch_openrouter_current_key_usage(
            "example-token",
            retry=2,
            client=client,
        )

    assert captured == {
        "method": "GET",
        "url": "https://openrouter.ai/api/v1/key",
        "authorization": "Bearer example-token",
    }
    assert result == {
        "currency": "USD",
        "usage_usd": 25.5,
        "usage_daily_usd": 1.0,
        "usage_weekly_usd": 7.25,
        "usage_monthly_usd": 20.75,
        "byok_usage_usd": 17.38,
        "byok_usage_daily_usd": 0.5,
        "byok_usage_weekly_usd": 3.0,
        "byok_usage_monthly_usd": 12.0,
        "limit_usd": 100.0,
        "limit_remaining_usd": 74.5,
        "limit_reset": "monthly",
        "is_free_tier": False,
        "expires_at": "2027-12-31T23:59:59Z",
    }
    assert "example-key-label" not in repr(result)
    assert "example-key-material" not in repr(result)


def test_openrouter_current_key_usage_rejects_unexpected_envelope() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"data": []})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(
            HttpTransportError,
            match="bad_schema: unexpected OpenRouter current key response",
        ) as excinfo:
            fetch_openrouter_current_key_usage("example-token", client=client)

    assert excinfo.value.error_type == "bad_schema"


def test_openrouter_current_key_usage_forwards_transport_options(monkeypatch) -> None:
    network = object()
    captured: dict[str, object] = {}

    def fake_request(method, url, **kwargs):  # noqa: ANN001, ANN003
        captured.update(method=method, url=url, **kwargs)
        return {"data": {"usage": 0}}, {"attempts": 1}

    monkeypatch.setattr(
        "transvortex.openrouter.request_openrouter_json_with_retry",
        fake_request,
    )

    result = fetch_openrouter_current_key_usage(
        "example-token",
        timeout=12.5,
        http2=False,
        retry=3,
        network=network,
    )

    assert result["usage_usd"] == 0.0
    assert captured["method"] == "GET"
    assert captured["url"] == "https://openrouter.ai/api/v1/key"
    assert captured["timeout"] == 12.5
    assert captured["http2"] is False
    assert captured["retry"] == 3
    assert captured["network"] is network
