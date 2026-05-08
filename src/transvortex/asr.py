from __future__ import annotations

import json
import os
import posixpath
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from .models import ProviderConfig
from .utils import write_json


class AsrEngine:
    def __init__(
        self,
        *,
        model_size: str,
        device: str,
        compute_type: str,
        mode: str = "local",
        source_lang: str | None = None,
        cloud_base_url: str = "https://api.openai.com",
        cloud_endpoint: str = "/v1/audio/transcriptions",
        cloud_model: str = "whisper-1",
        cloud_env_key: str = "TVX_MODEL_API_KEY",
        cloud_timeout_seconds: int = 120,
        cloud_provider: ProviderConfig | None = None,
        cloud_provider_model: str = "",
    ) -> None:
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.mode = mode
        self.source_lang = source_lang
        self.cloud_base_url = cloud_base_url.rstrip("/")
        self.cloud_endpoint = cloud_endpoint
        self.cloud_model = cloud_model
        self.cloud_env_key = cloud_env_key
        self.cloud_timeout_seconds = cloud_timeout_seconds
        self.cloud_provider = cloud_provider
        self.cloud_provider_model = cloud_provider_model
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
        if self.mode == "local":
            return self._transcribe_segment_local(audio_path, segment_start_offset)
        if self.mode == "openai":
            return self._transcribe_segment_openai(audio_path, segment_start_offset)
        raise RuntimeError(f"Unsupported ASR mode: {self.mode}")

    def _transcribe_segment_local(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
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

    def _transcribe_segment_openai(self, audio_path: Path, segment_start_offset: float) -> list[dict]:
        env_key = self.cloud_provider.env_key if self.cloud_provider else self.cloud_env_key
        api_key = os.getenv(env_key)
        if not api_key:
            raise RuntimeError(f"Missing environment variable: {env_key}")
        response = self._call_openai_transcriptions(audio_path, api_key=api_key)
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
                        "confidence": None,
                    }
                )
            return rows
        text = str(response.get("text", "")).strip()
        if not text:
            return []
        return [
            {
                "start": segment_start_offset,
                "end": segment_start_offset + 0.1,
                "text": text,
                "confidence": None,
            }
        ]

    def _call_openai_transcriptions(self, audio_path: Path, *, api_key: str) -> dict[str, Any]:
        boundary = f"----TransVortex{uuid.uuid4().hex}"
        body = self._build_multipart_body(audio_path=audio_path, boundary=boundary)
        if self.cloud_provider:
            model = self.cloud_provider_model or self.cloud_model
            url, auth_headers = _build_url_and_auth_headers(self.cloud_provider, api_key, model=model)
            method = self.cloud_provider.endpoint.method
        else:
            endpoint = self.cloud_endpoint if self.cloud_endpoint.startswith("/") else f"/{self.cloud_endpoint}"
            url = f"{self.cloud_base_url}{endpoint}"
            auth_headers = {"Authorization": f"Bearer {api_key}"}
            method = "POST"
        req = urllib.request.Request(
            url=url,
            data=body,
            method=method,
            headers={
                **auth_headers,
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
        )
        with urllib.request.urlopen(req, timeout=self.cloud_timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise RuntimeError("bad_schema: unexpected cloud ASR response")
        return payload

    def _build_multipart_body(self, *, audio_path: Path, boundary: str) -> bytes:
        def add_field(chunks: list[bytes], name: str, value: str) -> None:
            chunks.append(f"--{boundary}\r\n".encode("utf-8"))
            chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
            chunks.append(value.encode("utf-8"))
            chunks.append(b"\r\n")

        chunks: list[bytes] = []
        model = self.cloud_provider_model or self.cloud_model
        add_field(chunks, "model", model)
        add_field(chunks, "response_format", "verbose_json")
        language = _normalize_whisper_language(self.source_lang)
        if language:
            add_field(chunks, "language", language)
        add_field(chunks, "temperature", "0")

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


def _normalize_whisper_language(source_lang: str | None) -> str | None:
    if not source_lang:
        return None
    return source_lang.split("-", 1)[0].strip().lower() or None


def _build_url_and_auth_headers(config: ProviderConfig, api_key: str, *, model: str) -> tuple[str, dict[str, str]]:
    raw_path = config.endpoint.path_template.format(model=model)
    if not raw_path.startswith("/"):
        raw_path = f"/{raw_path}"
    parsed_base = urllib.parse.urlsplit(config.base_url)
    base_path = parsed_base.path or ""
    endpoint_path = raw_path
    if base_path and endpoint_path.startswith(f"{base_path}/"):
        endpoint_path = endpoint_path[len(base_path) :]
    elif base_path and endpoint_path == base_path:
        endpoint_path = "/"
    combined_path = posixpath.normpath(f"{base_path.rstrip('/')}/{endpoint_path.lstrip('/')}")
    if not combined_path.startswith("/"):
        combined_path = f"/{combined_path}"
    url = urllib.parse.urlunsplit(
        (
            parsed_base.scheme,
            parsed_base.netloc,
            combined_path,
            parsed_base.query,
            parsed_base.fragment,
        )
    )
    headers: dict[str, str] = {}
    auth = config.auth
    if auth.type == "bearer":
        headers[auth.header_name] = f"{auth.prefix}{api_key}"
    elif auth.type == "header":
        headers[auth.header_name] = f"{auth.prefix}{api_key}"
    elif auth.type == "query":
        sep = "&" if "?" in url else "?"
        q_name = urllib.parse.quote_plus(auth.query_name)
        q_val = urllib.parse.quote_plus(f"{auth.prefix}{api_key}")
        url = f"{url}{sep}{q_name}={q_val}"
    else:
        raise RuntimeError(f"Unsupported auth.type: {auth.type}")
    return url, headers


def write_segment_asr_output(path: Path, rows: list[dict]) -> None:
    write_json(path, rows)
