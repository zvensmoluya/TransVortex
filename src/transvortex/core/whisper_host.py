from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import sys
import tempfile
import traceback
import wave
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = 1
DLL_SUBDIRECTORIES = (
    ("nvidia", "cuda_runtime", "bin"),
    ("nvidia", "cuda_nvrtc", "bin"),
    ("nvidia", "cublas", "bin"),
    ("nvidia", "cudnn", "bin"),
)
_DLL_HANDLES: list[Any] = []


class WhisperHost:
    def __init__(self, *, accelerator_root: Path | None = None) -> None:
        self.accelerator_root = accelerator_root
        self.model: Any | None = None
        self.model_path = ""
        self.device = ""
        self.compute_type = ""
        _prepare_accelerator(accelerator_root)

    def runtime_info(self) -> dict[str, Any]:
        import ctranslate2

        return {
            "protocol_version": PROTOCOL_VERSION,
            "python_version": ".".join(str(part) for part in sys.version_info[:3]),
            "python_executable": sys.executable,
            "faster_whisper_version": _package_version("faster-whisper"),
            "ctranslate2_version": _package_version("ctranslate2"),
            "cpu_compute_types": sorted(ctranslate2.get_supported_compute_types("cpu")),
            "cuda": _cuda_info(ctranslate2),
        }

    def load_model(self, params: dict[str, Any]) -> dict[str, Any]:
        from faster_whisper import WhisperModel

        raw_path = str(params.get("model_path") or "").strip()
        if not raw_path:
            raise ValueError("model_path is required")
        model_path = Path(raw_path).expanduser().resolve()
        if not model_path.is_dir():
            raise FileNotFoundError(f"Model directory not found: {model_path}")
        device, compute_type = _resolve_device(
            str(params.get("device") or "auto"),
            str(params.get("compute_type") or "auto"),
        )
        self.model = WhisperModel(
            str(model_path),
            device=device,
            compute_type=compute_type,
            local_files_only=True,
        )
        self.model_path = str(model_path)
        self.device = device
        self.compute_type = compute_type
        return {
            "loaded": True,
            "model_path": self.model_path,
            "device": device,
            "compute_type": compute_type,
        }

    def transcribe(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.model is None:
            raise RuntimeError("model_not_loaded")
        audio_path = Path(str(params.get("audio_path") or "")).expanduser().resolve()
        if not audio_path.is_file():
            raise FileNotFoundError(f"Audio file not found: {audio_path}")
        offset = float(params.get("segment_start_offset") or 0.0)
        options = params.get("options") if isinstance(params.get("options"), dict) else {}
        kwargs: dict[str, Any] = {
            "vad_filter": False,
            "beam_size": max(int(options.get("beam_size", 5)), 1),
            "temperature": float(options.get("temperature", 0.0)),
            "condition_on_previous_text": bool(options.get("condition_on_previous_text", False)),
            "max_initial_timestamp": max(float(options.get("max_initial_timestamp", 30.0)), 0.0),
        }
        language = _normalize_language(str(params.get("source_lang") or ""))
        if language:
            kwargs["language"] = language
        prompt = str(params.get("prompt") or "").strip()
        if prompt:
            kwargs["initial_prompt"] = prompt
        hotwords = str(options.get("hotwords") or "").strip()
        if hotwords:
            kwargs["hotwords"] = hotwords
        segments, info = self.model.transcribe(str(audio_path), **kwargs)
        rows = [
            {
                "start": float(item.start) + offset,
                "end": float(item.end) + offset,
                "text": str(item.text).strip(),
                "confidence": getattr(item, "avg_logprob", None),
                "meta": {"source": "asr", "protocol": "faster_whisper"},
            }
            for item in segments
        ]
        return {
            "rows": rows,
            "model_path": self.model_path,
            "device": self.device,
            "compute_type": self.compute_type,
            "language": getattr(info, "language", None),
            "language_probability": getattr(info, "language_probability", None),
        }


def serve(host: WhisperHost) -> None:
    for raw in sys.stdin:
        line = raw.strip().lstrip("\ufeff")
        if not line:
            continue
        request_id: Any = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
            request_id = request.get("id")
            version = int(request.get("protocol_version", PROTOCOL_VERSION))
            if version != PROTOCOL_VERSION:
                raise RuntimeError(f"unsupported_protocol_version:{version}")
            method = str(request.get("method") or "")
            params = request.get("params") if isinstance(request.get("params"), dict) else {}
            if method == "runtime.info":
                result = host.runtime_info()
            elif method == "model.load":
                result = host.load_model(params)
            elif method == "transcribe":
                result = host.transcribe(params)
            elif method == "shutdown":
                _write_response({"id": request_id, "result": {"ok": True}})
                return
            else:
                raise RuntimeError(f"method_not_found:{method}")
            _write_response({"id": request_id, "result": result})
        except Exception as exc:  # noqa: BLE001 - the host must keep protocol output valid
            print(traceback.format_exc(), file=sys.stderr, flush=True)
            _write_response(
                {
                    "id": request_id,
                    "error": {
                        "code": _error_code(exc),
                        "message": str(exc),
                    },
                }
            )


def probe_runtime(
    *,
    model_path: Path | None = None,
    device: str = "auto",
    compute_type: str = "auto",
    accelerator_root: Path | None = None,
) -> dict[str, Any]:
    try:
        host = WhisperHost(accelerator_root=accelerator_root)
        payload = host.runtime_info()
        if model_path is not None:
            payload["model"] = host.load_model(
                {"model_path": str(model_path), "device": device, "compute_type": compute_type}
            )
            with tempfile.TemporaryDirectory(prefix="transvortex-whisper-probe-") as raw_dir:
                audio_path = Path(raw_dir) / "probe.wav"
                _write_probe_audio(audio_path)
                result = host.transcribe({"audio_path": str(audio_path), "source_lang": "en"})
                payload["transcription"] = {"ok": True, "row_count": len(result.get("rows") or [])}
        payload["ok"] = True
        return payload
    except Exception as exc:  # noqa: BLE001 - probe output is a structured diagnostic
        return {"ok": False, "code": _error_code(exc), "message": str(exc)}


def _resolve_device(device: str, compute_type: str) -> tuple[str, str]:
    import ctranslate2

    normalized_device = device.strip().lower() or "auto"
    normalized_compute = compute_type.strip().lower() or "auto"
    if normalized_device == "auto":
        cuda = _cuda_info(ctranslate2)
        normalized_device = "cuda" if cuda.get("available") else "cpu"
    if normalized_device not in {"cpu", "cuda"}:
        raise ValueError(f"unsupported_device:{device}")
    supported = set(ctranslate2.get_supported_compute_types(normalized_device))
    if normalized_compute == "auto":
        preferred = ("int8_float16", "float16", "int8") if normalized_device == "cuda" else ("int8", "int8_float32", "float32")
        normalized_compute = next((item for item in preferred if item in supported), "")
    if not normalized_compute or normalized_compute not in supported:
        raise RuntimeError(f"unsupported_compute_type:{normalized_device}:{compute_type}")
    return normalized_device, normalized_compute


def _cuda_info(ctranslate2: Any) -> dict[str, Any]:
    try:
        count = int(ctranslate2.get_cuda_device_count())
        compute_types = sorted(ctranslate2.get_supported_compute_types("cuda")) if count > 0 else []
        return {"available": count > 0, "device_count": count, "compute_types": compute_types}
    except Exception as exc:  # noqa: BLE001 - missing CUDA libraries are normal on CPU systems
        return {"available": False, "device_count": 0, "compute_types": [], "error": str(exc)}


def _prepare_accelerator(root: Path | None) -> None:
    roots = [root] if root is not None else []
    roots.extend(Path(item) for item in sys.path if item)
    for candidate in roots:
        for parts in DLL_SUBDIRECTORIES:
            path = candidate.joinpath(*parts)
            if not path.is_dir():
                continue
            if hasattr(os, "add_dll_directory"):
                _DLL_HANDLES.append(os.add_dll_directory(str(path)))
            os.environ["PATH"] = str(path) + os.pathsep + os.environ.get("PATH", "")


def _package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return ""


def _normalize_language(value: str) -> str | None:
    normalized = value.strip().lower().replace("_", "-")
    if not normalized or normalized in {"auto", "detect", "auto-detect"}:
        return None
    return normalized.split("-", 1)[0] or None


def _error_code(exc: Exception) -> str:
    text = str(exc).strip()
    if ":" in text:
        return text.split(":", 1)[0]
    if isinstance(exc, FileNotFoundError):
        return "file_not_found"
    if isinstance(exc, ValueError):
        return "invalid_request"
    return "runtime_error"


def _write_response(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _write_probe_audio(path: Path) -> None:
    sample_rate = 16000
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\0\0" * (sample_rate // 4))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="transvortex-whisper-host")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--model-path", default="")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--compute-type", default="auto")
    parser.add_argument("--accelerator-root", default="")
    args = parser.parse_args(argv)
    if args.probe:
        payload = probe_runtime(
            model_path=Path(args.model_path) if args.model_path else None,
            device=args.device,
            compute_type=args.compute_type,
            accelerator_root=Path(args.accelerator_root) if args.accelerator_root else None,
        )
        _write_response(payload)
        raise SystemExit(0 if payload.get("ok") else 1)
    serve(WhisperHost(accelerator_root=Path(args.accelerator_root) if args.accelerator_root else None))


if __name__ == "__main__":
    main()
