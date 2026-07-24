from __future__ import annotations

import json
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from transvortex.cli import main
from transvortex.app.config import load_app_config
from transvortex.app.asr_runtime import provider_credential_fingerprint, provider_test_fingerprint
from transvortex.utils import write_json
from transvortex.protocol.agent_protocol import agent_info_payload
from transvortex.protocol.agent_setup import _safe_url, setup_plan_payload, setup_verify_payload


def _write_setup_config(root: Path) -> Path:
    (root / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  provider: managed_test
asr_providers:
  - name: managed_test
    kind: local_worker
    protocol: faster_whisper
    model: large-v3
    runtime:
      source: managed
      id: managed:faster-whisper
    local:
      model_source: managed
      device: cpu
      compute_type: int8
""".strip(),
        encoding="utf-8",
    )
    providers_file = root / "providers.yaml"
    providers_file.write_text(
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
    return providers_file


def _write_route_config(root: Path, *, kind: str, base_url: str) -> Path:
    providers_file = _write_setup_config(root)
    auth = "type: none" if kind == "local_server" else "type: bearer\n      env_key: ASR_TEST_KEY\n      credential_id: asr_test"
    (root / "pipeline.yaml").write_text(
        f"""
artifacts_dir: artifacts
asr:
  provider: route_test
asr_providers:
  - name: route_test
    kind: {kind}
    protocol: openai_transcriptions
    base_url: {base_url}
    endpoint: /audio/transcriptions
    model: whisper-1
    auth:
      {auth}
    runtime:
      source: external
      id: route:asr
""".strip(),
        encoding="utf-8",
    )
    return providers_file


def test_agent_info_advertises_read_only_setup_contract(tmp_path: Path) -> None:
    payload = agent_info_payload(root_dir=tmp_path)

    assert payload["setup_contract"]["contract"] == "transvortex.agent_setup"
    assert payload["setup_contract"]["schema_version"] == 1
    assert payload["installation"]["config_root"] == str(tmp_path.resolve())
    assert payload["installation"]["capabilities_argv"][-2:] == ["agent-info", "--json"]
    assert payload["recommended_argv"][1][-2:] == ["setup-plan", "--json"]
    assert "transvortex asr setup-plan --json" in payload["recommended_workflow"]
    assert payload["commands"]["asr setup-plan"]["read_only"] is True
    assert payload["commands"]["asr setup-verify"]["supports_strict"] is True


def test_setup_plan_is_stable_and_secret_free(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup._environment_candidates",
        lambda _snapshot: [{"id": "external:test", "source": "registered", "python_executable": "C:/Python/python.exe"}],
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["schema_version"] == 1
    assert payload["contract"] == "transvortex.agent_setup"
    assert payload["kind"] == "setup_plan"
    assert payload["ok"] is True
    assert payload["ready"] is False
    assert payload["read_only"] is True
    assert payload["network_access"] is False
    assert payload["active_asr"]["runtime_source"] == "managed"
    assert payload["active_asr"]["credential_required"] is False
    assert payload["active_asr"]["credential_configured"] is False
    assert payload["requirements"]["runtime"]["id"] == "managed:faster-whisper"
    assert payload["requirements"]["model"]["id"] == "large-v3"
    assert "global_pip_install" in payload["forbidden_actions"]
    assert "verify_sha256_before_use" in payload["allowed_actions"]
    assert payload["current"]["environment_candidates"][0]["id"] == "external:test"
    assert "super-secret-value" not in json.dumps(payload, ensure_ascii=False)


def test_setup_plan_strips_query_credentials_from_endpoint_metadata(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    catalog = {
        "schema_version": 1,
        "runtime": {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "artifact": {"url": "https://example.invalid/runtime.zip?token=secret-value"},
        },
        "accelerators": [],
        "models": [],
    }
    monkeypatch.setattr("transvortex.protocol.agent_setup.load_asr_catalog", lambda: catalog)

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["requirements"]["runtime"]["artifact"]["url"] == "https://example.invalid/runtime.zip"
    assert "secret-value" not in json.dumps(payload, ensure_ascii=False)


def test_safe_url_strips_userinfo_query_and_fragment() -> None:
    assert _safe_url("https://user:password@example.invalid/v1?token=secret#fragment") == "https://example.invalid/v1"
    assert _safe_url("/v1/audio/transcriptions?token=secret") == "/v1/audio/transcriptions"


def test_setup_verify_reports_not_ready_without_mutating(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)
    before = sorted(path.relative_to(tmp_path).as_posix() for path in tmp_path.rglob("*"))

    payload = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["kind"] == "setup_verify"
    assert payload["ok"] is False
    assert any(item["id"] == "readiness" and item["status"] == "fail" for item in payload["checks"])
    assert "integrity" in payload
    assert "model_files_sha256" in payload["integrity"]["hashes_not_checked"]
    assert any(item["id"] == "managed_model_hashes" for item in payload["checks"])
    assert any(item["code"] == "model_not_installed" for item in payload["blocking_items"])
    after = sorted(path.relative_to(tmp_path).as_posix() for path in tmp_path.rglob("*"))
    assert after == before


def test_setup_cli_nested_commands_and_legacy_asr_parser(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "transvortex.cli.entry.sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "setup-plan",
            "--providers-file",
            str(providers_file),
            "--json",
        ],
    )

    main()
    payload = json.loads(capsys.readouterr().out)
    assert payload["kind"] == "setup_plan"
    assert payload["providers_file"] == str(providers_file.resolve())


def test_setup_verify_strict_returns_nonzero(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "setup-verify",
            "--providers-file",
            str(providers_file),
            "--json",
            "--strict",
        ],
    )

    with pytest.raises(SystemExit) as exc_info:
        main()
    assert exc_info.value.code == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["kind"] == "setup_verify"
    assert payload["ok"] is False


def test_setup_plan_keeps_readiness_failures_structured(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_provider_readiness",
        lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("probe-secret-value")),
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["kind"] == "setup_plan"
    assert payload["current"]["readiness"]["code"] == "readiness_probe_failed"
    assert any(item["code"] == "readiness_probe_failed" for item in payload["blocking_items"])
    assert "probe-secret-value" not in json.dumps(payload, ensure_ascii=False)


def test_setup_verify_requires_a_remote_route_probe(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  provider: remote_test
asr_providers:
  - name: remote_test
    kind: remote
    protocol: openai_transcriptions
    base_url: https://asr.example.invalid/v1
    endpoint: /audio/transcriptions
    model: whisper-1
    auth:
      type: bearer
      env_key: ASR_TEST_KEY
      credential_id: asr_test
    runtime:
      source: external
      id: remote:asr
""".strip(),
        encoding="utf-8",
    )
    monkeypatch.setenv("ASR_TEST_KEY", "placeholder-secret")

    payload = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["ok"] is False
    route_probe = next(item for item in payload["checks"] if item["id"] == "route_probe")
    assert route_probe["code"] == "route_probe_required"
    assert "placeholder-secret" not in json.dumps(payload, ensure_ascii=False)


