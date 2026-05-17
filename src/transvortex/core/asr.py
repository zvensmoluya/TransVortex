from __future__ import annotations

import json
import posixpath
import socket
import time
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError

from ..app.credentials import resolve_credential
from ..app.models import AsrProviderConfig
from ..http import DEFAULT_USER_AGENT, merge_default_headers
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


@dataclass
class AsrTranscriptionResult:
    rows: list[dict]
    raw_response: dict[str, Any] | None = None


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
        self.prompt = prompt
        self.asr_provider = asr_provider
        self.root_dir = root_dir
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
        return self.transcribe_segment_result(audio_path, segment_start_offset).rows

    def transcribe_segment_result(self, audio_path: Path, segment_start_offset: float) -> AsrTranscriptionResult:
        if self.mode == "local":
            return AsrTranscriptionResult(rows=self._transcribe_segment_local(audio_path, segment_start_offset))
        if self.mode == "cloud":
            client = build_asr_client(self.asr_provider)
            return client.transcribe_segment(
                audio_path,
                segment_start_offset,
                source_lang=self.source_lang,
                prompt=self.prompt,
                root_dir=self.root_dir,
            )
        raise RuntimeError(f"Unsupported ASR mode: {self.mode}")

    def _transcribe_segment_local(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        model = self._ensure_model()
        transcribe_kwargs: dict[str, Any] = {"vad_filter": False}
        language = _normalize_whisper_language(self.source_lang)
        if language:
            transcribe_kwargs["language"] = language
        transcribe_kwargs["max_initial_timestamp"] = self.local_max_initial_timestamp
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
        response = self._call_openai_transcriptions(
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
                        },
                    }
                )
            return AsrTranscriptionResult(rows=rows, raw_response=response)
        text = str(response.get("text", "")).strip()
        if not text:
            return AsrTranscriptionResult(rows=[], raw_response=response)
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
                    },
                }
            ],
            raw_response=response,
        )

    def _call_openai_transcriptions(
        self,
        audio_path: Path,
        *,
        api_key: str,
        source_lang: str | None = None,
        prompt: str = "",
    ) -> dict[str, Any]:
        boundary = f"----TransVortex{uuid.uuid4().hex}"
        body = self._build_multipart_body(
            audio_path=audio_path,
            boundary=boundary,
            source_lang=source_lang,
            prompt=prompt,
        )
        url = _build_cloud_asr_url(self.config.base_url, self.config.endpoint)
        auth_headers = {"Authorization": f"Bearer {api_key}"}
        method = "POST"
        req = urllib.request.Request(
            url=url,
            data=body,
            method=method,
            headers=merge_default_headers(
                auth_headers,
                Accept="application/json",
                **{
                    "User-Agent": DEFAULT_USER_AGENT,
                    "Content-Type": f"multipart/form-data; boundary={boundary}",
                },
            ),
        )
        raw = self._urlopen_with_retry(req)
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise RuntimeError("bad_schema: unexpected cloud ASR response")
        return payload

    def _urlopen_with_retry(self, req: urllib.request.Request) -> str:
        attempts = max(1, int(getattr(self.config, "retry", 1) or 1))
        last_exc: Exception | None = None
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(req, timeout=self.config.timeout_seconds) as resp:
                    return resp.read().decode("utf-8")
            except Exception as exc:
                last_exc = exc
                if attempt + 1 >= attempts or not _is_retryable_asr_error(exc):
                    raise
                time.sleep(min(0.5 * (2**attempt), 4.0))
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("cloud_asr_request_failed")

    def _build_multipart_body(
        self,
        *,
        audio_path: Path,
        boundary: str,
        source_lang: str | None = None,
        prompt: str = "",
    ) -> bytes:
        def add_field(chunks: list[bytes], name: str, value: str) -> None:
            chunks.append(f"--{boundary}\r\n".encode("utf-8"))
            chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
            chunks.append(value.encode("utf-8"))
            chunks.append(b"\r\n")

        def add_multi_field(chunks: list[bytes], name: str, value: Any) -> None:
            if value is None:
                return
            if isinstance(value, (list, tuple)):
                for item in value:
                    add_multi_field(chunks, name, item)
                return
            if isinstance(value, bool):
                add_field(chunks, name, "true" if value else "false")
                return
            add_field(chunks, name, str(value))

        _validate_extra_form_fields(self.config.request.extra_form_fields)
        array_format = _normalize_asr_array_format(self.config.request.array_format)
        chunks: list[bytes] = []
        add_field(chunks, "model", self.config.model)
        add_field(chunks, "response_format", self.config.request.response_format)
        language = _normalize_whisper_language(source_lang)
        if language:
            add_field(chunks, "language", language)
        add_field(chunks, "temperature", _format_form_number(self.config.request.temperature))
        timestamp_key = _asr_array_field_name("timestamp_granularities", array_format)
        for granularity in self.config.request.timestamp_granularities:
            if str(granularity).strip():
                add_field(chunks, timestamp_key, str(granularity).strip())
        if prompt:
            add_field(chunks, "prompt", prompt)
        include_key = _asr_array_field_name("include", array_format)
        for include_item in self.config.request.include:
            if str(include_item).strip():
                add_field(chunks, include_key, str(include_item).strip())
        for name, value in self.config.request.extra_form_fields.items():
            add_multi_field(chunks, str(name), value)

        file_name = audio_path.name
        file_bytes = audio_path.read_bytes()
        mime = "audio/wav" if audio_path.suffix.lower() == ".wav" else "application/octet-stream"
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            (
                f'Content-Disposition: form-data; name="file"; filename="{file_name}"\r\n'
                f"Content-Type: {mime}\r\n\r\n"
            ).encode("utf-8")
        )
        chunks.append(file_bytes)
        chunks.append(b"\r\n")
        chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
        return b"".join(chunks)


def build_asr_client(config: AsrProviderConfig | None) -> OpenAITranscriptionsAsrClient:
    if config is None:
        raise RuntimeError("Missing ASR provider config")
    if config.protocol == "openai_transcriptions":
        return OpenAITranscriptionsAsrClient(config)
    raise RuntimeError(f"unsupported_asr_protocol: {config.protocol}")


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


def _is_retryable_asr_error(exc: Exception) -> bool:
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return True
    if isinstance(exc, HTTPError):
        return exc.code in {408, 409, 425, 429, 500, 502, 503, 504}
    if isinstance(exc, URLError):
        reason = getattr(exc, "reason", None)
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return True
        lowered = str(reason or exc).lower()
        return any(
            marker in lowered
            for marker in (
                "timed out",
                "timeout",
                "temporarily unavailable",
                "unexpected_eof",
                "eof occurred",
                "connection reset",
                "connection aborted",
                "remote end closed connection",
            )
        )
    lowered = str(exc).lower()
    return any(
        marker in lowered
        for marker in (
            "timed out",
            "timeout",
            "http error 429",
            "http error 5",
            "unexpected_eof",
            "eof occurred",
            "connection reset",
            "connection aborted",
            "remote end closed connection",
        )
    )


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
