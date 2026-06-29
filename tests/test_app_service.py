from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from transvortex.app.desktop_api import DesktopApi
from transvortex.app_service import handle_line
from transvortex.cli import main as cli_main


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
    (root / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )


def _request(method: str, params: dict | None = None, request_id: int = 1) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})


def test_app_service_ping_and_unknown_method(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    ping = handle_line(service, _request("desktop.ping"), root_dir=tmp_path)
    missing = handle_line(service, _request("missing.method"), root_dir=tmp_path)

    assert ping["result"]["ok"] is True
    assert missing["error"]["code"] == "method_not_found"


def test_app_service_invalid_json_returns_parse_error(tmp_path: Path) -> None:
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, "{bad", root_dir=tmp_path)

    assert response["id"] is None
    assert response["error"]["code"] == "parse_error"


def test_app_service_config_get_matches_cli_and_redacts_secret(tmp_path: Path, monkeypatch, capsys) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("config.get"), root_dir=tmp_path)
    monkeypatch.setattr("sys.argv", ["transvortex", "--root", str(tmp_path), "config", "show", "--json"])
    cli_main()
    cli_payload = json.loads(capsys.readouterr().out)
    raw_response = json.dumps(response, ensure_ascii=False)

    payload = response["result"]
    assert "super-secret-value" not in raw_response
    assert payload["providers"][0]["name"] == cli_payload["providers"][0]["name"]
    assert payload["providers"][0]["has_key"] is True
    assert payload["routing"]["primary"] == cli_payload["routing"]["primary"]
    assert payload["custom_adapter_template"]["id"] == "custom_json"


def test_app_service_desktop_snapshot_contains_control_plane_payloads(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)

    response = handle_line(service, _request("desktop.snapshot"), root_dir=tmp_path)

    assert "config" in response["result"]
    assert "tasks" in response["result"]
    assert "runtime" in response["result"]
    assert "environment" in response["result"]


def test_app_service_runtime_submit_and_acquire(tmp_path: Path) -> None:
    _write_config(tmp_path)
    service = DesktopApi(root_dir=tmp_path)
    request = {
        "request_version": 1,
        "input": str(tmp_path / "demo.mp4"),
        "source_lang": "en",
        "target_lang": "zh-CN",
        "provider": "p1",
        "model": "m1",
    }

    submitted = handle_line(service, _request("runtime.submitRun", {"request": request}), root_dir=tmp_path)
    acquired = handle_line(service, _request("runtime.acquireNext"), root_dir=tmp_path)

    task_id = submitted["result"]["task_id"]
    assert submitted["result"]["status"] == "QUEUED"
    assert acquired["result"]["acquired"] is True
    assert acquired["result"]["launch"]["task_id"] == task_id
    assert (tmp_path / "artifacts" / task_id / "runtime_request.json").exists()


def test_app_service_auth_list_does_not_return_secret(tmp_path: Path, monkeypatch) -> None:
    _write_config(tmp_path)
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    service = DesktopApi(root_dir=tmp_path)

    saved = handle_line(
        service,
        _request("auth.set", {"credential_id": "p1", "api_key": "secret-token"}),
        root_dir=tmp_path,
    )
    listed = handle_line(service, _request("auth.list"), root_dir=tmp_path)
    raw = json.dumps(listed, ensure_ascii=False)

    assert saved["result"]["credential_id"] == "p1"
    assert "secret-token" not in raw
    assert listed["result"]["credentials"] == [{"credential_id": "p1", "has_key": True}]


def test_app_service_subprocess_smoke(tmp_path: Path) -> None:
    _write_config(tmp_path)
    request = _request("desktop.ping") + "\n"

    proc = subprocess.run(
        [sys.executable, "-m", "transvortex.app_service", "--root", str(tmp_path)],
        input=request,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )

    payload = json.loads(proc.stdout.strip())
    assert payload["result"]["service"] == "transvortex.app_service"
    assert proc.stderr == ""
