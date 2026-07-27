from transvortex.protocol.errors import classify_exception
from transvortex.openrouter import OpenRouterTransportError


def test_classify_ffmpeg_failure_as_media_processing_error() -> None:
    info = classify_exception(
        RuntimeError(
            "Command '['ffmpeg', '-i', 'demo.mp3']' returned non-zero exit status 4294967274."
        ),
        stage="PRECHECK",
    )

    assert info["code"] == "media_processing_failed"
    assert "音频处理失败" in info["hint_zh"]
    assert "stderr" not in info["hint_zh"]


def test_runtime_error_hint_is_user_facing() -> None:
    info = classify_exception(RuntimeError("unknown failure"), stage="TRANSLATE")

    assert info["code"] == "runtime_error"
    assert "events.json" not in info["hint_zh"]
    assert "stderr" not in info["hint_zh"]


def test_classify_openrouter_missing_timestamps_as_asr_configuration_error() -> None:
    info = classify_exception(
        RuntimeError(
            "openrouter_asr_timestamps_missing: openai/whisper-large-v3"
        ),
        stage="ASR",
    )

    assert info["code"] == "openrouter_asr_timestamps_missing"
    assert info["retryable"] is False
    assert "时间轴" in info["hint_zh"]


def test_classify_openrouter_payment_error_with_safe_request_details() -> None:
    info = classify_exception(
        OpenRouterTransportError(
            "payment_required",
            "openrouter_payment_required: insufficient credits",
            status_code=402,
            openrouter_error_type="payment_required",
            provider_code="insufficient_credits",
            generation_id="gen_failed",
        ),
        stage="ASR",
    )

    assert info["code"] == "provider_payment_required"
    assert info["retryable"] is False
    assert "余额" in info["hint_zh"]
    assert info["details"] == {
        "status_code": 402,
        "openrouter_error_type": "payment_required",
        "provider_code": "insufficient_credits",
        "generation_id": "gen_failed",
    }


def test_classify_openrouter_rate_limit_as_retryable_provider_error() -> None:
    info = classify_exception(
        OpenRouterTransportError(
            "rate_limit",
            "openrouter_rate_limit_exceeded: retry later",
            status_code=429,
            openrouter_error_type="rate_limit_exceeded",
            retry_after_seconds=7,
        ),
        stage="ASR",
    )

    assert info["code"] == "provider_rate_limit"
    assert info["retryable"] is True
    assert info["details"]["retry_after_seconds"] == 7
