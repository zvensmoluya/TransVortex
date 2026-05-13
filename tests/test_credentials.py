from __future__ import annotations

import os
import stat
from pathlib import Path

from transvortex.app.credentials import (
    auth_file_path,
    delete_auth_credential,
    read_auth_credentials,
    resolve_credential,
    write_auth_credential,
)


def test_credential_resolution_priority(tmp_path: Path, monkeypatch) -> None:
    home = tmp_path / "home"
    root = tmp_path / "project"
    root.mkdir()
    monkeypatch.setenv("TRANSVORTEX_HOME", str(home))
    (root / ".env").write_text("KEY=from-dotenv\n", encoding="utf-8")
    write_auth_credential("cred", "from-auth")

    assert resolve_credential(env_key="KEY", credential_id="cred", root_dir=root, explicit_key="explicit").source == "explicit"
    monkeypatch.setenv("KEY", "from-env")
    resolved = resolve_credential(env_key="KEY", credential_id="cred", root_dir=root)
    assert resolved.key == "from-env"
    assert resolved.source == "env"
    monkeypatch.delenv("KEY")
    resolved = resolve_credential(env_key="KEY", credential_id="cred", root_dir=root)
    assert resolved.key == "from-auth"
    assert resolved.source == "auth_json"
    delete_auth_credential("cred")
    resolved = resolve_credential(env_key="KEY", credential_id="cred", root_dir=root)
    assert resolved.key == "from-dotenv"
    assert resolved.source == "dotenv"


def test_auth_json_write_delete_and_permissions(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    path = write_auth_credential("p1", "secret")
    assert path == auth_file_path()
    assert read_auth_credentials() == {"p1": "secret"}
    if os.name != "nt":
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert delete_auth_credential("p1") is True
    assert read_auth_credentials() == {}
