from __future__ import annotations

import importlib.util
import os
import posixpath
import site
import sys
import urllib.parse
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
        model_size: str,
        device: str,
        compute_type: str,
        mode: str = "local",
        source_lang: str | None = None,
        local_max_initial_timestamp: float = 30.0,
        local_beam_size: int = 5,
        local_temperature: float = 0.0,
        local_condition_on_previous_text: bool = True,
        local_hotwords: str = "",
        prompt: str = "",
        asr_provider: AsrProviderConfig | None = None,
        root_dir: Path | None = None,
    ) -> None:
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.mode = mode
        self.source_lang = source_lang
        self.local_max_initial_timestamp = max(float(local_max_initial_timestamp), 0.0)
        self.local_beam_size = max(int(local_beam_size), 1)
        self.local_temperature = float(local_temperature)
        self.local_condition_on_previous_text = bool(local_condition_on_previous_text)
        self.local_hotwords = str(local_hotwords or "").strip()
        self.prompt = prompt
        self.asr_provider = asr_provider
        self.root_dir = root_dir
        self._model = None

    def _ensure_model(self) -> Any:
        if self._model is None:
            _prepare_local_cuda_runtime(self.device)
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
        return self.transcribe_segment_result(audio_path, segment_start_offset).rows

    def transcribe_segment_result(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        prompt: str | None = None,
    ) -> AsrTranscriptionResult:
        if self.mode == "local":
            return AsrTranscriptionResult(
                rows=self._transcribe_segment_local(
                    audio_path,
                    segment_start_offset,
                    prompt=self.prompt if prompt is None else prompt,
                )
            )
        if self.mode == "cloud":
            client = build_asr_client(self.asr_provider)
            return client.transcribe_segment(
                audio_path,
                segment_start_offset,
                source_lang=self.source_lang,
                prompt=self.prompt if prompt is None else prompt,
                root_dir=self.root_dir,
            )
        raise RuntimeError(f"Unsupported ASR mode: {self.mode}")

    def _transcribe_segment_local(
        self,
        audio_path: Path,
        segment_start_offset: float,
        *,
        prompt: str = "",
    ) -> list[dict]:
        model = self._ensure_model()
        transcribe_kwargs: dict[str, Any] = {
            "vad_filter": False,
            "beam_size": self.local_beam_size,
            "temperature": self.local_temperature,
            "condition_on_previous_text": self.local_condition_on_previous_text,
        }
        language = _normalize_whisper_language(self.source_lang)
        if language:
            transcribe_kwargs["language"] = language
        transcribe_kwargs["max_initial_timestamp"] = self.local_max_initial_timestamp
        prompt = str(prompt or "").strip()
        if prompt:
            transcribe_kwargs["initial_prompt"] = prompt
        if self.local_hotwords:
            transcribe_kwargs["hotwords"] = self.local_hotwords
        segments, _info = model.transcribe(str(audio_path), **transcribe_kwargs)
        rows = []
        for item in segments:
            rows.append(
                {
                    "start": float(item.start) + segment_start_offset,
                    "end": float(item.end) + segment_start_offset,
                    "text": str(item.text).strip(),
                    "confidence": getattr(item, "avg_logprob", None),
                    "meta": {"source": "asr", "provider": "local", "protocol": "faster_whisper"},
                }
            )
        return rows

    def _transcribe_segment_openai(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        if self.asr_provider is None:
            raise RuntimeError("Missing ASR provider config")
        client = OpenAITranscriptionsAsrClient(self.asr_provider)
        return client.transcribe_segment(
            audio_path,
            segment_start_offset,
            source_lang=self.source_lang,
            prompt=self.prompt,
            root_dir=self.root_dir,
        ).rows


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
        credential = resolve_credential(
            env_key=self.config.env_key,
            credential_id=self.config.credential_id,
            provider_name="",
            root_dir=root_dir,
        )
        if not credential.found:
            raise RuntimeError(f"Missing credential: {credential.credential_id or credential.env_key}")
        if self.config.request.response_format != "verbose_json":
            raise RuntimeError(
                f"unsupported_asr_response_format_for_segments: {self.config.request.response_format}"
            )
        _validate_extra_form_fields(self.config.request.extra_form_fields)
        response, transport_meta = self._call_openai_transcriptions(
            audio_path,
            api_key=credential.key,
            source_lang=source_lang,
            prompt=prompt,
        )
        rows: list[dict] = []
        segments = response.get("segments")
        if isinstance(segments, list) and segments:
            for item in segments:
                text = str(item.get("text", "")).strip()
                if not text:
                    continue
                rows.append(
                    {
                        "start": float(item.get("start", 0.0)) + segment_start_offset,
                        "end": float(item.get("end", 0.0)) + segment_start_offset,
                        "text": text,
                        "confidence": item.get("avg_logprob"),
                        "meta": {
                            "provider": self.config.name,
                            "protocol": self.config.protocol,
                            "source": "asr",
                            **_asr_row_transport_meta(transport_meta),
                        },
                    }
                )
            return AsrTranscriptionResult(rows=rows, raw_response=response, transport_meta=transport_meta)
        text = str(response.get("text", "")).strip()
        if not text:
            return AsrTranscriptionResult(rows=[], raw_response=response, transport_meta=transport_meta)
        return AsrTranscriptionResult(
            rows=[
                {
                    "start": segment_start_offset,
                    "end": segment_start_offset + 0.1,
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
        auth_headers = {"Authorization": f"Bearer {api_key}"}
        payload, transport_meta = request_json_with_retry(
            "POST",
            url,
            data=data,
            files=files,
            headers=merge_default_headers(auth_headers, **DEFAULT_JSON_HEADERS),
            timeout=float(self.config.timeout_seconds),
            http2=bool(getattr(self.config, "http2", True)),
            retry=max(1, int(getattr(self.config, "retry", 1) or 1)),
            context="cloud ASR upstream",
        )
        if not isinstance(payload, dict):
            raise RuntimeError("bad_schema: unexpected cloud ASR response")
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
        add_field("response_format", self.config.request.response_format)
        language = _normalize_whisper_language(source_lang)
        if language:
            add_field("language", language)
        add_field("temperature", _format_form_number(self.config.request.temperature))
        timestamp_key = _asr_array_field_name("timestamp_granularities", array_format)
        for granularity in self.config.request.timestamp_granularities:
            if str(granularity).strip():
                add_field(timestamp_key, str(granularity).strip())
        if prompt:
            add_field("prompt", prompt)
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


def build_asr_client(config: AsrProviderConfig | None) -> OpenAITranscriptionsAsrClient:
    if config is None:
        raise RuntimeError("Missing ASR provider config")
    if config.protocol == "openai_transcriptions":
        return OpenAITranscriptionsAsrClient(config)
    raise RuntimeError(f"unsupported_asr_protocol: {config.protocol}")


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


def _asr_row_transport_meta(meta: dict[str, Any]) -> dict[str, Any]:
    return {
        key: meta[key]
        for key in ("transport", "http_version", "http2_requested", "http2_enabled")
        if key in meta
    }


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
