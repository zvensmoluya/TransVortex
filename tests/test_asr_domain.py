from __future__ import annotations

from pathlib import Path

import pytest

from transvortex.app.asr_admin import save_asr_provider_config
from transvortex.app.asr_resolution import (
    asr_engine_to_yaml_row,
    declared_asr_capabilities,
    parse_asr_engine_spec,
    parse_asr_user_overrides,
    recommended_asr_policy,
    resolve_asr_engine,
)
from transvortex.app.config import load_app_config
from transvortex.app.credentials import resolve_provider_credential
from transvortex.asr_domain import (
    AsrAudioInputCapabilities,
    AsrCapabilities,
    AsrChunkingOverrides,
    AsrRuntimeCapabilities,
    AsrUserOverrides,
    CapabilityLimit,
    FasterWhisperWorkerEngineSpec,
    FunAsrServiceEngineSpec,
    OpenRouterAsrEngineSpec,
    resolve_asr_policy,
)


def test_faster_whisper_worker_keeps_runtime_and_model_bindings_independent() -> None:
    spec = parse_asr_engine_spec(
        {
            "id": "local_whisper",
            "type": "faster_whisper_worker",
            "runtime": {"source": "registered", "id": "runtime:custom"},
            "model": {"source": "managed", "id": "large-v3"},
            "accelerator": {"source": "registered", "id": "accelerator:cuda"},
            "device": "cuda",
        }
    )

    assert isinstance(spec, FasterWhisperWorkerEngineSpec)
    assert spec.runtime_binding.source == "registered"
    assert spec.model_binding.source == "managed"
    assert spec.accelerator_binding is not None
    assert spec.accelerator_binding.source == "registered"

    with pytest.raises(ValueError, match="id is required for a registered resource"):
        parse_asr_engine_spec(
            {
                "id": "invalid_worker",
                "type": "faster_whisper_worker",
                "runtime": {"source": "registered"},
            }
        )


def test_remote_endpoint_uses_a_secret_reference_and_rejects_secret_headers() -> None:
    spec = parse_asr_engine_spec(
        {
            "id": "openrouter_asr",
            "type": "openrouter_asr",
            "model": "openai/whisper-large-v3",
            "endpoint": {
                "credential": {
                    "binding_id": "openrouter_asr",
                    "secret_ref": "openrouter_account",
                },
                "headers": {"HTTP-Referer": "https://example.invalid"},
            },
        }
    )

    assert isinstance(spec, OpenRouterAsrEngineSpec)
    assert spec.endpoint.credential is not None
    assert spec.endpoint.credential.binding_id == "openrouter_asr"
    assert spec.endpoint.credential.secret_ref == "openrouter_account"
    assert spec.endpoint.credential.env_fallback == "OPENROUTER_API_KEY"

    with pytest.raises(ValueError, match="cannot contain credentials"):
        parse_asr_engine_spec(
            {
                "id": "bad",
                "type": "openrouter_asr",
                "model": "openai/whisper-large-v3",
                "endpoint": {"headers": {"Authorization": "secret"}},
            }
        )

    with pytest.raises(ValueError, match="cannot contain credentials"):
        parse_asr_engine_spec(
            {
                "id": "bad_cookie",
                "type": "openai_transcription",
                "model": "whisper-1",
                "endpoint": {"headers": {"Cookie": "session=example-token"}},
            }
        )

    for header in ("X-Token", "X-Auth", "X-Credential", "X-Custom-Key"):
        with pytest.raises(ValueError, match="cannot contain credentials"):
            parse_asr_engine_spec(
                {
                    "id": f"bad_{header.lower()}",
                    "type": "openai_transcription",
                    "model": "whisper-1",
                    "endpoint": {"headers": {header: "example-token"}},
                }
            )

    idempotent = parse_asr_engine_spec(
        {
            "id": "safe_header",
            "type": "openai_transcription",
            "endpoint": {"headers": {"Idempotency-Key": "request-123"}},
        }
    )
    assert idempotent.endpoint.headers == {"Idempotency-Key": "request-123"}


@pytest.mark.parametrize(
    ("engine_type", "env_key", "model"),
    [
        ("openai_transcription", "OPENAI_API_KEY", "whisper-1"),
        ("openrouter_asr", "OPENROUTER_API_KEY", "openai/whisper-large-v3"),
    ],
)
def test_custom_endpoint_cannot_inherit_official_environment_credential(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    engine_type: str,
    env_key: str,
    model: str,
) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    monkeypatch.setenv(env_key, "official-endpoint-secret")
    resolution = resolve_asr_engine(
        {
            "id": "custom_remote",
            "type": engine_type,
            "model": model,
            "endpoint": {"base_url": "https://asr.example.invalid/v1"},
        },
        root_dir=tmp_path,
    )

    assert resolution.spec.endpoint.credential is not None
    assert resolution.spec.endpoint.credential.env_fallback == ""
    assert resolution.runtime.auth.binding_id == "custom_remote"
    assert resolution.runtime.auth.env_key == ""
    assert resolve_provider_credential(resolution.runtime, root_dir=tmp_path).found is False

    with pytest.raises(ValueError, match="only allowed for its canonical official endpoint"):
        resolve_asr_engine(
            {
                "id": "unsafe_custom_remote",
                "type": engine_type,
                "model": model,
                "endpoint": {
                    "base_url": "https://asr.example.invalid/v1",
                    "credential": {
                        "binding_id": "unsafe_custom_remote",
                        "secret_ref": "unsafe_custom_remote",
                        "env_fallback": env_key,
                    },
                },
            },
            root_dir=tmp_path,
        )


