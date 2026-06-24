from __future__ import annotations

import importlib.util
import os
import posixpath
import site
import sys
import urllib.parse
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..app.credentials import resolve_credential
from ..app.models import AsrProviderConfig
from ..http import DEFAULT_JSON_HEADERS, merge_default_headers, request_json_with_retry
from ..utils import write_json


ASR_EXTRA_FORM_RESERVED_FIELDS = {
    "file",
    "model",
    "language",
    "response_format",
    "temperature",
    "timestamp_granularities",
    "timestamp_granularities[]",
    "include",
    "include[]",
}

_CUDA_WHEEL_DLL_SUBDIRS = (
    ("cuda_runtime", "bin"),
    ("cuda_nvrtc", "bin"),
    ("cublas", "bin"),
    ("cudnn", "bin"),
)
_CUDA_DLL_DIRECTORY_HANDLES: list[Any] = []
_CUDA_DLL_DIRECTORY_PATHS: set[str] = set()
_CUDA_DLL_DIRECTORIES_REGISTERED = False


@dataclass
class AsrTranscriptionResult:
    rows: list[dict]
    raw_response: dict[str, Any] | None = None
    transport_meta: dict[str, Any] = field(default_factory=dict)


class AsrEngine:
    def __init__(
        self,
        *,
        asr_provider: AsrProviderConfig,
        source_lang: str | None = None,
        prompt: str = "",
        root_dir: Path | None = None,
    ) -> None:
        self.asr_provider = asr_provider
        self.source_lang = source_lang
        self.prompt = prompt
        self.root_dir = root_dir
        self._adapter = build_asr_client(asr_provider)

    def transcribe_segment(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        return self.transcribe_segment_result(audio_path, segment_start_offset).rows

    def transcribe_segment_result(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        prompt: str | None = None,
    ) -> AsrTranscriptionResult:
        return self._adapter.transcribe_segment(
            audio_path,
            segment_start_offset,
            source_lang=self.source_lang,
            prompt=self.prompt if prompt is None else prompt,
            root_dir=self.root_dir,
        )


class FasterWhisperAsrAdapter:
    def __init__(self, config: AsrProviderConfig) -> None:
        self.config = config
        self._model = None

    def _ensure_model(self) -> Any:
        local = self.config.local
        if self._model is None:
            _prepare_local_cuda_runtime(local.device)
            try:
                from faster_whisper import WhisperModel
            except Exception as exc:  # pragma: no cover - runtime dependency
                raise RuntimeError(
                    "faster-whisper is required for ASR. Install with: pip install -e .[asr]"
                ) from exc
            self._model = WhisperModel(
                self.config.model or local.model_size,
                device=local.device,
                compute_type=local.compute_type,
            )
        return self._model

    def transcribe_segment(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        prompt: str = "",
        source_lang: str | None = None,
        root_dir: Path | None = None,
    ) -> AsrTranscriptionResult:
        del root_dir
        local = self.config.local
        model = self._ensure_model()
        transcribe_kwargs: dict[str, Any] = {
            "vad_filter": False,
            "beam_size": max(int(local.beam_size), 1),
            "temperature": float(local.temperature),
            "condition_on_previous_text": bool(local.condition_on_previous_text),
        }
        language = _normalize_whisper_language(source_lang)
        if language:
            transcribe_kwargs["language"] = language
        transcribe_kwargs["max_initial_timestamp"] = max(float(local.max_initial_timestamp), 0.0)
        prompt = str(prompt or "").strip()
        if prompt:
            transcribe_kwargs["initial_prompt"] = prompt
        hotwords = str(local.hotwords or "").strip()
        if hotwords:
            transcribe_kwargs["hotwords"] = hotwords
        segments, _info = model.transcribe(str(audio_path), **transcribe_kwargs)
        rows = []
        for item in segments:
            rows.append(
                {
                    "start": float(item.start) + segment_start_offset,
                    "end": float(item.end) + segment_start_offset,
                    "text": str(item.text).strip(),
                    "confidence": getattr(item, "avg_logprob", None),
                    "meta": {"source": "asr", "provider": self.config.name, "protocol": "faster_whisper"},
                }
            )
        return AsrTranscriptionResult(rows=rows)


class OpenAITranscriptionsAsrClient:
    def __init__(self, config: AsrProviderConfig) -> None:
        self.config = config

    def transcribe_segment(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        source_lang: str | None = None,
        prompt: str = "",
        root_dir: Path | None = None,
    ) -> AsrTranscriptionResult:
        api_key = ""
        if self.config.auth.type == "bearer":
            credential = resolve_credential(
                env_key=self.config.env_key,
                credential_id=self.config.credential_id,
                provider_name="",
                root_dir=root_dir,
            )
            if not credential.found:
                raise RuntimeError(f"Missing credential: {credential.credential_id or credential.env_key}")
            api_key = credential.key
        elif self.config.auth.type != "none":
            raise RuntimeError(f"unsupported_asr_auth_type: {self.config.auth.type}")
        if self.config.request.response_format != "verbose_json":
            raise RuntimeError(
                f"unsupported_asr_response_format_for_segments: {self.config.request.response_format}"
            )
        _validate_extra_form_fields(self.config.request.extra_form_fields)
        response, transport_meta = self._call_openai_transcriptions(
            audio_path,
            api_key=api_key,
            source_lang=source_lang,
            prompt=prompt,
        )
        rows = _map_openai_transcription_rows(
            response=response,
            config=self.config,
            segment_start_offset=segment_start_offset,
            transport_meta=transport_meta,
        )
        if rows:
            return AsrTranscriptionResult(rows=rows, raw_response=response, transport_meta=transport_meta)
        text = str(response.get("text", "")).strip()
        if not text:
            return AsrTranscriptionResult(rows=[], raw_response=response, transport_meta=transport_meta)
        return AsrTranscriptionResult(
            rows=[
                {
                    "start": segment_start_offset,
                    "end": segment_start_offset + _fallback_audio_duration_seconds(audio_path),
                    "text": text,
                    "confidence": None,
                    "meta": {
                        "provider": self.config.name,
                        "protocol": self.config.protocol,
                        "source": "asr",
                        "warning": "missing_timestamps",
                        **_asr_row_transport_meta(transport_meta),
                    },
                }
            ],
            raw_response=response,
            transport_meta=transport_meta,
        )

    def _call_openai_transcriptions(
        self,
        audio_path: Path,
        *,
        api_key: str,
        source_lang: str | None = None,
        prompt: str = "",
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        data, files = self._build_multipart_fields(
            audio_path=audio_path,
            source_lang=source_lang,
            prompt=prompt,
        )
        url = _build_cloud_asr_url(self.config.base_url, self.config.endpoint)
        auth_headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        payload, transport_meta = request_json_with_retry(
            "POST",
            url,
            data=data,
            files=files,
            headers=merge_default_headers(auth_headers, **DEFAULT_JSON_HEADERS),
            timeout=float(self.config.execution.timeout_seconds),
            http2=bool(getattr(self.config, "http2", True)),
            retry=max(1, int(getattr(self.config.execution, "retry", 1) or 1)),
            context="ASR upstream",
        )
        if not isinstance(payload, dict):
            raise RuntimeError("bad_schema: unexpected ASR response")
        return payload, transport_meta

    def _build_multipart_fields(
        self,
        *,
        audio_path: Path,
        source_lang: str | None = None,
        prompt: str = "",
    ) -> tuple[dict[str, Any], list[tuple[str, Any]]]:
        data: dict[str, Any] = {}

        def add_field(name: str, value: str) -> None:
            existing = data.get(name)
            if existing is None:
                data[name] = value
            elif isinstance(existing, list):
                existing.append(value)
            else:
                data[name] = [existing, value]

        def add_multi_field(name: str, value: Any) -> None:
            if value is None:
                return
            if isinstance(value, (list, tuple)):
                for item in value:
                    add_multi_field(name, item)
                return
            if isinstance(value, bool):
                add_field(name, "true" if value else "false")
                return
            add_field(name, str(value))

        _validate_extra_form_fields(self.config.request.extra_form_fields)
        array_format = _normalize_asr_array_format(self.config.request.array_format)
        add_field("model", self.config.model)
        if _asr_request_bool(self.config.request, "send_response_format", True):
            add_field("response_format", self.config.request.response_format)
        language = _normalize_whisper_language(source_lang)
        if language and _asr_request_bool(self.config.request, "send_language", True):
            add_field(str(getattr(self.config.request, "language_field", "language") or "language"), language)
        if _asr_request_bool(self.config.request, "send_temperature", True):
            add_field("temperature", _format_form_number(self.config.request.temperature))
        if _asr_request_bool(self.config.request, "send_timestamp_granularities", True):
            timestamp_key = _asr_array_field_name("timestamp_granularities", array_format)
            for granularity in self.config.request.timestamp_granularities:
                if str(granularity).strip():
                    add_field(timestamp_key, str(granularity).strip())
        if prompt and _asr_request_bool(self.config.request, "send_prompt", True):
            add_field(str(getattr(self.config.request, "prompt_field", "prompt") or "prompt"), prompt)
        include_key = _asr_array_field_name("include", array_format)
        for include_item in self.config.request.include:
            if str(include_item).strip():
                add_field(include_key, str(include_item).strip())
        for name, value in self.config.request.extra_form_fields.items():
            add_multi_field(str(name), value)

        file_name = audio_path.name
        file_bytes = audio_path.read_bytes()
        mime = "audio/wav" if audio_path.suffix.lower() == ".wav" else "application/octet-stream"
        files = [("file", (file_name, file_bytes, mime))]
        return data, files


class FunASROpenAIAsrClient(OpenAITranscriptionsAsrClient):
    def transcribe_segment(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        source_lang: str | None = None,
        prompt: str = "",
        root_dir: Path | None = None,
    ) -> AsrTranscriptionResult:
        del root_dir
        if self.config.auth.type != "none":
            raise RuntimeError(f"unsupported_funasr_auth_type: {self.config.auth.type}")
        if self.config.request.response_format != "verbose_json":
            raise RuntimeError(
                f"unsupported_funasr_response_format_for_segments: {self.config.request.response_format}"
            )
        if self.config.request.include:
            raise RuntimeError("unsupported_funasr_request_field: include")
        if self.config.request.extra_form_fields:
            raise RuntimeError("unsupported_funasr_request_field: extra_form_fields")
        _validate_extra_form_fields(self.config.request.extra_form_fields)
        response, transport_meta = self._call_openai_transcriptions(
            audio_path,
            api_key="",
            source_lang=source_lang,
            prompt=prompt,
        )
        rows = _map_funasr_openai_rows(
            response=response,
            config=self.config,
            segment_start_offset=segment_start_offset,
            transport_meta=transport_meta,
        )
        if rows:
            return AsrTranscriptionResult(rows=rows, raw_response=response, transport_meta=transport_meta)
        text = str(response.get("text", "")).strip()
        if not text:
            return AsrTranscriptionResult(rows=[], raw_response=response, transport_meta=transport_meta)
        return AsrTranscriptionResult(
            rows=[
                {
                    "start": segment_start_offset,
                    "end": segment_start_offset + _fallback_audio_duration_seconds(audio_path),
                    "text": text,
                    "confidence": None,
                    "meta": {
                        "provider": self.config.name,
                        "protocol": self.config.protocol,
                        "source": "asr",
                        "warning": "missing_segment_timestamps",
                        **_asr_row_transport_meta(transport_meta),
                    },
                }
            ],
            raw_response=response,
            transport_meta=transport_meta,
        )


def build_asr_client(
    config: AsrProviderConfig | None,
) -> FasterWhisperAsrAdapter | OpenAITranscriptionsAsrClient | FunASROpenAIAsrClient:
    if config is None:
        raise RuntimeError("Missing ASR provider config")
    if config.kind == "local_inprocess" and config.protocol == "faster_whisper":
        return FasterWhisperAsrAdapter(config)
    if config.kind in {"local_server", "remote"} and config.protocol == "openai_transcriptions":
        return OpenAITranscriptionsAsrClient(config)
    if config.kind == "local_server" and config.protocol == "funasr_openai":
        return FunASROpenAIAsrClient(config)
    raise RuntimeError(f"unsupported_asr_provider: {config.kind}/{config.protocol}")


def _prepare_local_cuda_runtime(device: str) -> None:
    if os.name != "nt":
        return
    if str(device or "").strip().lower() not in {"auto", "cuda"}:
        return
    _register_nvidia_cuda_wheel_dll_dirs()


def _candidate_nvidia_package_roots() -> list[Path]:
    candidates: list[Path] = []
    try:
        spec = importlib.util.find_spec("nvidia")
    except Exception:
        spec = None
    locations = getattr(spec, "submodule_search_locations", None) if spec is not None else None
    if locations:
        candidates.extend(Path(location) for location in locations)

    site_paths: list[str] = []
    try:
        site_paths.extend(site.getsitepackages())
    except Exception:
        pass
    try:
        site_paths.append(site.getusersitepackages())
    except Exception:
        pass
    site_paths.extend(sys.path)
    candidates.extend(Path(path) / "nvidia" for path in site_paths if path)

    out: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        try:
            key = str(candidate.resolve())
        except OSError:
            key = str(candidate)
        if key not in seen:
            seen.add(key)
            out.append(candidate)
    return out


def _register_nvidia_cuda_wheel_dll_dirs() -> None:
    global _CUDA_DLL_DIRECTORIES_REGISTERED
    if _CUDA_DLL_DIRECTORIES_REGISTERED:
        return
    _CUDA_DLL_DIRECTORIES_REGISTERED = True
    for root in _candidate_nvidia_package_roots():
        for parts in _CUDA_WHEEL_DLL_SUBDIRS:
            path = root.joinpath(*parts)
            if path.is_dir():
                _add_dll_directory(path)


def _add_dll_directory(path: Path) -> None:
    raw = str(path)
    normalized = os.path.normcase(os.path.abspath(raw))
    if normalized in _CUDA_DLL_DIRECTORY_PATHS:
        return
    _CUDA_DLL_DIRECTORY_PATHS.add(normalized)
    if hasattr(os, "add_dll_directory"):
        handle = os.add_dll_directory(raw)
        _CUDA_DLL_DIRECTORY_HANDLES.append(handle)
    path_items = os.environ.get("PATH", "").split(os.pathsep)
    if normalized not in {os.path.normcase(os.path.abspath(item)) for item in path_items if item}:
        os.environ["PATH"] = raw + os.pathsep + os.environ.get("PATH", "")


def _normalize_whisper_language(source_lang: str | None) -> str | None:
    if not source_lang:
        return None
    return source_lang.split("-", 1)[0].strip().lower() or None


def _format_form_number(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def _normalize_asr_array_format(value: str) -> str:
    normalized = str(value or "repeat").strip().lower()
    if normalized in {"repeat", "brackets"}:
        return normalized
    raise RuntimeError(f"unsupported_asr_array_format: {value}")


def _asr_array_field_name(name: str, array_format: str) -> str:
    return f"{name}[]" if array_format == "brackets" else name


def _asr_request_bool(request: Any, name: str, default: bool) -> bool:
    value = getattr(request, name, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _fallback_audio_duration_seconds(audio_path: Path) -> float:
    if audio_path.suffix.lower() == ".wav":
        try:
            with wave.open(str(audio_path), "rb") as handle:
                rate = handle.getframerate()
                frames = handle.getnframes()
                if rate > 0 and frames > 0:
                    return max(float(frames) / float(rate), 0.1)
        except (wave.Error, OSError, EOFError):
            pass
    return 0.1


def _asr_row_transport_meta(meta: dict[str, Any]) -> dict[str, Any]:
    return {
        key: meta[key]
        for key in ("transport", "http_version", "http2_requested", "http2_enabled")
        if key in meta
    }


def _map_openai_transcription_rows(
    *,
    response: dict[str, Any],
    config: AsrProviderConfig,
    segment_start_offset: float,
    transport_meta: dict[str, Any],
) -> list[dict]:
    rows: list[dict] = []
    segments = response.get("segments")
    if not isinstance(segments, list):
        return rows
    for item in segments:
        if not isinstance(item, dict):
            continue
        text = str(item.get("text", "")).strip()
        if not text:
            continue
        start_seconds = _float_or_none(item.get("start"))
        end_seconds = _float_or_none(item.get("end"))
        if start_seconds is None or end_seconds is None or end_seconds <= start_seconds:
            continue
        confidence = item.get("avg_logprob", item.get("confidence"))
        meta = {
            "provider": config.name,
            "protocol": config.protocol,
            "source": "asr",
            **_asr_row_transport_meta(transport_meta),
        }
        rows.append(
            {
                "start": start_seconds + segment_start_offset,
                "end": end_seconds + segment_start_offset,
                "text": text,
                "confidence": confidence,
                "meta": meta,
            }
        )
    return rows


def _map_funasr_openai_rows(
    *,
    response: dict[str, Any],
    config: AsrProviderConfig,
    segment_start_offset: float,
    transport_meta: dict[str, Any],
) -> list[dict]:
    rows: list[dict] = []
    for item in _funasr_segment_items(response):
        text = _funasr_segment_text(item)
        if not text:
            continue
        start_seconds, end_seconds = _funasr_segment_times(item)
        if start_seconds is None or end_seconds is None or end_seconds <= start_seconds:
            continue
        confidence = item.get("confidence", item.get("avg_logprob"))
        meta = {
            "provider": config.name,
            "protocol": config.protocol,
            "source": "asr",
            **_asr_row_transport_meta(transport_meta),
        }
        item_meta = item.get("meta")
        if isinstance(item_meta, dict):
            for source_key, target_key in (
                ("provider_model", "sensevoice_provider_model"),
                ("has_real_timestamp", "sensevoice_has_real_timestamp"),
                ("language_tag", "sensevoice_language_tag"),
                ("emotion_tag", "sensevoice_emotion_tag"),
                ("event_tag", "sensevoice_event_tag"),
                ("other_tags", "sensevoice_other_tags"),
            ):
                if source_key in item_meta:
                    meta[target_key] = item_meta[source_key]
        speaker = item.get("speaker")
        if speaker is not None:
            meta["speaker"] = speaker
        rows.append(
            {
                "start": start_seconds + segment_start_offset,
                "end": end_seconds + segment_start_offset,
                "text": text,
                "confidence": confidence,
                "meta": meta,
            }
        )
    return rows


def _funasr_segment_items(response: dict[str, Any]) -> list[dict[str, Any]]:
    for key in ("segments", "result", "utterances"):
        value = response.get(key)
        if isinstance(value, list):
            out = [item for item in value if isinstance(item, dict)]
            if out:
                return out
    return []


def _funasr_segment_text(item: dict[str, Any]) -> str:
    for key in ("text", "sentence"):
        value = item.get(key)
        if isinstance(value, (str, int, float)):
            text = str(value).strip()
            if text:
                return text
    return ""


def _funasr_segment_times(item: dict[str, Any]) -> tuple[float | None, float | None]:
    start = _float_or_none(item.get("start"))
    end = _float_or_none(item.get("end"))
    if start is not None and end is not None:
        return start, end
    start = _float_or_none(item.get("start_time"))
    end = _float_or_none(item.get("end_time"))
    if start is not None and end is not None:
        return start, end
    timestamp = item.get("timestamp")
    if isinstance(timestamp, list) and len(timestamp) >= 2:
        start = _float_or_none(timestamp[0])
        end = _float_or_none(timestamp[1])
        if start is not None and end is not None:
            return start / 1000.0, end / 1000.0
    return None, None


def _float_or_none(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _validate_extra_form_fields(fields: dict[str, Any]) -> None:
    for name in fields:
        normalized = str(name).strip()
        if normalized in ASR_EXTRA_FORM_RESERVED_FIELDS:
            raise RuntimeError(f"reserved_asr_form_field: {normalized}")


def _build_cloud_asr_url(base_url: str, endpoint: str) -> str:
    raw_path = endpoint.strip()
    if not raw_path:
        raw_path = "/"
    if not raw_path.startswith("/"):
        raw_path = f"/{raw_path}"
    parsed_base = urllib.parse.urlsplit(base_url.rstrip("/"))
    base_path = parsed_base.path or ""
    endpoint_path = raw_path
    if base_path and endpoint_path.startswith(f"{base_path}/"):
        endpoint_path = endpoint_path[len(base_path) :]
    elif base_path and endpoint_path == base_path:
        endpoint_path = "/"
    combined_path = posixpath.normpath(f"{base_path.rstrip('/')}/{endpoint_path.lstrip('/')}")
    if not combined_path.startswith("/"):
        combined_path = f"/{combined_path}"
    if endpoint_path.endswith("/") and not combined_path.endswith("/"):
        combined_path = f"{combined_path}/"
    return urllib.parse.urlunsplit(
        (
            parsed_base.scheme,
            parsed_base.netloc,
            combined_path,
            parsed_base.query,
            parsed_base.fragment,
        )
    )


def write_segment_asr_output(path: Path, rows: list[dict]) -> None:
    write_json(path, rows)
