from __future__ import annotations

from . import __version__


DEFAULT_USER_AGENT = f"TransVortex/{__version__}"
DEFAULT_JSON_HEADERS = {
    "Accept": "application/json",
    "User-Agent": DEFAULT_USER_AGENT,
}


def merge_default_headers(headers: dict[str, str] | None = None, **defaults: str) -> dict[str, str]:
    merged = {key: value for key, value in defaults.items() if value}
    for key, value in (headers or {}).items():
        existing_key = next((item for item in merged if item.lower() == key.lower()), None)
        if existing_key is not None:
            merged.pop(existing_key)
        merged[str(key)] = str(value)
    return merged
