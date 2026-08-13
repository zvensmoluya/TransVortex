from __future__ import annotations

import json
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from transvortex.cli import main
from transvortex.app.config import load_app_config
from transvortex.app.credentials import write_auth_credential
from transvortex.app.asr_runtime import provider_credential_fingerprint, provider_test_fingerprint
from transvortex.utils import write_json
from transvortex.protocol.agent_protocol import agent_info_payload
from transvortex.protocol.agent_setup import (
    _hardware_payload,
    _safe_url,
    setup_failure_payload,
    setup_plan_payload,
    setup_verify_payload,
)


def _write_setup_config(root: Path) -> Path:
    (root / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: managed_test}
asr_engines:
  - id: managed_test
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
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
    engine_type = "funasr_service" if kind == "local_server" else "openai_transcription"
    credential = "" if kind == "local_server" else "\n      credential: {binding_id: route_test, secret_ref: asr_test}"
    scope = "loopback" if kind == "local_server" else "remote"
    (root / "pipeline.yaml").write_text(
        f"""
config_schema_version: 2
artifacts_dir: artifacts
asr: {{engine: route_test}}
asr_engines:
  - id: route_test
    type: {engine_type}
    model: whisper-1
    endpoint:
      scope: {scope}
      base_url: {base_url}
      path: /audio/transcriptions{credential}
""".strip(),
        encoding="utf-8",
    )
    return providers_file


def test_agent_info_advertises_read_only_setup_contract(tmp_path: Path) -> None:
    payload = agent_info_payload(root_dir=tmp_path)

    assert payload["setup_contract"]["contract"] == "transvortex.agent_setup"
    assert payload["setup_contract"]["schema_version"] == 2
    assert payload["commands"]["asr funasr-launcher-status"]["read_only"] is True
    assert payload["commands"]["asr funasr-launcher-save"]["ownership"] == "external"
    assert payload["commands"]["asr funasr-launcher-remove"]["requires_confirmation_flag"] == "--yes"
    assert payload["setup_contract"]["supported_scopes"] == [
        "inspect",
        "prepare_model",
        "prepare_accelerator",
        "register",
        "full",
    ]
    assert payload["setup_contract"]["strict_scope"] == "full"
    assert payload["installation"]["config_root"] == str(tmp_path.resolve())
    assert payload["installation"]["capabilities_argv"][-2:] == ["agent-info", "--json"]
    assert payload["recommended_argv"][1][-4:] == ["setup-plan", "--scope", "full", "--json"]
    assert "transvortex asr setup-plan --scope <scope> --json" in payload["recommended_workflow"]
    assert payload["commands"]["asr setup-plan"]["read_only"] is True
    assert payload["commands"]["asr setup-verify"]["supports_strict"] is True
    assert payload["commands"]["asr setup-apply"]["executor"] == "transvortex"
    assert payload["commands"]["asr model-register"]["ownership"] == "external"


