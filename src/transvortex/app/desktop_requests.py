from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from ..utils import read_json


REQUEST_VERSION = 1

_UNSET = object()


class RequestValidationError(ValueError):
    pass


@dataclass(frozen=True)
class RunRequest:
    input: str
    source_lang: str
    target_lang: str
    request_version: int = REQUEST_VERSION
    input_type: str = "video_asr_translate"
    bilingual: bool = False
    output: str = ""
    provider: str = ""
    model: str = ""
    routing: dict[str, Any] = field(default_factory=dict)
    overrides: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ResumeRequest:
    task_id: str
    request_version: int = REQUEST_VERSION
    output: str = ""
    provider: str = ""
    model: str = ""
    routing: dict[str, Any] = field(default_factory=dict)
    overrides: dict[str, Any] = field(default_factory=dict)


def load_run_request(path: Path) -> RunRequest:
    return run_request_from_payload(_read_request_payload(path))


def load_resume_request(path: Path) -> ResumeRequest:
    return resume_request_from_payload(_read_request_payload(path))


def run_request_to_payload(request: RunRequest) -> dict[str, Any]:
    return _request_payload(request)


def resume_request_to_payload(request: ResumeRequest) -> dict[str, Any]:
    return _request_payload(request)


def _request_payload(request: RunRequest | ResumeRequest) -> dict[str, Any]:
    payload = asdict(request)
    if not payload.get("routing"):
        payload.pop("routing", None)
    return payload


def run_request_from_flags(
    *,
    input_path: str,
    input_type: str,
    source_lang: str,
    target_lang: str,
    bilingual: bool,
    output: str | None,
    provider: str | None,
    model: str | None,
    overrides: dict[str, Any],
    routing: dict[str, Any] | None = None,
) -> RunRequest:
    return RunRequest(
        input=str(Path(input_path).resolve()),
        input_type=normalize_input_type(input_type),
        source_lang=_require_text(source_lang, "source_lang"),
        target_lang=_require_text(target_lang, "target_lang"),
        bilingual=bool(bilingual),
        output=_optional_resolved_path(output),
        provider=_optional_text(provider),
        model=_optional_text(model),
        routing=_routing_payload(routing),
        overrides=_clean_overrides(overrides),
    )


def resume_request_from_flags(
    *,
    task_id: str,
    output: str | None,
    provider: str | None,
    model: str | None,
    overrides: dict[str, Any],
    routing: dict[str, Any] | None = None,
) -> ResumeRequest:
    return ResumeRequest(
        task_id=_require_text(task_id, "task_id"),
        output=_optional_resolved_path(output),
        provider=_optional_text(provider),
        model=_optional_text(model),
        routing=_routing_payload(routing),
        overrides=_clean_overrides(overrides),
    )


def run_request_from_payload(payload: dict[str, Any]) -> RunRequest:
    _validate_version(payload)
    input_path = _first(payload, "input", "input_file", "input_path")
    source_lang = _first(payload, "source_lang", "src")
    target_lang = _first(payload, "target_lang", "tgt")
    input_type = _first(payload, "input_type", default="video_asr_translate")
    output = _first(payload, "output", "output_file", default="")
    output_dir = _first(payload, "output_dir", default="")
    if not output and output_dir and input_path and target_lang:
        output = _output_file_from_dir(str(output_dir), str(input_path), str(target_lang))

    overrides = _request_overrides(payload)
    return RunRequest(
        request_version=REQUEST_VERSION,
        input=str(Path(_require_text(input_path, "input")).resolve()),
        input_type=normalize_input_type(str(input_type)),
        source_lang=_require_text(source_lang, "source_lang"),
        target_lang=_require_text(target_lang, "target_lang"),
        bilingual=_bool_value(_first(payload, "bilingual", default=False), "bilingual"),
        output=_optional_resolved_path(output),
        provider=_optional_text(_first(payload, "provider", default="")),
        model=_optional_text(_first(payload, "model", default="")),
        routing=_routing_payload(_first(payload, "routing", default=None)),
        overrides=overrides,
    )


