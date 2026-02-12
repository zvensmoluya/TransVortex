from __future__ import annotations

from pathlib import Path
from typing import Any

from .utils import write_json


class AsrEngine:
    def __init__(self, *, model_size: str, device: str, compute_type: str) -> None:
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._model = None

    def _ensure_model(self) -> Any:
        if self._model is None:
            try:
                from faster_whisper import WhisperModel
            except Exception as exc:  # pragma: no cover - runtime dependency
                raise RuntimeError(
                    "faster-whisper is required for ASR. Install with: pip install -e .[asr]"
                ) from exc
            self._model = WhisperModel(
                self.model_size,
                device=self.device,
                compute_type=self.compute_type,
            )
        return self._model

    def transcribe_segment(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        model = self._ensure_model()
        segments, _info = model.transcribe(str(audio_path), vad_filter=False)
        rows = []
        for item in segments:
            rows.append(
                {
                    "start": float(item.start) + segment_start_offset,
                    "end": float(item.end) + segment_start_offset,
                    "text": str(item.text).strip(),
                    "confidence": getattr(item, "avg_logprob", None),
                }
            )
        return rows


def write_segment_asr_output(path: Path, rows: list[dict]) -> None:
    write_json(path, rows)