def test_setup_plan_is_stable_and_secret_free(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setenv("PROVIDER_KEY", "super-secret-value")
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup._environment_candidates",
        lambda _snapshot: [{"id": "external:test", "source": "registered", "python_executable": "C:/Python/python.exe"}],
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["schema_version"] == 2
    assert payload["contract"] == "transvortex.agent_setup"
    assert payload["kind"] == "setup_plan"
    assert payload["ok"] is True
    assert payload["ready"] is False
    assert payload["read_only"] is True
    assert payload["network_access"] is False
    assert payload["active_asr"]["runtime_source"] == "managed"
    assert payload["active_asr"]["requested_device"] == "cpu"
    assert payload["active_asr"]["resolved_device"] == "cpu"
    assert payload["provider_mode"] == "local_worker"
    assert payload["requested_scope"] == "full"
    assert payload["current_configuration"] == payload["active_asr"]
    assert payload["scope_policy"]["selection_authority"] == "agent"
    assert payload["scope_policy"]["current_configuration_is_target"] is False
    assert payload["selection"]["authority"] == "agent"
    assert payload["selection"]["target_locked"] is False
    assert "route" not in payload
    assert payload["active_asr"]["credential_required"] is False
    assert payload["active_asr"]["credential_configured"] is False
    assert payload["requirements"]["runtime"]["id"] == "managed:faster-whisper"
    assert payload["requirements"]["model"]["id"] == "large-v3"
    assert "invent_unadvertised_transvortex_command" in payload["forbidden_actions"]
    assert "prepare_external_model" in payload["allowed_actions"]
    assert payload["resources"]["runtime"]["product_source"] == "managed"
    assert payload["resources"]["model"]["source"] == "managed"
    assert payload["current"]["environment_candidates"][0]["id"] == "external:test"
    assert payload["agent_argv"]["register_model_cpu"][
        payload["agent_argv"]["register_model_cpu"].index("--device") + 1
    ] == "cpu"
    assert "--accelerator-root" in payload["agent_argv"]["register_model_cuda"]
    assert "--accelerator-id" in payload["agent_argv"]["register_accelerator"]
    assert "--accelerator-registration-id" in payload["agent_argv"]["activate_external_cuda"]
    assert "super-secret-value" not in json.dumps(payload, ensure_ascii=False)


def test_inspect_scope_is_machine_readable_and_forbids_mutation(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)

    plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file, scope="inspect")
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup._local_worker_probe",
        lambda *_args, **_kwargs: pytest.fail("inspect scope must not execute the local worker"),
    )
    verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file, scope="inspect")

    assert plan["requested_scope"] == "inspect"
    assert plan["scope_policy"]["permitted_mutations"] == []
    assert plan["scope_policy"]["mutation_policy"] == "forbidden"
    assert all(action["mutating"] is False for action in plan["plan"]["actions"])
    assert plan["verification"]["strict"] is False
    assert plan["scope_result"]["complete"] is False
    assert plan["scope_result"]["provisional"] is True
    assert "--scope" in plan["verification"]["argv"]
    assert "--strict" not in plan["verification"]["argv"]
    assert verify["ok"] is False
    assert verify["asr_ready"] is False
    assert verify["scope_result"]["complete"] is True
    assert verify["scope_result"]["verification_performed"] is True
    assert verify["scope_result"]["agent_report_required"] is True
    assert verify["verification_profile"] == "scope_only"
    assert verify["executes_local_code"] is False
    assert verify["integrity"]["model_files"]["status"] == "not_checked"


def test_prepare_model_scope_leaves_model_and_device_selection_to_agent(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file, scope="prepare_model")

    actions = {action["id"]: action for action in payload["plan"]["actions"]}
    managed_install = actions["install_model"]
    assert payload["current_configuration"]["model"] == "large-v3"
    assert payload["selection"]["current_configuration_is_target"] is False
    assert {item["id"] for item in payload["selection"]["model_candidates"]} == {
        "small",
        "medium",
        "large-v3",
    }
    assert payload["selection"]["device_options"] == ["cpu", "cuda", "auto"]
    assert managed_install["choice_group"] == "model_source"
    assert "<model-id>" in managed_install["argv_template"]
    assert "large-v3" not in managed_install["argv_template"]
    assert {"prepare_accelerator", "register_accelerator", "activate_accelerator"} <= set(actions)


def test_register_scope_only_advertises_existing_resource_registration(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file, scope="register")

    mutating = [action for action in payload["plan"]["actions"] if action["mutating"]]
    assert mutating
    assert {action["operation"] for action in mutating} <= {"register", "activate"}
    assert all(action["requires_network"] is False for action in mutating)
    assert "prepare_external_model" not in payload["allowed_actions"]


def test_setup_plan_reports_resolved_asr_storage_volume(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    storage_root = Path("D:/TransVortex/Resources")
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_runtime_snapshot",
        lambda _root: {
            "paths": {
                "app_data_root": "C:/Users/Test/AppData/Local/TransVortex",
                "storage_root": str(storage_root),
                "components_root": str(storage_root / "Components"),
                "models_root": str(storage_root / "Models" / "faster-whisper"),
                "downloads_root": str(storage_root / "Downloads" / "ASR"),
            },
            "storage": {
                "root": str(storage_root),
                "disk_root": "D:/",
                "selection_origin": "configured",
                "total_bytes": 1_000_000,
                "free_bytes": 750_000,
                "reserve_bytes": 100_000,
                "space_known": True,
                "writable": True,
                "can_change": True,
                "change_blocker": "",
                "config_error": "",
            },
            "runtime": {"id": "managed:faster-whisper", "installed": False},
            "accelerators": [],
            "models": [],
            "registered_models": [],
            "registered_accelerators": [],
            "environments": [],
        },
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file, scope="inspect")

    assert payload["storage"]["root"] == str(storage_root)
    assert payload["storage"]["disk_root"] == "D:/"
    assert payload["storage"]["free_bytes"] == 750_000
    assert payload["current"]["paths"]["storage_root"] == str(storage_root)
    assert "disk" not in payload["platform"]