def test_managed_runtime_with_external_model_skips_managed_model_checks(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  provider: external_model
asr_providers:
  - name: external_model
    kind: local_worker
    protocol: faster_whisper
    model: large-v3
    runtime: {source: managed, id: managed:faster-whisper}
    local:
      model_source: external
      model_path: C:/Models/large-v3
      device: cpu
      compute_type: int8
""".strip(),
        encoding="utf-8",
    )

    plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert plan["requirements"]["runtime"] is not None
    assert plan["requirements"]["model"] is None
    assert "model_not_installed" not in {item["code"] for item in plan["blocking_items"]}
    assert "managed_model" not in {item["id"] for item in verify["checks"]}


def test_external_runtime_with_managed_model_keeps_model_checks(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr:
  provider: external_runtime
asr_providers:
  - name: external_runtime
    kind: local_worker
    protocol: faster_whisper
    model: large-v3
    runtime: {source: external, id: external:missing}
    local:
      model_source: managed
      device: cpu
      compute_type: int8
""".strip(),
        encoding="utf-8",
    )

    plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert plan["requirements"]["runtime"] is None
    assert plan["requirements"]["model"]["id"] == "large-v3"
    assert "managed_runtime" not in {item["id"] for item in verify["checks"]}
    assert "managed_model" in {item["id"] for item in verify["checks"]}


