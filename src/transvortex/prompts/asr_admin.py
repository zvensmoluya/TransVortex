from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml


ASR_PROMPT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _write_yaml(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(
        yaml.safe_dump(payload, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _to_bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return default


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _validate_profile_id(profile_id: str) -> str:
    normalized = str(profile_id or "").strip().lower()
    if not ASR_PROMPT_ID_RE.fullmatch(normalized):
        raise ValueError("invalid_asr_prompt_profile_id")
    return normalized


def _prompt_path(root_dir: Path, profile_id: str, version: int) -> Path:
    path = (root_dir / "prompts" / "asr" / f"{profile_id}.v{max(1, int(version))}.md").resolve()
    prompt_root = (root_dir / "prompts" / "asr").resolve()
    if prompt_root not in path.parents:
        raise ValueError("invalid_asr_prompt_path")
    return path


def _read_prompt_text(root_dir: Path, raw_path: Any) -> str:
    text = str(raw_path or "").strip()
    if not text:
        return ""
    path = Path(text)
    resolved = (path if path.is_absolute() else root_dir / path).resolve()
    prompt_root = (root_dir / "prompts" / "asr").resolve()
    if prompt_root not in resolved.parents or not resolved.exists() or not resolved.is_file():
        return ""
    return resolved.read_text(encoding="utf-8").strip()


def _profile_payload(root_dir: Path, row: dict[str, Any], *, include_text: bool) -> dict[str, Any]:
    payload = {
        "id": str(row.get("id") or ""),
        "name": str(row.get("name") or row.get("id") or ""),
        "scope": str(row.get("scope") or "project"),
        "version": _to_int(row.get("version"), 1),
        "path": str(row.get("path") or ""),
        "include_previous_text": _to_bool(row.get("include_previous_text"), False),
        "max_chars": _to_int(row.get("max_chars"), 800),
    }
    if include_text:
        payload["text"] = _read_prompt_text(root_dir, payload["path"])
    return payload


def _asr_prompt_config(payload: dict[str, Any]) -> dict[str, Any]:
    asr = payload.setdefault("asr", {})
    if not isinstance(asr, dict):
        asr = {}
        payload["asr"] = asr
    prompt = asr.setdefault("prompt", {})
    if not isinstance(prompt, dict):
        prompt = {}
        asr["prompt"] = prompt
    return prompt


def list_asr_prompt_profiles(*, root_dir: Path, pipeline_file: Path | None = None) -> dict[str, Any]:
    pipeline_file = pipeline_file or root_dir / "pipeline.yaml"
    pipeline = _read_yaml(pipeline_file)
    prompt = _asr_prompt_config(pipeline)
    profiles = [
        _profile_payload(root_dir, row, include_text=True)
        for row in _as_list(prompt.get("profiles"))
        if isinstance(row, dict)
    ]
    return {
        "active_profile": str(prompt.get("active_profile") or ""),
        "enabled": _to_bool(prompt.get("enabled"), True),
        "profiles": profiles,
        "pipeline_file": str(pipeline_file),
    }


def save_asr_prompt_profile(
    *,
    root_dir: Path,
    profile: dict[str, Any],
    pipeline_file: Path | None = None,
) -> dict[str, Any]:
    pipeline_file = pipeline_file or root_dir / "pipeline.yaml"
    pipeline = _read_yaml(pipeline_file)
    prompt = _asr_prompt_config(pipeline)
    profile_id = _validate_profile_id(str(profile.get("id") or ""))
    profiles = [row for row in _as_list(prompt.get("profiles")) if isinstance(row, dict)]
    existing = next((row for row in profiles if str(row.get("id") or "") == profile_id), None)
    version = _to_int(profile.get("version"), _to_int(existing.get("version") if existing else None, 1))
    version = max(version, 1)
    path = _prompt_path(root_dir, profile_id, version)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(profile.get("text") or "").strip(), encoding="utf-8")
    relative_path = path.relative_to(root_dir).as_posix()
    row = {
        "id": profile_id,
        "name": str(profile.get("name") or (existing or {}).get("name") or profile_id),
        "scope": str(profile.get("scope") or (existing or {}).get("scope") or "project"),
        "version": version,
        "path": relative_path,
        "include_previous_text": _to_bool(
            profile.get("include_previous_text"),
            _to_bool((existing or {}).get("include_previous_text"), False),
        ),
        "max_chars": _to_int(profile.get("max_chars"), _to_int((existing or {}).get("max_chars"), 800)),
    }
    profiles = [item for item in profiles if str(item.get("id") or "") != profile_id]
    profiles.append(row)
    profiles.sort(key=lambda item: str(item.get("id") or ""))
    prompt["profiles"] = profiles
    prompt["enabled"] = _to_bool(profile.get("enabled"), _to_bool(prompt.get("enabled"), True))
    if _to_bool(profile.get("active"), True):
        prompt["active_profile"] = profile_id
    if prompt.get("active_profile") == profile_id:
        prompt["include_previous_text"] = row["include_previous_text"]
        prompt["max_chars"] = row["max_chars"]
    _write_yaml(pipeline_file, pipeline)
    return {
        "profile": _profile_payload(root_dir, row, include_text=True),
        "active_profile": str(prompt.get("active_profile") or ""),
        "pipeline_file": str(pipeline_file),
    }


def delete_asr_prompt_profile(
    *,
    root_dir: Path,
    profile_id: str,
    pipeline_file: Path | None = None,
) -> dict[str, Any]:
    pipeline_file = pipeline_file or root_dir / "pipeline.yaml"
    pipeline = _read_yaml(pipeline_file)
    prompt = _asr_prompt_config(pipeline)
    normalized_id = _validate_profile_id(profile_id)
    profiles = [row for row in _as_list(prompt.get("profiles")) if isinstance(row, dict)]
    removed = [row for row in profiles if str(row.get("id") or "") == normalized_id]
    kept = [row for row in profiles if str(row.get("id") or "") != normalized_id]
    prompt["profiles"] = kept
    if str(prompt.get("active_profile") or "") == normalized_id:
        prompt["active_profile"] = str(kept[0].get("id") or "") if kept else ""
    prompt_root = (root_dir / "prompts" / "asr").resolve()
    for row in removed:
        raw_path = str(row.get("path") or "")
        if not raw_path:
            continue
        path = (Path(raw_path) if Path(raw_path).is_absolute() else root_dir / raw_path).resolve()
        if prompt_root in path.parents and path.exists() and path.is_file():
            path.unlink()
    _write_yaml(pipeline_file, pipeline)
    return {
        "deleted": bool(removed),
        "active_profile": str(prompt.get("active_profile") or ""),
        "pipeline_file": str(pipeline_file),
    }