def test_accelerator_contract_separates_configuration_availability_and_activation(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file, scope="prepare_accelerator")

    accelerator = payload["resources"]["accelerator"]
    assert accelerator["configured"] is True
    assert accelerator["available"] is False
    assert accelerator["active"] is False
    assert accelerator["state"] == "not_requested"
    assert payload["active_asr"]["configured_preferences"]["accelerator"]["id"] == "nvidia-cuda12"
    assert payload["active_asr"]["execution"]["resolved_device"] == "cpu"
    assert payload["active_asr"]["execution"]["accelerator_active"] is False
    assert "prepare_external_model" not in payload["allowed_actions"]
    assert "prepare_external_accelerator" in payload["allowed_actions"]
    action_ids = {action["id"] for action in payload["plan"]["actions"]}
    assert {"prepare_accelerator", "register_accelerator", "activate_accelerator"} <= action_ids


def test_setup_failure_keeps_scope_contract_shape(tmp_path: Path) -> None:
    payload = setup_failure_payload(kind="setup_plan", root_dir=tmp_path, scope="inspect")

    assert payload["requested_scope"] == "inspect"
    assert payload["scope_result"]["status"] == "blocked"
    assert payload["scope_policy"]["permitted_mutations"] == []
    assert payload["current_configuration"] is None
    assert payload["selection"]["authority"] == "agent"
    assert payload["storage"]["space_known"] is False


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


def test_hardware_payload_has_one_consistent_cuda_status_shape() -> None:
    direct = _hardware_payload(
        {
            "available": True,
            "device_count": 1,
            "compute_types": ["float16"],
        }
    )
    wrapped = _hardware_payload({"ok": True, "cuda": direct})

    assert direct == {
        "status": "pass",
        "available": True,
        "device_count": 1,
        "compute_types": ["float16"],
    }
    assert wrapped["status"] == "pass"
    assert wrapped["ok"] is True
    assert wrapped["cuda"] == direct


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


def test_setup_apply_cli_waits_for_managed_operation(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_setup_config(tmp_path)

    class FakeManager:
        def __init__(self, **_kwargs) -> None:
            pass

        def start_install(self, kind: str, item_id: str = "") -> dict:
            assert (kind, item_id) == ("model", "small")
            return {"id": "asr_test"}

        def wait(self, operation_id: str) -> dict:
            assert operation_id == "asr_test"
            return {"id": operation_id, "state": "completed"}

    monkeypatch.setattr("transvortex.cli.entry.AsrOperationManager", FakeManager)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "setup-apply",
            "--resource",
            "model",
            "--item-id",
            "small",
            "--providers-file",
            str(providers_file),
            "--json",
        ],
    )

    main()

    payload = json.loads(capsys.readouterr().out)
    assert payload["kind"] == "managed_apply"
    assert payload["ok"] is True
    assert payload["executor"] == "transvortex"