def test_canonical_endpoint_uses_explicit_bound_environment_fallback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TRANSVORTEX_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("OPENAI_API_KEY", "official-openai-secret")
    resolution = resolve_asr_engine(
        {"id": "official_openai", "type": "openai_transcription"},
        root_dir=tmp_path,
    )

    lookup = resolve_provider_credential(resolution.runtime, root_dir=tmp_path)

    assert resolution.runtime.auth.binding_id == "official_openai"
    assert resolution.runtime.auth.env_key == "OPENAI_API_KEY"
    assert lookup.key == "official-openai-secret"
    assert lookup.source == "env"


def test_policy_defaults_are_constrained_by_capabilities_but_explicit_invalid_override_fails() -> None:
    spec = parse_asr_engine_spec(
        {
            "id": "openrouter_asr",
            "type": "openrouter_asr",
            "model": "openai/whisper-large-v3",
        }
    )
    capabilities = AsrCapabilities(
        audio_input=AsrAudioInputCapabilities(
            max_duration_seconds=CapabilityLimit(
                hard_max=180,
                knowledge="verified",
                source="service_probe",
            )
        ),
        runtime=AsrRuntimeCapabilities(
            max_parallelism=CapabilityLimit(
                hard_max=2,
                knowledge="verified",
                source="service_probe",
            )
        ),
    )

    resolved = resolve_asr_policy(recommended_asr_policy(spec), None, capabilities)

    assert resolved.policy.chunking.window_target_seconds == 180
    assert resolved.policy.execution.maximum_concurrency == 2
    assert {item.reason for item in resolved.adjustments} == {
        "engine_duration_limit",
        "runtime_parallelism_limit",
    }

    with pytest.raises(ValueError, match="exceeds the engine capability"):
        resolve_asr_policy(
            recommended_asr_policy(spec),
            AsrUserOverrides(
                chunking=AsrChunkingOverrides(window_target_seconds=240),
            ),
            capabilities,
        )


def test_funasr_capability_and_policy_do_not_depend_on_openrouter() -> None:
    spec = parse_asr_engine_spec(
        {
            "id": "funasr_local",
            "type": "funasr_service",
            "model": "sensevoice",
        }
    )

    assert isinstance(spec, FunAsrServiceEngineSpec)
    assert spec.endpoint.scope == "loopback"
    assert spec.endpoint.credential is None
    assert declared_asr_capabilities(spec).timeline.granularities == ("segment",)
    assert recommended_asr_policy(spec).chunking.window_target_seconds == 120


def test_engine_yaml_only_persists_intent_and_explicit_overrides(tmp_path: Path) -> None:
    raw = {
        "id": "openrouter_asr",
        "type": "openrouter_asr",
        "model": "openai/whisper-large-v3",
        "policy_overrides": {
            "execution": {"target_concurrency": 2, "maximum_concurrency": 2}
        },
    }
    resolution = resolve_asr_engine(raw, root_dir=tmp_path)

    row = asr_engine_to_yaml_row(resolution.spec, resolution.overrides)

    assert row["type"] == "openrouter_asr"
    assert row["model"] == "openai/whisper-large-v3"
    assert row["policy_overrides"] == {
        "execution": {"target_concurrency": 2, "maximum_concurrency": 2}
    }
    assert "chunking" not in row
    assert "request" not in row


def test_app_config_resolves_asr_engine_schema(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr:
  engine: funasr_local
asr_engines:
  - id: local_whisper
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
  - id: funasr_local
    type: funasr_service
    model: sensevoice
  - id: openrouter_asr
    type: openrouter_asr
    model: openai/whisper-large-v3
""".strip()
        + "\n",
        encoding="utf-8",
    )

    config = load_app_config(root_dir=tmp_path)

    assert set(config.asr_engine_specs) == {
        "local_whisper",
        "funasr_local",
        "openrouter_asr",
    }
    assert config.pipeline.asr_provider == "funasr_local"
    assert config.asr_providers["funasr_local"].protocol == "funasr_openai"
    assert config.asr_policy_resolutions["openrouter_asr"].policy.chunking.window_target_seconds == 300


def test_override_parser_rejects_transport_and_timeline_fields() -> None:
    with pytest.raises(ValueError, match="unsupported ASR chunking overrides fields"):
        parse_asr_user_overrides({"chunking": {"timeline_strategy": "custom"}})

    with pytest.raises(ValueError, match="ASR chunking mode must be one of"):
        parse_asr_user_overrides({"chunking": {"mode": "auto"}})


def test_engine_schema_requires_an_explicit_non_empty_engine_list(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        "config_schema_version: 2\nasr: {engine: local_whisper}\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="non-empty asr_engines list"):
        load_app_config(root_dir=tmp_path)


def test_remote_engine_is_not_activated_when_credential_write_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pipeline_file = tmp_path / "pipeline.yaml"
    pipeline_file.write_text(
        """
config_schema_version: 2
artifacts_dir: artifacts
asr: {engine: local_whisper}
asr_engines:
  - id: local_whisper
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
""".lstrip(),
        encoding="utf-8",
    )
    original = pipeline_file.read_text(encoding="utf-8")

    def fail_credential_write(_credential_id: str, _secret: str) -> None:
        raise OSError("credential write failed")

    monkeypatch.setattr(
        "transvortex.app.asr_admin.write_auth_credential",
        fail_credential_write,
    )

    with pytest.raises(OSError, match="credential write failed"):
        save_asr_provider_config(
            root_dir=tmp_path,
            provider_draft={
                "name": "openrouter_asr",
                "kind": "remote",
                "protocol": "openrouter_stt",
                "model": "openai/whisper-large-v3",
                "base_url": "https://openrouter.ai/api/v1",
                "auth": {"credential_id": "openrouter_asr"},
            },
            api_key="example-token",
        )

    assert pipeline_file.read_text(encoding="utf-8") == original
