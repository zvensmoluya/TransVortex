from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any


AUTH_FILE_VERSION = 1


@dataclass(frozen=True)
class CredentialLookup:
    key: str
    source: str
    credential_id: str
    env_key: str

    @property
    def found(self) -> bool:
        return bool(self.key)


def transvortex_home() -> Path:
    raw = os.getenv("TRANSVORTEX_HOME")
    if raw and raw.strip():
        return Path(raw).expanduser()
    return Path.home() / ".transvortex"


def auth_file_path(home: Path | None = None) -> Path:
    return (home or transvortex_home()) / "auth.json"


def provider_credential_id(provider: Any) -> str:
    credential_id = str(getattr(provider, "credential_id", "") or "").strip()
    if credential_id:
        return credential_id
    return str(getattr(provider, "name", "") or "").strip()


def read_dotenv_values(root_dir: Path) -> dict[str, str]:
    dotenv_file = root_dir / ".env"
    if not dotenv_file.exists():
        return {}
    values: dict[str, str] = {}
    for raw in dotenv_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value
    return values


def _read_auth_payload(path: Path | None = None) -> dict[str, Any]:
    path = path or auth_file_path()
    if not path.exists():
        return {"version": AUTH_FILE_VERSION, "credentials": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return {"version": AUTH_FILE_VERSION, "credentials": {}}
    credentials = data.get("credentials")
    if isinstance(credentials, dict):
        return {"version": data.get("version", AUTH_FILE_VERSION), "credentials": credentials}
    # Compatibility with an early flat auth.json shape.
    flat = {str(k): str(v) for k, v in data.items() if isinstance(v, str)}
    return {"version": AUTH_FILE_VERSION, "credentials": flat}


def read_auth_credentials(path: Path | None = None) -> dict[str, str]:
    payload = _read_auth_payload(path)
    credentials = payload.get("credentials")
    if not isinstance(credentials, dict):
        return {}
    return {str(k): str(v) for k, v in credentials.items() if isinstance(v, str) and v}


def _secure_created_file(path: Path) -> None:
    if os.name == "nt":
        return
    try:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def _secure_created_dir(path: Path) -> None:
    if os.name == "nt":
        return
    try:
        path.chmod(stat.S_IRWXU)
    except OSError:
        pass


def write_auth_credential(credential_id: str, value: str, *, path: Path | None = None) -> Path:
    credential_id = credential_id.strip()
    if not credential_id:
        raise ValueError("credential_id is required")
    if not value:
        raise ValueError("credential value is required")
    path = path or auth_file_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    _secure_created_dir(path.parent)
    credentials = read_auth_credentials(path)
    credentials[credential_id] = value
    payload = {"version": AUTH_FILE_VERSION, "credentials": dict(sorted(credentials.items()))}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    _secure_created_file(path)
    return path


def delete_auth_credential(credential_id: str, *, path: Path | None = None) -> bool:
    credential_id = credential_id.strip()
    path = path or auth_file_path()
    credentials = read_auth_credentials(path)
    existed = credential_id in credentials
    if existed:
        credentials.pop(credential_id, None)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": AUTH_FILE_VERSION, "credentials": dict(sorted(credentials.items()))}
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        _secure_created_file(path)
    return existed


def auth_file_permission_warning(path: Path | None = None) -> str:
    if os.name == "nt":
        return ""
    path = path or auth_file_path()
    if not path.exists():
        return ""
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError:
        return ""
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        return f"{path} is readable or writable by group/others"
    return ""


def resolve_credential(
    *,
    env_key: str,
    credential_id: str,
    provider_name: str = "",
    root_dir: Path | None = None,
    explicit_key: str | None = None,
) -> CredentialLookup:
    env_key = env_key.strip()
    credential_id = credential_id.strip()
    provider_name = provider_name.strip()
    if explicit_key:
        return CredentialLookup(explicit_key, "explicit", credential_id, env_key)
    if env_key and os.getenv(env_key):
        return CredentialLookup(os.environ[env_key], "env", credential_id, env_key)
    credentials = read_auth_credentials()
    if credential_id and credentials.get(credential_id):
        return CredentialLookup(credentials[credential_id], "auth_json", credential_id, env_key)
    if provider_name and provider_name != credential_id and credentials.get(provider_name):
        return CredentialLookup(credentials[provider_name], "auth_json", provider_name, env_key)
    if root_dir is not None and env_key:
        dotenv_values = read_dotenv_values(root_dir)
        if dotenv_values.get(env_key):
            return CredentialLookup(dotenv_values[env_key], "dotenv", credential_id, env_key)
    return CredentialLookup("", "missing", credential_id, env_key)


def resolve_provider_credential(provider: Any, *, root_dir: Path | None = None, explicit_key: str | None = None) -> CredentialLookup:
    credential_id = provider_credential_id(provider)
    return resolve_credential(
        env_key=str(getattr(provider, "env_key", "") or ""),
        credential_id=credential_id,
        provider_name=str(getattr(provider, "name", "") or ""),
        root_dir=root_dir,
        explicit_key=explicit_key,
    )