def test_external_resource_cli_registers_and_activates(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_setup_config(tmp_path)
    captured: dict[str, object] = {}

    def register_model(**kwargs):  # noqa: ANN003
        captured["model"] = kwargs
        return {"ok": True, "code": "ready", "model": {"id": "external:model"}}

    monkeypatch.setattr("transvortex.cli.entry.probe_external_model", register_model)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "model-register",
            "--model-path",
            str(tmp_path / "model"),
            "--label",
            "访谈模型",
            "--providers-file",
            str(providers_file),
            "--json",
        ],
    )

    main()

    model_payload = json.loads(capsys.readouterr().out)
    assert model_payload["kind"] == "model_register"
    assert model_payload["ownership"] == "external"
    assert captured["model"]["save"] is True
    assert captured["model"]["user_label"] == "访谈模型"

    def activate(**kwargs):  # noqa: ANN003
        captured["activation"] = kwargs
        return {"ok": True, "readiness": {"can_run": True}}

    monkeypatch.setattr("transvortex.cli.entry.activate_asr_resources", activate)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "resources-activate",
            "--model-registration-id",
            "external:model",
            "--device",
            "cuda",
            "--compute-type",
            "float16",
            "--providers-file",
            str(providers_file),
            "--json",
        ],
    )

    main()

    activation_payload = json.loads(capsys.readouterr().out)
    assert activation_payload["kind"] == "resources_activate"
    assert activation_payload["ok"] is True
    assert captured["activation"]["model_registration_id"] == "external:model"
    assert captured["activation"]["device"] == "cuda"
    assert captured["activation"]["compute_type"] == "float16"
    assert captured["activation"]["providers_file"] == providers_file.resolve()


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


def test_setup_verify_inspect_strict_uses_scope_completion(tmp_path: Path, monkeypatch, capsys) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "sys.argv",
        [
            "transvortex",
            "--root",
            str(tmp_path),
            "asr",
            "setup-verify",
            "--scope",
            "inspect",
            "--providers-file",
            str(providers_file),
            "--json",
            "--strict",
        ],
    )

    main()

    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False
    assert payload["scope_result"]["complete"] is True


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


def test_ready_setup_plan_does_not_repeat_resource_install_actions(
    tmp_path: Path,
    monkeypatch,
) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_provider_readiness",
        lambda *_args, **_kwargs: {
            "state": "ready",
            "code": "ready",
            "can_run": True,
            "primary_action": "",
            "checked_at": "2026-07-24T00:00:00+00:00",
            "details": {},
        },
    )
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_runtime_snapshot",
        lambda _root: {
            "paths": {},
            "runtime": {"id": "managed:faster-whisper", "installed": True},
            "accelerators": [],
            "models": [{"id": "large-v3", "installed": True}],
            "registered_models": [],
            "registered_accelerators": [],
            "environments": [],
        },
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    action_ids = {action["id"] for action in payload["plan"]["actions"]}
    assert payload["ready"] is True
    assert payload["resources"]["runtime"]["state"] == "ready"
    assert payload["resources"]["model"]["state"] == "ready"
    assert "install_runtime" not in action_ids
    assert "install_model" not in action_ids
    assert {"discover", "inspect_host_environment", "verify"} <= action_ids


def test_hardware_incompatibility_is_an_agent_action_not_a_blocked_plan(
    tmp_path: Path,
    monkeypatch,
) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: local_whisper}
asr_engines:
  - id: local_whisper
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: small}
    accelerator: {source: managed, id: nvidia-cuda12}
    device: cuda
    compute_type: float16
""".strip(),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_provider_readiness",
        lambda *_args, **_kwargs: {
            "state": "unavailable",
            "code": "hardware_incompatible",
            "can_run": False,
            "primary_action": "choose_device",
            "checked_at": "2026-07-24T00:00:00+00:00",
            "details": {},
        },
    )
    monkeypatch.setattr(
        "transvortex.protocol.agent_setup.asr_runtime_snapshot",
        lambda _root: {
            "paths": {},
            "runtime": {"id": "managed:faster-whisper", "installed": True},
            "accelerators": [{"id": "nvidia-cuda12", "installed": True}],
            "models": [{"id": "small", "installed": True}],
            "registered_models": [],
            "registered_accelerators": [],
            "environments": [],
        },
    )

    payload = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)

    action_ids = {action["id"] for action in payload["plan"]["actions"]}
    assert payload["plan_status"] == "needs_action"
    assert payload["resources"]["driver"]["state"] == "inspect"
    assert payload["resources"]["accelerator"]["state"] == "needs_verification"
    assert payload["active_asr"]["requested_device"] == "cuda"
    assert payload["active_asr"]["resolved_device"] == "cuda"
    assert payload["requirements"]["accelerator"]["dll_directories"] == [
        "nvidia/cuda_runtime/bin",
        "nvidia/cuda_nvrtc/bin",
        "nvidia/cublas/bin",
        "nvidia/cudnn/bin",
    ]
    assert payload["requirements"]["accelerator"]["packages"] == {
        "nvidia-cublas-cu12": "12.4.5.8",
        "nvidia-cuda-nvrtc-cu12": "12.4.127",
        "nvidia-cuda-runtime-cu12": "12.4.127",
        "nvidia-cudnn-cu12": "9.1.0.70",
    }
    assert "prepare_system_acceleration" in action_ids
    assert "configure_local_worker_device" in action_ids
    assert "activate_managed_accelerator" in action_ids
    assert "install_accelerator" not in action_ids
    assert "install_model" not in action_ids


def test_setup_verify_requires_a_remote_route_probe(tmp_path: Path, monkeypatch) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: remote_test}
asr_engines:
  - id: remote_test
    type: openai_transcription
    model: whisper-1
    endpoint:
      base_url: https://asr.example.invalid/v1
      path: /audio/transcriptions
      credential: {binding_id: remote_test, secret_ref: asr_test}
""".strip(),
        encoding="utf-8",
    )
    monkeypatch.setenv("ASR_TEST_KEY", "placeholder-secret")

    payload = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert payload["ok"] is False
    route_probe = next(item for item in payload["checks"] if item["id"] == "route_probe")
    assert route_probe["code"] == "route_probe_required"
    assert "placeholder-secret" not in json.dumps(payload, ensure_ascii=False)