def test_malformed_catalog_stays_structured(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.load_asr_catalog",
        lambda: {"schema_version": 1, "runtime": {}, "accelerators": 1, "models": 1},
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["kind"] == "setup_plan"
    assert payload["catalog_error"] == "catalog_invalid"
    assert any(item["code"] == "catalog_invalid" for item in payload["blocking_items"])


def test_remote_route_does_not_require_managed_catalog(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_route_config(tmp_path, kind="remote", base_url="https://asr.example.invalid/v1")
    monkeypatch.setenv("ASR_TEST_KEY", "placeholder-secret")
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.load_asr_catalog",
        lambda: {"schema_version": 1, "runtime": {}, "accelerators": 1, "models": 1},
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["requirements"]["runtime"] is None
    assert payload["requirements"]["model"] is None
    assert "catalog_invalid" not in {item["code"] for item in payload["blocking_items"]}


def test_provider_test_requires_structured_remote_confirmations(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_route_config(tmp_path, kind="remote", base_url="https://asr.example.invalid/v1")
    monkeypatch.setenv("ASR_TEST_KEY", "placeholder-secret")
    monkeypatch.setattr(
        "transvortex.cli.entry.run_asr_connection_test",
        lambda *args, **kwargs: pytest.fail("probe must not run without confirmations"),
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "provider-test",
            "--providers-file",
            str(providers_file),
            "--json",
        ],
    )

    with pytest.raises(SystemExit) as exc_info:
        main()

    assert exc_info.value.code == 2
    payload = json.loads(capsys.readouterr().out)
    assert payload["kind"] == "provider_test"
    assert payload["code"] == "confirmation_required"
    assert payload["probe"]["status"] == "not_run"
    assert payload["required_confirmations"] == ["confirm-network", "confirm-media", "confirm-cost"]


def test_local_service_probe_rejects_non_loopback_endpoint(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_route_config(tmp_path, kind="local_server", base_url="https://asr.example.invalid/v1")
    monkeypatch.setattr(
        "transvortex.cli.entry.run_asr_connection_test",
        lambda *args, **kwargs: pytest.fail("non-loopback local route must not be probed"),
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "provider-test",
            "--providers-file",
            str(providers_file),
            "--confirm-network",
            "--json",
        ],
    )

    with pytest.raises(SystemExit) as exc_info:
        main()

    assert exc_info.value.code == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["code"] == "local_service_endpoint_not_loopback"


def test_remote_probe_freshness_controls_strict_verification(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_route_config(tmp_path, kind="remote", base_url="https://asr.example.invalid/v1")
    monkeypatch.setenv("ASR_TEST_KEY", "placeholder-secret")
    config = load_app_config(root_dir=tmp_path, providers_file=providers_file)
    provider = config.asr_providers["route_test"]
    fingerprint = provider_test_fingerprint(provider)
    credential_fingerprint = provider_credential_fingerprint(provider, root_dir=tmp_path)

    def state_at(checked_at: str) -> dict:
        return {
            "provider_tests": {
                fingerprint: {
                    "ok": True,
                    "code": "ready",
                    "checked_at": checked_at,
                    "credential_fingerprint": credential_fingerprint,
                    "details": {
                        "provider": provider.name,
                        "protocol": provider.protocol,
                        "model": provider.model,
                        "row_count": 1,
                        "transport": {"transport": "httpx"},
                    },
                }
            }
        }

    stale = (datetime.now(timezone.utc) - timedelta(days=2)).replace(microsecond=0).isoformat()
    monkeypatch.setattr("transvortex.protocol.agent_setup.load_asr_runtime_state", lambda _paths: state_at(stale))
    stale_plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    assert stale_plan["current"]["provider_test"]["code"] == "route_probe_stale"
    assert setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)["ok"] is False

    fresh = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    monkeypatch.setattr("transvortex.protocol.agent_setup.load_asr_runtime_state", lambda _paths: state_at(fresh))
    fresh_plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    assert fresh_plan["ready"] is True
    fresh_verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)
    assert fresh_verify["ok"] is True
    assert next(item for item in fresh_verify["checks"] if item["id"] == "route_probe")["status"] == "pass"

    monkeypatch.setenv("ASR_TEST_KEY", "replacement-secret")
    changed_plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    assert changed_plan["current"]["provider_test"]["code"] == "route_probe_credential_changed"


def test_strict_verify_rejects_marker_only_fake_runtime(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    model_bytes = b"model"
    catalog = {
        "schema_version": 1,
        "runtime": {
            "id": "managed:faster-whisper",
            "version": "1.0.0",
            "protocol_version": 1,
            "artifact": {"published": False, "url": "", "size": 0, "sha256": ""},
        },
        "accelerators": [],
        "models": [
            {
                "id": "small",
                "repository": "example/model",
                "revision": "pinned",
                "files": [
                    {
                        "path": "model.bin",
                        "size": len(model_bytes),
                        "sha256": hashlib.sha256(model_bytes).hexdigest(),
                    }
                ],
            }
        ],
    }
    catalog_path = tmp_path / "catalog.json"
    write_json(catalog_path, catalog)
    monkeypatch.setenv("TRANSVORTEX_ASR_CATALOG", str(catalog_path))
    runtime_root = tmp_path / "Components" / "faster-whisper" / "1.0.0"
    runtime_root.mkdir(parents=True)
    (runtime_root / "python.exe").write_bytes(b"")
    write_json(
        runtime_root / "component.json",
        {"id": "managed:faster-whisper", "version": "1.0.0", "protocol_version": 1, "python": "python.exe"},
    )
    model_root = tmp_path / "Models" / "faster-whisper" / "small" / "pinned"
    model_root.mkdir(parents=True)
    (model_root / "model.bin").write_bytes(model_bytes)
    write_json(model_root / "model.json", {"id": "small", "revision": "pinned"})
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr: {provider: managed_test}
asr_providers:
  - name: managed_test
    kind: local_worker
    protocol: faster_whisper
    model: small
    runtime: {source: managed, id: managed:faster-whisper}
    local: {model_source: managed, device: cpu, compute_type: int8}
""".strip(),
        encoding="utf-8",
    )

    payload = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert next(item for item in payload["checks"] if item["id"] == "managed_runtime_marker")["status"] == "pass"
    assert next(item for item in payload["checks"] if item["id"] == "managed_model_hashes")["status"] == "pass"
    assert next(item for item in payload["checks"] if item["id"] == "runtime_protocol_probe")["status"] == "fail"
    assert payload["ok"] is False
