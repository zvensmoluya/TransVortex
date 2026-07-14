from __future__ import annotations

import tempfile
import wave
from pathlib import Path
from typing import Any

from ..core.asr import AsrEngine
from .asr_runtime import record_provider_test
from .models import AsrProviderConfig


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
            "row_count": len(result.rows),
            "transport": result.transport_meta,
        }
        saved = record_provider_test(
            provider,
            root_dir=root_dir,
            ok=True,
            code="ready",
            details=details,
        )
        return {**saved, **details}
    except Exception as exc:  # noqa: BLE001 - provider tests return a structured diagnostic
        details = {
            "provider": provider.name,
            "protocol": provider.protocol,
            "message": str(exc),
        }
        saved = record_provider_test(
            provider,
            root_dir=root_dir,
            ok=False,
            code=_test_error_code(exc),
            details=details,
        )
        return {**saved, **details}
    finally:
        if engine is not None:
            engine.close()


def _write_probe_audio(path: Path) -> None:
    sample_rate = 16000
    frame_count = sample_rate // 4
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\0\0" * frame_count)


def _test_error_code(exc: Exception) -> str:
    message = str(exc).strip()
    if ":" in message:
        prefix = message.split(":", 1)[0].strip()
        if prefix:
            return prefix
    return "connection_failed"