def resume_request_from_payload(payload: dict[str, Any]) -> ResumeRequest:
    _validate_version(payload)
    overrides = _request_overrides(payload)
    return ResumeRequest(
        request_version=REQUEST_VERSION,
        task_id=_require_text(_first(payload, "task_id", "taskId"), "task_id"),
        output=_optional_resolved_path(_first(payload, "output", "output_file", default="")),
        provider=_optional_text(_first(payload, "provider", default="")),
        model=_optional_text(_first(payload, "model", default="")),
        routing=_routing_payload(_first(payload, "routing", default=None)),
        overrides=overrides,
    )


def normalize_input_type(value: str | None) -> str:
    raw = str(value or "video_asr_translate")
    if raw in {"srt", "srt_translate"}:
        return "srt_translate"
    if raw in {"segments", "segments_translate"}:
        return "segments_translate"
    if raw in {"video_asr", "video_asr_translate"}:
        return raw
    return "video_asr_translate"


def _read_request_payload(path: Path) -> dict[str, Any]:
    payload = read_json(path)
    if not isinstance(payload, dict):
        raise RequestValidationError("request JSON must be an object")
    return payload


def _validate_version(payload: dict[str, Any]) -> None:
    version = payload.get("request_version", REQUEST_VERSION)
    if version != REQUEST_VERSION:
        raise RequestValidationError(f"unsupported request_version: {version}")


def _request_overrides(payload: dict[str, Any]) -> dict[str, Any]:
    raw_overrides = payload.get("overrides")
    if raw_overrides is not None and not isinstance(raw_overrides, dict):
        raise RequestValidationError("overrides must be an object")
    overrides = dict(raw_overrides or {})
    for key, value in payload.items():
        if key in {
            "request_version",
            "input",
            "input_file",
            "input_path",
            "input_type",
            "source_lang",
            "src",
            "target_lang",
            "tgt",
            "bilingual",
            "output",
            "output_file",
            "output_dir",
            "provider",
            "model",
            "routing",
            "task_id",
            "taskId",
            "overrides",
        }:
            continue
        overrides[key] = value
    return _clean_overrides(overrides)


def _clean_overrides(overrides: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in overrides.items() if value is not None and value != ""}


def _routing_payload(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise RequestValidationError("routing must be an object")
    primary = _route_payload(
        value.get("primary", {}),
        field="routing.primary",
        required=True,
    )
    fallback_raw = value.get("fallback", [])
    if fallback_raw is None:
        fallback_raw = []
    if not isinstance(fallback_raw, list):
        raise RequestValidationError("routing.fallback must be a list")
    return {
        "primary": primary,
        "fallback": [
            _route_payload(item, field=f"routing.fallback[{idx}]", required=True)
            for idx, item in enumerate(fallback_raw)
        ],
    }


def _route_payload(
    value: Any,
    *,
    field: str,
    required: bool = False,
) -> dict[str, str]:
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise RequestValidationError(f"{field} must be an object")
    route = {
        "provider": _optional_text(_first(value, "provider", default="")),
        "model": _optional_text(_first(value, "model", default="")),
    }
    if required and (not route["provider"] or not route["model"]):
        raise RequestValidationError(
            f"{field}.provider and {field}.model are required"
        )
    return route


def _first(payload: dict[str, Any], *keys: str, default: Any = _UNSET) -> Any:
    for key in keys:
        value = payload.get(key, _UNSET)
        if value is not _UNSET:
            return value
    if default is not _UNSET:
        return default
    return None


def _require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RequestValidationError(f"{field} is required")
    return value.strip()


def _optional_text(value: Any) -> str:
    return value.strip() if isinstance(value, str) and value.strip() else ""


def _optional_resolved_path(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        return ""
    return str(Path(value).resolve())


def _bool_value(value: Any, field: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes", "on"}:
            return True
        if normalized in {"false", "0", "no", "off"}:
            return False
    raise RequestValidationError(f"{field} must be a boolean")


def _output_file_from_dir(output_dir: str, input_path: str, target_lang: str) -> str:
    stem = Path(input_path).stem or "output"
    return str((Path(output_dir) / f"{stem}.{target_lang}.srt").resolve())
