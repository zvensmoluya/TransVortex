from __future__ import annotations

import tempfile
import wave
from pathlib import Path
from typing import Any

from ..core.asr import AsrEngine
from .asr_runtime import record_provider_test
from .models import AsrProviderConfig


_SAFE_TRANSPORT_KEYS = {
    "transport",
    "http_version",
    "http2_requested",
    "http2_enabled",
    "streaming",
    "attempts",
    "generation_id",
    "service",
    "openrouter_model",
    "timeline_mode",
    "model_status",
    "runtime_source",
    "runtime_id",
    "device",
    "compute_type",
}


def _safe_transport_meta(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return {}
    return {key: raw[key] for key in sorted(_SAFE_TRANSPORT_KEYS) if key in raw}


def run_asr_connection_test(
    provider: AsrProviderConfig,
    *,
    root_dir: Path,
    source_lang: str = "en",
) -> dict[str, Any]:
    engine: AsrEngine | None = None
    try:
        with tempfile.TemporaryDirectory(prefix="transvortex-asr-test-") as raw_dir:
            audio_path = Path(raw_dir) / "probe.wav"
            _write_probe_audio(audio_path)
            engine = AsrEngine(
                asr_provider=provider,
                source_lang=source_lang,
                root_dir=root_dir,
            )
            result = engine.transcribe_segment_result(audio_path, 0.0)
        details = {
            "provider": provider.name,
            "protocol": provider.protocol,
            "model": provider.model,
            "row_count": len(result.rows),
            "transport": _safe_transport_meta(result.transport_meta),
        }
        ok = True
        code = "ready"
    except Exception as exc:  # noqa: BLE001 - provider tests return a structured diagnostic
        details = {
            "provider": provider.name,
            "protocol": provider.protocol,
            "model": provider.model,
            "error_type": type(exc).__name__,
        }
        ok = False
        code = _test_error_code(exc)
    finally:
        if engine is not None:
            try:
                engine.close()
            except Exception:  # noqa: BLE001 - closing must not replace the probe result
                pass
    try:
        saved = record_provider_test(
            provider,
            root_dir=root_dir,
            ok=ok,
            code=code,
            details=details,
        )
    except Exception:  # noqa: BLE001 - state write failure is a stable, secret-free error
        return {
            "ok": False,
            "code": "probe_state_write_failed",
            "checked_at": "",
            "provider": provider.name,
            "protocol": provider.protocol,
        }
    return {
        "ok": saved.get("ok") is True,
        "code": str(saved.get("code") or "connection_failed"),
        "checked_at": str(saved.get("checked_at") or ""),
        **details,
    }


def _write_probe_audio(path: Path) -> None:
    sample_rate = 16000
    frame_count = sample_rate // 4
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\0\0" * frame_count)


def _test_error_code(exc: Exception) -> str:
    known = {
        "bad_schema",
        "auth_error",
        "bad_gateway",
        "connection_failed",
        "credential_missing",
        "http_error",
        "network_error",
        "provider_server_error",
        "provider_preflight_failed",
        "provider_timeout",
        "rate_limit",
        "request_timeout",
        "service_unreachable",
        "service_unavailable",
        "gateway_timeout",
        "unsupported_auth",
        "openrouter_asr_timestamps_missing",
        "unsupported_openrouter_asr_model",
    }
    explicit = str(getattr(exc, "code", "") or getattr(exc, "error_type", "") or "").strip().lower()
    if explicit in known:
        return explicit
    message = str(exc).strip()
    if message.lower().startswith("missing credential:"):
        return "credential_missing"
    prefix = message.split(":", 1)[0].strip().lower() if ":" in message else ""
    if prefix in known:
        return prefix
    if isinstance(exc, TimeoutError):
        return "request_timeout"
    return "connection_failed"