def test_managed_runtime_with_external_model_skips_managed_model_checks(
    tmp_path: Path,
    monkeypatch,
) -> None:
    providers_file = _write_setup_config(tmp_path)
    monkeypatch.setattr(
        "transvortex.app.asr_runtime.registered_external_model",
        lambda **_kwargs: {
            "model_id": "large-v3",
            "model_path": "C:/Models/large-v3",
        },
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: external_model}
asr_engines:
  - id: external_model
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: registered, id: external:model-test}
    device: cpu
    compute_type: int8
""".strip(),
        encoding="utf-8",
    )

    plan = setup_plan_payload(root_dir=tmp_path, providers_file=providers_file)
    verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert plan["requirements"]["runtime"] is not None
    assert plan["requirements"]["model"] is None
    assert plan["provider_mode"] == "local_worker"
    assert plan["resources"]["model"]["source"] == "external"
    assert {"prepare_model", "register_model", "activate_model"} <= {
        action["id"] for action in plan["plan"]["actions"]
    }
    assert "model_not_installed" not in {item["code"] for item in plan["blocking_items"]}
    assert "managed_model" not in {item["id"] for item in verify["checks"]}


def test_external_runtime_with_managed_model_keeps_model_checks(tmp_path: Path) -> None:
    providers_file = _write_setup_config(tmp_path)
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: external_runtime}
asr_engines:
  - id: external_runtime
    type: faster_whisper_worker
    runtime: {source: registered, id: external:missing}
    model: {source: managed, id: large-v3}
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
    assert not {
        action["id"]
        for action in payload["plan"]["actions"]
        if action.get("resource") in {"runtime", "model", "accelerator", "driver"}
    }


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
            "engine-test",
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
            "engine-test",
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
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "user-data"))
    write_auth_credential("asr_test", "placeholder-secret")
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
    assert fresh_plan["ready"] is True, json.dumps(
        {
            "plan_status": fresh_plan["plan_status"],
            "blocking_items": fresh_plan["blocking_items"],
            "provider_test": fresh_plan["current"]["provider_test"],
        },
        ensure_ascii=False,
    )
    fresh_verify = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)
    assert fresh_verify["ok"] is True
    assert next(item for item in fresh_verify["checks"] if item["id"] == "route_probe")["status"] == "pass"

    write_auth_credential("asr_test", "replacement-secret")
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
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: managed_test}
asr_engines:
  - id: managed_test
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: small}
    device: cpu
    compute_type: int8
""".strip(),
        encoding="utf-8",
    )

    payload = setup_verify_payload(root_dir=tmp_path, providers_file=providers_file)

    assert next(item for item in payload["checks"] if item["id"] == "managed_runtime_marker")["status"] == "pass"
    assert next(item for item in payload["checks"] if item["id"] == "managed_model_hashes")["status"] == "pass"
    assert next(item for item in payload["checks"] if item["id"] == "runtime_protocol_probe")["status"] == "fail"
    assert payload["ok"] is False
