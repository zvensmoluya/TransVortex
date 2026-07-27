from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


OPENROUTER_ASR_BASE_URL = "https://openrouter.ai/api/v1"
OPENROUTER_ASR_ENDPOINT = "/audio/transcriptions"
OPENROUTER_ASR_ENV_KEY = "OPENROUTER_API_KEY"
OPENROUTER_ASR_CREDENTIAL_ID = "openrouter_asr"
OPENROUTER_ASR_DEFAULT_MODEL = "openai/whisper-large-v3"


@dataclass(frozen=True)
class OpenRouterAsrModelProfile:
    model: str
    display_name: str
    status: str
    timeline_mode: str
    response_format: str
    timestamp_granularities: tuple[str, ...]
    prompt_mode: str
    max_window_seconds: float
    min_window_seconds: float
    overlap_seconds: float
    fuzzy_dedupe: bool
    notes_zh: str
    native_capabilities: tuple[str, ...] = ()
    exposed_capabilities: tuple[str, ...] = ("text", "usage")
    allowed_extra_json_fields: tuple[str, ...] = ()
    allowed_provider_options: tuple[str, ...] = ()

    def to_payload(self) -> dict[str, Any]:
        payload = asdict(self)
        for key in (
            "timestamp_granularities",
            "native_capabilities",
            "exposed_capabilities",
            "allowed_extra_json_fields",
            "allowed_provider_options",
        ):
            payload[key] = list(payload[key])
        return payload


_OPENROUTER_ASR_MODEL_PROFILES = (
    OpenRouterAsrModelProfile(
        model="openai/whisper-large-v3",
        display_name="Whisper Large V3",
        status="candidate",
        timeline_mode="segments_required",
        response_format="verbose_json",
        timestamp_granularities=("segment",),
        prompt_mode="groq_provider_option",
        max_window_seconds=60.0,
        min_window_seconds=8.0,
        overlap_seconds=3.0,
        fuzzy_dedupe=True,
        notes_zh="请求分段时间戳；真实任务若只返回整段文本会明确失败，不静默生成粗时间轴。",
        native_capabilities=("multilingual", "segment_timestamps"),
        exposed_capabilities=("text", "usage", "segment_timestamps"),
        allowed_provider_options=("groq.prompt",),
    ),
    OpenRouterAsrModelProfile(
        model="x-ai/grok-stt-1.0",
        display_name="Grok STT 1.0",
        status="experimental",
        timeline_mode="chunk",
        response_format="json",
        timestamp_granularities=(),
        prompt_mode="unsupported",
        max_window_seconds=20.0,
        min_window_seconds=5.0,
        overlap_seconds=0.0,
        fuzzy_dedupe=False,
        notes_zh="OpenRouter 当前只保证整段文本结构；先按短音频窗口生成粗时间轴，等待真实响应验证单词时间戳。",
        native_capabilities=("word_timestamps", "speaker_diarization", "multichannel"),
        exposed_capabilities=("text", "usage"),
    ),
)

_OPENROUTER_ASR_PROFILE_BY_MODEL = {
    profile.model: profile for profile in _OPENROUTER_ASR_MODEL_PROFILES
}


def openrouter_asr_model_profile(model: str) -> OpenRouterAsrModelProfile | None:
    return _OPENROUTER_ASR_PROFILE_BY_MODEL.get(str(model or "").strip())


def require_openrouter_asr_model_profile(model: str) -> OpenRouterAsrModelProfile:
    profile = openrouter_asr_model_profile(model)
    if profile is None:
        raise ValueError(f"Unsupported OpenRouter ASR model: {model}")
    return profile


def openrouter_asr_model_profiles_payload() -> list[dict[str, Any]]:
    return [profile.to_payload() for profile in _OPENROUTER_ASR_MODEL_PROFILES]


def openrouter_asr_admin_defaults(model: str) -> dict[str, Any]:
    profile = require_openrouter_asr_model_profile(model)
    return {
        "execution": {
            "concurrency": 4,
            "adaptive_concurrency": True,
            "min_concurrency": 1,
            "max_concurrency": 4,
            "max_inflight_upload_mb": 64,
            "timeout_seconds": 120,
            "retry": 2,
        },
        "chunking": {
            "mode": "silence",
            "window_seconds": profile.max_window_seconds,
            "max_window_seconds": profile.max_window_seconds,
            "min_window_seconds": profile.min_window_seconds,
            "overlap_seconds": profile.overlap_seconds,
            "short_audio_seconds": profile.max_window_seconds,
            "max_upload_mb": 24,
            "silence": {
                "noise_db": -35,
                "min_silence_seconds": 0.25,
                "cut_padding_seconds": 0.15,
                "fallback_mode": "hard_cut",
            },
            "fuzzy_dedupe": profile.fuzzy_dedupe,
        },
        "preprocessing": {
            "trim_silence": {
                "enabled": True,
                "backend": "ffmpeg_silencedetect",
                "noise_db": -35,
                "min_silence_seconds": 0.2,
                "keep_preroll_seconds": 0.25,
                "trim_trailing": True,
                "keep_postroll_seconds": 0.1,
                "min_upload_seconds": 0.5,
            }
        },
        "request": {
            "response_format": profile.response_format,
            "temperature": 0,
            "timestamp_granularities": list(profile.timestamp_granularities),
            "include": [],
            "extra_form_fields": {},
            "extra_json_fields": {},
            "provider_options": {},
            "array_format": "repeat",
            "send_response_format": True,
            "send_temperature": True,
            "send_timestamp_granularities": bool(profile.timestamp_granularities),
            "send_language": True,
            "send_prompt": profile.prompt_mode != "unsupported",
            "language_field": "language",
            "prompt_field": "prompt",
        },
    }
