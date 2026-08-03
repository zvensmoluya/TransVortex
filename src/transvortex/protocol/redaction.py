from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any


REDACTED = "***REDACTED***"
MIN_ENV_SECRET_VALUE_LENGTH = 8
SENSITIVE_FIELD_NAMES = {
    "api_key",
    "apikey",
    "key",
    "token",
    "access_token",
    "refresh_token",
    "secret",
    "password",
    "authorization",
    "x-api-key",
    "x_api_key",
}
SECRET_ENV_NAME_RE = re.compile(r"(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|AUTHORIZATION)", re.IGNORECASE)
COMMON_SECRET_PATTERNS = [
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", re.IGNORECASE),
    re.compile(r"\bsk-[A-Za-z0-9._-]{8,}"),
    re.compile(r"(?i)([?&](?:key|api_key|token|access_token)=)([^&\s]+)"),
]


def _dotenv_values(root_dir: Path | None) -> list[str]:
    if root_dir is None:
        return []
    dotenv = root_dir / ".env"
    if not dotenv.exists():
        return []
    values: list[str] = []
    for raw in dotenv.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if not SECRET_ENV_NAME_RE.search(key):
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if value:
            values.append(value)
    return values


def collect_secret_values(root_dir: Path | None = None) -> list[str]:
    values: list[str] = []
    for name, value in os.environ.items():
        if value and SECRET_ENV_NAME_RE.search(name):
            values.append(value)
    values.extend(_dotenv_values(root_dir))
    out: list[str] = []
    for value in values:
        # Environment-derived values are replaced as raw substrings. Short,
        # common values such as "root" are too ambiguous for that strategy:
        # they can corrupt paths and CLI flags. Structured sensitive fields
        # and recognizable secret formats are still redacted independently.
        if len(value) < MIN_ENV_SECRET_VALUE_LENGTH:
            continue
        if value not in out:
            out.append(value)
    out.sort(key=len, reverse=True)
    return out


def _redact_string(value: str, secrets: list[str]) -> str:
    redacted = value
    for secret in secrets:
        redacted = redacted.replace(secret, REDACTED)
    redacted = COMMON_SECRET_PATTERNS[0].sub(f"Bearer {REDACTED}", redacted)
    redacted = COMMON_SECRET_PATTERNS[1].sub(REDACTED, redacted)
    redacted = COMMON_SECRET_PATTERNS[2].sub(lambda match: f"{match.group(1)}{REDACTED}", redacted)
    return redacted


def redact(value: Any, *, root_dir: Path | None = None, secrets: list[str] | None = None) -> Any:
    active_secrets = collect_secret_values(root_dir) if secrets is None else secrets
    if isinstance(value, str):
        return _redact_string(value, active_secrets)
    if isinstance(value, dict):
        out: dict[Any, Any] = {}
        for key, item in value.items():
            key_text = str(key).strip().lower()
            if key_text in SENSITIVE_FIELD_NAMES:
                out[key] = REDACTED if item not in {None, ""} else item
            else:
                out[key] = redact(item, root_dir=root_dir, secrets=active_secrets)
        return out
    if isinstance(value, list):
        return [redact(item, root_dir=root_dir, secrets=active_secrets) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item, root_dir=root_dir, secrets=active_secrets) for item in value)
    return value
