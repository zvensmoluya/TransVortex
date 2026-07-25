from __future__ import annotations

import os
from pathlib import Path

import pytest

from transvortex.app.config import (
    ARTIFACTS_DIR_ENV,
    CACHE_DIR_ENV,
    apply_route_overrides,
    load_app_config,
)
from transvortex.app.asr_admin import activate_asr_resources, draft_to_asr_provider_config
from transvortex.memory.plan import resolve_memory_plan


def test_config_priority_cli_over_env_over_yaml(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
chunk_seconds: 60
default_concurrency: 8
        """.strip(),
        encoding="utf-8",
    )
    monkeypatch.setenv("TVX_CHUNK_SECONDS", "45")
    cfg = load_app_config(root_dir=tmp_path, cli_overrides={"chunk_seconds": 30})
    assert cfg.pipeline.chunk_seconds == 30


def test_network_config_defaults_to_system_and_loads_local_proxy(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    pipeline = tmp_path / "pipeline.yaml"
    pipeline.write_text("artifacts_dir: artifacts\n", encoding="utf-8")

    default = load_app_config(root_dir=tmp_path)
    assert default.network.mode == "system"
    assert default.network.proxy_port == 0

    pipeline.write_text(
        "network:\n  mode: local_proxy\n  proxy_port: 7890\n",
        encoding="utf-8",
    )
    configured = load_app_config(root_dir=tmp_path)

    assert configured.network.mode == "local_proxy"
    assert configured.network.proxy_port == 7890
    assert all(provider.network == configured.network for provider in configured.providers.values())
    assert all(provider.network == configured.network for provider in configured.asr_providers.values())


@pytest.mark.parametrize(
    "network_yaml",
    [
        "network:\n  mode: unsupported\n",
        "network:\n  mode: local_proxy\n  proxy_port: 0\n",
        "network:\n  mode: local_proxy\n  proxy_port: 70000\n",
    ],
)
def test_network_config_rejects_invalid_values(tmp_path: Path, network_yaml: str) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(network_yaml, encoding="utf-8")

    with pytest.raises(ValueError, match="network|Network"):
        load_app_config(root_dir=tmp_path)


def test_external_whisper_draft_does_not_inherit_managed_runtime_id() -> None:
    provider = draft_to_asr_provider_config(
        {
            "name": "external_whisper",
            "kind": "local_worker",
            "protocol": "faster_whisper",
            "model": "small",
            "runtime": {"source": "external"},
            "local": {"device": "cpu", "compute_type": "auto"},
        }
    )

    assert provider.runtime.source == "external"
    assert provider.runtime.id == ""


def test_local_whisper_model_source_is_independent_from_runtime() -> None:
    provider = draft_to_asr_provider_config(
        {
            "name": "local_whisper",
            "kind": "local_worker",
            "protocol": "faster_whisper",
            "model": "large-v3",
            "runtime": {"source": "managed", "id": "managed:faster-whisper"},
            "accelerator": {"source": "external", "id": "external:nvidia-test"},
            "local": {
                "model_source": "external",
                "model_path": r"D:\Models\faster-whisper-large-v3",
                "device": "auto",
            },
        }
    )

    assert provider.runtime.source == "managed"
    assert provider.accelerator.source == "external"
    assert provider.accelerator.id == "external:nvidia-test"
    assert provider.local.model_source == "external"
    assert provider.local.model_path == r"D:\Models\faster-whisper-large-v3"
    assert provider.local.external_model_id == "large-v3"
    assert provider.local.external_model_path == r"D:\Models\faster-whisper-large-v3"


def test_asr_resource_activation_can_apply_local_worker_device_settings(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr: {provider: local_whisper}
asr_providers:
  - name: local_whisper
    kind: local_worker
    protocol: faster_whisper
    model: small
    runtime: {source: managed, id: managed:faster-whisper}
    local: {model_source: managed, device: auto, compute_type: auto}
""".strip(),
        encoding="utf-8",
    )

    result = activate_asr_resources(
        root_dir=tmp_path,
        device="cpu",
        compute_type="int8",
    )
    provider = load_app_config(root_dir=tmp_path).asr_providers["local_whisper"]

    assert result["ok"] is True
    assert result["device"] == "cpu"
    assert result["compute_type"] == "int8"
    assert provider.runtime.source == "managed"
    assert provider.local.device == "cpu"
    assert provider.local.compute_type == "int8"


def test_asr_resource_activation_rejects_gpu_compute_type_on_cpu(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
artifacts_dir: artifacts
asr: {provider: local_whisper}
asr_providers:
  - name: local_whisper
    kind: local_worker
    protocol: faster_whisper
    model: small
    runtime: {source: managed, id: managed:faster-whisper}
    local: {model_source: managed, device: auto, compute_type: auto}
""".strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="not compatible with CPU"):
        activate_asr_resources(
            root_dir=tmp_path,
            device="cpu",
            compute_type="float16",
        )


def test_artifacts_directory_environment_overrides_workspace_yaml(
    tmp_path: Path, monkeypatch
) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
    desktop_tasks = tmp_path / "desktop-workspace" / "Tasks"
    monkeypatch.setenv(ARTIFACTS_DIR_ENV, str(desktop_tasks))

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.artifacts_dir == desktop_tasks
    assert cfg.pipeline.cache_dir == desktop_tasks / ".cache"


def test_cache_directory_environment_is_independent_from_task_artifacts(
    tmp_path: Path, monkeypatch
) -> None:
    (tmp_path / "providers.yaml").write_text("providers: []\n", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
    desktop_tasks = tmp_path / "desktop-workspace" / "Tasks"
    desktop_cache = tmp_path / "desktop-workspace" / "Cache"
    monkeypatch.setenv(ARTIFACTS_DIR_ENV, str(desktop_tasks))
    monkeypatch.setenv(CACHE_DIR_ENV, str(desktop_cache))

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.artifacts_dir == desktop_tasks
    assert cfg.pipeline.cache_dir == desktop_cache


def test_long_context_translation_defaults(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.translation_batch_size == 120
    assert cfg.pipeline.translation.chunk_lines == 120
    assert cfg.pipeline.translation.context_before_lines == 80
    assert cfg.pipeline.translation.context_after_lines == 40
    assert cfg.pipeline.translation.chunking.mode == "capacity_aware"
    assert cfg.pipeline.translation.chunking.target_chunk_lines == 400
    assert cfg.providers["p1"].capabilities.max_batch_lines == 200
    assert cfg.providers["p1"].capabilities.max_output_tokens == 0


def test_provider_capability_output_token_fields_load_from_yaml(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
    capabilities:
      max_batch_lines: 500
      max_context_tokens: 300000
      max_input_tokens: 250000
      max_output_tokens: 65536
      recommended_output_tokens: 32768
      output_token_param: max_completion_tokens
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)
    capabilities = cfg.providers["p1"].capabilities
    assert capabilities.max_batch_lines == 500
    assert capabilities.max_context_tokens == 300000
    assert capabilities.max_input_tokens == 250000
    assert capabilities.max_output_tokens == 65536
    assert capabilities.recommended_output_tokens == 32768
    assert capabilities.output_token_param == "max_completion_tokens"


def test_model_specific_capacity_and_reasoning_load_from_yaml(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai-compatible
    compat_mode: openai_responses
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1, m2]
    capabilities:
      max_batch_lines: 1000
      max_output_tokens: 128000
      recommended_output_tokens: 32000
    model_configs:
      m1:
        max_batch_lines: 240
        max_context_tokens: 400000
        max_input_tokens: 360000
        max_output_tokens: 64000
        recommended_output_tokens: 16000
        reasoning_effort: low
      m2:
        max_output_tokens: 16000
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)
    provider = cfg.providers["p1"]
    model = provider.model_config("m1")
    capabilities = provider.capabilities_for_model("m1")

    assert model.reasoning_effort == "low"
    assert capabilities.max_batch_lines == 240
    assert capabilities.max_context_tokens == 400000
    assert capabilities.max_input_tokens == 360000
    assert capabilities.max_output_tokens == 64000
    assert capabilities.recommended_output_tokens == 16000
    assert provider.capabilities_for_model("m2").max_context_tokens == 0
    assert provider.capabilities_for_model("m2").recommended_output_tokens == 16000
    assert provider.capabilities.reasoning_effort_param == "reasoning.effort"
    assert provider.capabilities.reasoning_efforts == ["minimal", "low", "medium", "high"]


def test_translation_chunking_budget_fields_load_from_yaml(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation:
  chunking:
    input_safety_ratio: 0.75
    prompt_overhead_tokens: 900
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)
    chunking = cfg.pipeline.translation.chunking

    assert chunking.input_safety_ratio == 0.75
    assert chunking.prompt_overhead_tokens == 900


def test_translation_experiment_logging_loads_from_yaml(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation:
  experiment_logging:
    enabled: true
    save_raw_text: false
    save_metrics: true
    label: pilot
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)
    logging = cfg.pipeline.translation.experiment_logging

    assert logging.enabled is True
    assert logging.save_raw_text is False
    assert logging.save_metrics is True
    assert logging.label == "pilot"

    cfg2 = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "translation_chunking_mode": "fixed",
            "translation_experiment_logging_enabled": "false",
            "translation_experiment_label": "override",
        },
    )

    assert cfg2.pipeline.translation.chunking.mode == "fixed"
    assert cfg2.pipeline.translation.experiment_logging.enabled is False
    assert cfg2.pipeline.translation.experiment_logging.label == "override"


def test_cli_overrides_provider_limits_and_memory_patch(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
    limits:
      timeout_seconds: 30
      retry: 3
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  patch:
    enabled: true
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "provider_timeout_seconds": 90,
            "provider_retry": 5,
            "provider_http2": "false",
            "provider_streaming_enabled": "true",
            "provider_connect_timeout_seconds": 11,
            "provider_read_timeout_seconds": 77,
            "translation_batching_mode": "fixed",
            "translation_min_chunk_lines": 12,
            "memory_patch_enabled": "false",
            "memory_patch_window_chunks": 4,
        },
    )

    assert cfg.pipeline.timeout_seconds == 90
    assert cfg.pipeline.retry == 5
    assert cfg.providers["p1"].limits.timeout_seconds == 90
    assert cfg.providers["p1"].limits.retry == 5
    assert cfg.providers["p1"].limits.http2 is False
    assert cfg.providers["p1"].limits.streaming_enabled is True
    assert cfg.providers["p1"].limits.connect_timeout_seconds == 11
    assert cfg.providers["p1"].limits.read_timeout_seconds == 77
    assert cfg.pipeline.translation.batching.mode == "fixed"
    assert cfg.pipeline.translation.batching.min_chunk_lines == 12
    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.patch.window_chunks == 4


def test_memory_atomic_overrides_set_feature_switches(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  enabled: true
  bootstrap:
    enabled: true
  inject:
    enabled: true
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "memory_enabled": "false",
            "memory_bootstrap_enabled": "false",
            "memory_inject_enabled": "false",
        },
    )

    assert cfg.pipeline.memory.enabled is False
    assert cfg.pipeline.memory.bootstrap.enabled is False
    assert cfg.pipeline.memory.inject.enabled is False


def test_memory_inject_and_patch_overrides_are_validated_together(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    enabled: true
  patch:
    enabled: true
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "memory_inject_enabled": "false",
            "memory_patch_enabled": "false",
        },
    )

    assert cfg.pipeline.memory.inject.enabled is False
    assert cfg.pipeline.memory.patch.enabled is False


def test_memory_patch_defaults_disabled(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.patch.mode == "serial"
    assert cfg.pipeline.memory.patch.window_chunks == 3


def test_repository_default_auto_bootstrap_injects_memory(tmp_path: Path) -> None:
    providers_file = tmp_path / "providers.yaml"
    providers_file.write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    pipeline_file = Path(__file__).resolve().parents[1] / "pipeline.yaml"

    cfg = load_app_config(root_dir=tmp_path, providers_file=providers_file, pipeline_file=pipeline_file)

    assert cfg.pipeline.memory.enabled is True
    assert cfg.pipeline.memory.bootstrap.enabled is True
    assert cfg.pipeline.memory.inject.enabled is True
    assert cfg.pipeline.memory.inject.locked is True
    assert cfg.pipeline.memory.inject.confirmed is True
    assert cfg.pipeline.memory.inject.proposed is True
    assert cfg.pipeline.memory.inject.intensity == "high"
    assert cfg.pipeline.memory.inject.max_prompt_tokens == 2400
    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.patch.window_chunks == 3


def test_repository_default_funasr_uses_local_service_chunking(tmp_path: Path) -> None:
    providers_file = tmp_path / "providers.yaml"
    providers_file.write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    pipeline_file = Path(__file__).resolve().parents[1] / "pipeline.yaml"

    cfg = load_app_config(root_dir=tmp_path, providers_file=providers_file, pipeline_file=pipeline_file)
    provider = cfg.asr_providers["funasr_sensevoice_local"]

    assert provider.protocol == "funasr_openai"
    assert provider.chunking.mode == "fixed"
    assert provider.chunking.window_seconds == 120
    assert provider.chunking.max_window_seconds == 120
    assert provider.chunking.min_window_seconds == 1
    assert provider.chunking.overlap_seconds == 0
    assert provider.chunking.short_audio_seconds == 120
    assert provider.chunking.max_upload_mb == 64
    assert provider.chunking.fuzzy_dedupe is False


def test_desktop_product_default_uses_official_openai_whisper(tmp_path: Path) -> None:
    providers_file = tmp_path / "providers.yaml"
    providers_file.write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    pipeline_file = Path(__file__).resolve().parents[1] / "pipeline.desktop.yaml"

    cfg = load_app_config(
        root_dir=tmp_path,
        providers_file=providers_file,
        pipeline_file=pipeline_file,
    )
    provider = cfg.asr_providers["openai_whisper"]

    assert provider.kind == "remote"
    assert provider.protocol == "openai_transcriptions"
    assert provider.base_url == "https://api.openai.com/v1"
    assert provider.endpoint == "/v1/audio/transcriptions"
    assert provider.model == "whisper-1"
    assert provider.env_key == "OPENAI_API_KEY"
    assert provider.credential_id == "openai_whisper"


def test_provider_base_url_and_model_dynamic(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: custom
    api_type: openai-compatible
    base_url: https://my-proxy.example.com/api
    env_key: CUSTOM_KEY
    models: [my-model-v2]
routing:
  primary: {provider: custom, model: my-model-v2}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.providers["custom"].base_url == "https://my-proxy.example.com/api"
    assert cfg.routing.primary.model == "my-model-v2"
    assert cfg.providers["custom"].compat_mode == "openai_chat"
    assert cfg.active_routing_profile == "default"
    assert cfg.routing_profiles[0].primary.provider == "custom"


def test_routing_profiles_select_active_profile(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: KEY
    models: [m1, m2]
routing:
  active_profile: route_2
  primary: {provider: p1, model: m1}
  fallback: []
routing_profiles:
  - id: route_1
    name: 配置 1
    primary: {provider: p1, model: m1}
    fallback: []
  - id: route_2
    name: 配置 2
    primary: {provider: p1, model: m2, reasoning_effort: service_default}
    fallback:
      - {provider: p1, model: m1, reasoning_effort: none}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.active_routing_profile == "route_2"
    assert cfg.routing.primary.model == "m2"
    assert cfg.routing.primary.reasoning_effort == "service_default"
    assert cfg.routing.fallback[0].model == "m1"
    assert cfg.routing.fallback[0].reasoning_effort == "none"
    assert [item.name for item in cfg.routing_profiles] == ["配置 1", "配置 2"]
    assert cfg.routing_profile_next_seq == 3


def test_apply_route_overrides_prefers_full_routing_over_legacy_pair(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1, m2]
routing:
  primary: {provider: p1, model: m1}
  fallback:
    - {provider: p1, model: m2}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("artifacts_dir: artifacts\n", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)

    legacy = apply_route_overrides(cfg, provider_name="p1", model="legacy")
    assert legacy.routing.primary.model == "legacy"
    assert legacy.routing.fallback[0].model == "m2"

    routed = apply_route_overrides(
        cfg,
        provider_name="p1",
        model="legacy",
        routing={
            "primary": {"provider": "p1", "model": "m2"},
            "fallback": [],
        },
    )
    assert routed.routing.primary.model == "m2"
    assert routed.routing.fallback == []


def test_routing_profiles_fallback_to_first_when_active_missing(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: KEY
    models: [m1]
routing:
  active_profile: missing
routing_profiles:
  - id: route_1
    name: 配置 1
    primary: {provider: p1, model: m1}
    fallback: []
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.active_routing_profile == "route_1"
    assert cfg.routing.primary.provider == "p1"
    assert cfg.routing_profile_next_seq == 2


def test_routing_profiles_next_seq_uses_configured_monotonic_value(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: KEY
    models: [m1]
routing:
  active_profile: route_1
  next_profile_seq: 9
routing_profiles:
  - id: route_1
    name: 配置 1
    primary: {provider: p1, model: m1}
    fallback: []
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.routing_profile_next_seq == 9


def test_provider_new_schema_and_mappings(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: g1
    api_type: gemini-compatible
    compat_mode: gemini_generate_content
    base_url: https://example-gemini/v1beta
    env_key: GEMINI_KEY
    models: [gemini-x]
    auth:
      type: query
      query_name: token
    endpoint:
      path_template: /models/{model}:generateContent
      method: POST
    request_mapping:
      style: gemini_generate_content
    response_mapping:
      text_paths: ["candidates[0].content.parts[].text"]
    capabilities:
      supports_system_prompt: false
      supports_temperature: true
      max_batch_lines: 20
routing:
  primary: {provider: g1, model: gemini-x}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    p = cfg.providers["g1"]
    assert p.auth.type == "query"
    assert p.auth.query_name == "token"
    assert p.endpoint.path_template == "/models/{model}:generateContent"
    assert p.mapping.response["text_paths"][0] == "candidates[0].content.parts[].text"
    assert p.capabilities.max_batch_lines == 20


def test_vertex_express_defaults(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: vertex
    api_type: gemini-compatible
    compat_mode: vertex_express
    env_key: KEY
routing:
  primary: {provider: vertex, model: gemini-3.5-flash}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    p = cfg.providers["vertex"]
    assert p.base_url == "https://aiplatform.googleapis.com/v1"
    assert p.endpoint.path_template == "/publishers/google/models/{model}:generateContent"
    assert p.auth.type == "query"
    assert p.auth.query_name == "key"
    assert p.models[0] == "gemini-3.5-flash"
    assert "gemini-3.1-pro-preview" in p.models
    assert "gemini-2.0-flash-001" not in p.models
    assert p.model_list.path_template == ""


def test_provider_extended_schema_model_list_and_extra_headers(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: responses
    api_type: openai-compatible
    compat_mode: openai_responses
    base_url: https://example.com/v1
    env_key: KEY
    models: [gpt-x]
    extra_headers:
      X-Test: "1"
    model_list:
      path_template: /models
      method: GET
      response_paths: ["data[].id"]
routing:
  primary: {provider: responses, model: gpt-x}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    p = cfg.providers["responses"]
    assert p.endpoint.path_template == "/responses"
    assert p.mapping.response["text_paths"][0] == "output_text"
    assert p.extra_headers["X-Test"] == "1"
    assert p.model_list.response_paths == ["data[].id"]


def test_provider_request_mapping_extended_fields_round_trip(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: custom
    api_type: custom
    compat_mode: custom_json
    base_url: https://example.com/custom
    env_key: KEY
    models: [custom-model]
    endpoint:
      path_template: /translate
      method: POST
    request_mapping:
      style: custom_json
      query_params:
        api-version: "2024-01-01"
      body_template:
        model: "{{model}}"
        prompt: "{{prompt}}"
      body_overrides:
        stream: false
      body_remove_paths:
        - temperature
    response_mapping:
      text_paths: ["result.text"]
routing:
  primary: {provider: custom, model: custom-model}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    mapping = cfg.providers["custom"].mapping.request
    assert mapping["style"] == "custom_json"
    assert mapping["query_params"]["api-version"] == "2024-01-01"
    assert mapping["body_template"]["model"] == "{{model}}"
    assert mapping["body_overrides"]["stream"] is False
    assert mapping["body_remove_paths"] == ["temperature"]


def test_provider_file_priority_local_over_yaml_over_example(tmp_path: Path) -> None:
    providers_yaml = """
providers:
  - name: from_yaml
    api_type: openai
    base_url: https://yaml.example/v1
    env_key: YAML_KEY
    models: [yaml-model]
routing:
  primary: {provider: from_yaml, model: yaml-model}
    """.strip()
    providers_example = """
providers:
  - name: from_example
    api_type: openai
    base_url: https://example.example/v1
    env_key: EXAMPLE_KEY
    models: [example-model]
routing:
  primary: {provider: from_example, model: example-model}
    """.strip()
    providers_local = """
providers:
  - name: from_local
    api_type: anthropic
    base_url: https://local.example/v1
    env_key: LOCAL_KEY
    models: [local-model]
routing:
  primary: {provider: from_local, model: local-model}
    """.strip()
    (tmp_path / "providers.yaml").write_text(providers_yaml, encoding="utf-8")
    (tmp_path / "providers.example.yaml").write_text(providers_example, encoding="utf-8")
    (tmp_path / "providers.local.yaml").write_text(providers_local, encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.routing.primary.provider == "from_local"

    (tmp_path / "providers.local.yaml").unlink()
    cfg2 = load_app_config(root_dir=tmp_path)
    assert cfg2.routing.primary.provider == "from_yaml"

    (tmp_path / "providers.yaml").unlink()
    cfg3 = load_app_config(root_dir=tmp_path)
    assert cfg3.routing.primary.provider == "from_example"


def test_provider_file_cli_override_wins(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: default_file
    api_type: openai
    base_url: https://default.example/v1
    env_key: DEFAULT_KEY
    models: [m1]
routing:
  primary: {provider: default_file, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    override_path = tmp_path / "custom.providers.yaml"
    override_path.write_text(
        """
providers:
  - name: cli_file
    api_type: anthropic
    base_url: https://cli.example/v1
    env_key: CLI_KEY
    models: [m2]
routing:
  primary: {provider: cli_file, model: m2}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path, providers_file=override_path)
    assert cfg.routing.primary.provider == "cli_file"


def test_dotenv_sets_api_key_when_missing(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: TVX_MODEL_API_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    (tmp_path / ".env").write_text('TVX_MODEL_API_KEY="from-dotenv"', encoding="utf-8")
    monkeypatch.delenv("TVX_MODEL_API_KEY", raising=False)
    cfg = load_app_config(root_dir=tmp_path)
    from transvortex.app.credentials import resolve_provider_credential

    assert os.getenv("TVX_MODEL_API_KEY") is None
    resolved = resolve_provider_credential(cfg.providers["p1"], root_dir=tmp_path)
    assert resolved.key == "from-dotenv"
    assert resolved.source == "dotenv"


def test_dotenv_does_not_override_existing_env(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: TVX_MODEL_API_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    (tmp_path / ".env").write_text("TVX_MODEL_API_KEY=from-dotenv", encoding="utf-8")
    monkeypatch.setenv("TVX_MODEL_API_KEY", "from-env")
    load_app_config(root_dir=tmp_path)
    assert os.getenv("TVX_MODEL_API_KEY") == "from-env"


def test_remote_asr_provider_config_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: openai_asr
asr_providers:
  - name: openai_asr
    kind: remote
    protocol: openai_transcriptions
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    auth:
      type: bearer
      env_key: OPENAI_API_KEY
      credential_id: openai_asr
    execution:
        timeout_seconds: 180
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.asr_provider == "openai_asr"
    provider = cfg.asr_providers["openai_asr"]
    assert provider.kind == "remote"
    assert provider.protocol == "openai_transcriptions"
    assert provider.base_url == "https://api.openai.com"
    assert provider.endpoint == "/v1/audio/transcriptions"
    assert provider.model == "whisper-1"
    assert provider.auth.type == "bearer"
    assert provider.env_key == "OPENAI_API_KEY"
    assert provider.credential_id == "openai_asr"
    assert provider.execution.timeout_seconds == 180


def test_asr_providers_parse_new_schema(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    prompt_dir = tmp_path / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "show.v1.md").write_text("Use known character names.", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: openai_whisper
  audio_track: "2"
  prompt:
    enabled: true
    active_profile: show
    profiles:
      - id: show
        name: Show terms
        path: prompts/asr/show.v1.md
        max_chars: 120
    include_previous_text: false
    max_chars: 120
asr_providers:
  - name: openai_whisper
    kind: remote
    protocol: openai_transcriptions
    base_url: https://api.openai.com/v1
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    auth:
      type: bearer
      env_key: OPENAI_API_KEY
      credential_id: openai_asr
    execution:
      concurrency: 12
      adaptive_concurrency: true
      min_concurrency: 2
      max_concurrency: 12
      max_inflight_upload_mb: 256
      timeout_seconds: 180
    chunking:
      mode: silence
      max_window_seconds: 45
      min_window_seconds: 10
      overlap_seconds: 3
      max_upload_mb: 20
      silence:
        noise_db: -38
        min_silence_seconds: 0.3
        cut_padding_seconds: 0.2
    http2: false
    request:
      response_format: verbose_json
      temperature: 0.25
      timestamp_granularities: [segment, word]
      include: [logprobs]
      array_format: brackets
      extra_form_fields:
        custom_flag: yes
        custom_list: [a, b]
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.asr_provider == "openai_whisper"
    assert cfg.pipeline.asr_audio_track == "2"
    provider = cfg.asr_providers["openai_whisper"]
    assert provider.kind == "remote"
    assert provider.protocol == "openai_transcriptions"
    assert provider.base_url == "https://api.openai.com/v1"
    assert provider.endpoint == "/v1/audio/transcriptions"
    assert provider.model == "whisper-1"
    assert provider.env_key == "OPENAI_API_KEY"
    assert provider.credential_id == "openai_asr"
    assert provider.execution.concurrency == 12
    assert provider.execution.min_concurrency == 2
    assert provider.execution.max_concurrency == 12
    assert provider.execution.max_inflight_upload_mb == 256
    assert provider.execution.timeout_seconds == 180
    assert provider.chunking.mode == "silence"
    assert provider.chunking.max_window_seconds == 45
    assert provider.chunking.min_window_seconds == 10
    assert provider.chunking.overlap_seconds == 3
    assert provider.chunking.max_upload_mb == 20
    assert provider.chunking.silence.noise_db == -38
    assert provider.chunking.silence.min_silence_seconds == 0.3
    assert provider.chunking.silence.cut_padding_seconds == 0.2
    assert provider.http2 is False
    assert provider.request.response_format == "verbose_json"
    assert provider.request.temperature == 0.25
    assert provider.request.timestamp_granularities == ["segment", "word"]
    assert provider.request.include == ["logprobs"]
    assert provider.request.array_format == "brackets"
    assert provider.request.extra_form_fields == {"custom_flag": True, "custom_list": ["a", "b"]}
    assert cfg.pipeline.asr_prompt.enabled is True
    assert cfg.pipeline.asr_prompt.active_profile == "show"
    assert cfg.pipeline.asr_prompt.text == "Use known character names."
    assert cfg.pipeline.asr_prompt.include_previous_text is False
    assert cfg.pipeline.asr_prompt.max_chars == 120


def test_funasr_local_server_protocol_defaults(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: funasr_sensevoice_local
asr_providers:
  - name: funasr_sensevoice_local
    kind: local_server
    protocol: funasr_openai
    base_url: http://127.0.0.1:8899
    endpoint: /v1/audio/transcriptions
    model: sensevoice
    auth:
      type: none
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)
    provider = cfg.asr_providers["funasr_sensevoice_local"]

    assert provider.kind == "local_server"
    assert provider.protocol == "funasr_openai"
    assert provider.model == "sensevoice"
    assert provider.auth.type == "none"
    assert provider.http2 is False
    assert provider.execution.concurrency == 1
    assert provider.request.send_temperature is False
    assert provider.request.send_timestamp_granularities is False
    assert provider.request.send_prompt is False
    assert provider.request.array_format == "repeat"
    assert provider.chunking.mode == "none"
    assert provider.chunking.window_seconds == 3600
    assert provider.chunking.max_window_seconds == 3600
    assert provider.chunking.min_window_seconds == 1
    assert provider.chunking.overlap_seconds == 0
    assert provider.chunking.short_audio_seconds == 3600
    assert provider.chunking.max_upload_mb == 2048
    assert provider.chunking.fuzzy_dedupe is False


def test_asr_prompt_rejects_inline_project_text(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  prompt:
    text: "legacy text"
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match=r"Unsupported asr\.prompt field\(s\): text"):
        load_app_config(root_dir=tmp_path)


def test_asr_prompt_profile_loads_prompt_file(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    prompt_dir = tmp_path / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "anime.v1.md").write_text("Names: Subaru, Emilia", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  prompt:
    enabled: true
    active_profile: anime
    profiles:
      - id: anime
        name: Anime names
        scope: project
        version: 1
        path: prompts/asr/anime.v1.md
        include_previous_text: true
        max_chars: 224
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.asr_prompt.active_profile == "anime"
    assert cfg.pipeline.asr_prompt.text == "Names: Subaru, Emilia"
    assert cfg.pipeline.asr_prompt.include_previous_text is True
    assert cfg.pipeline.asr_prompt.max_chars == 224
    assert cfg.pipeline.asr_prompt.profiles[0].text == "Names: Subaru, Emilia"


def test_asr_prompt_cli_overrides_profile(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    prompt_dir = tmp_path / "prompts" / "asr"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "anime.v1.md").write_text("Profile prompt", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  prompt:
    active_profile: anime
    profiles:
      - id: anime
        name: Anime
        path: prompts/asr/anime.v1.md
        include_previous_text: false
        max_chars: 100
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "asr_prompt_text": "Task prompt",
            "asr_prompt_enabled": "false",
            "asr_prompt_include_previous_text": "true",
            "asr_prompt_max_chars": 80,
        },
    )

    assert cfg.pipeline.asr_prompt.active_profile == "anime"
    assert cfg.pipeline.asr_prompt.text == "Task prompt"
    assert cfg.pipeline.asr_prompt.enabled is False
    assert cfg.pipeline.asr_prompt.include_previous_text is True
    assert cfg.pipeline.asr_prompt.max_chars == 80


def test_asr_preprocessing_config_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: remote_asr
asr_providers:
  - name: remote_asr
    kind: remote
    protocol: openai_transcriptions
    preprocessing:
      trim_silence:
        enabled: false
        backend: ffmpeg_silencedetect
        noise_db: -42
        min_silence_seconds: 0.4
        keep_preroll_seconds: 0.5
        trim_trailing: false
        keep_postroll_seconds: 0.2
        min_upload_seconds: 1.2
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)
    trim = cfg.asr_providers["remote_asr"].preprocessing.trim_silence
    assert trim.enabled is False
    assert trim.backend == "ffmpeg_silencedetect"
    assert trim.noise_db == -42
    assert trim.min_silence_seconds == 0.4
    assert trim.keep_preroll_seconds == 0.5
    assert trim.trim_trailing is False
    assert trim.keep_postroll_seconds == 0.2
    assert trim.min_upload_seconds == 1.2


def test_legacy_asr_mode_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  mode: openai
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="Unsupported legacy ASR field"):
        load_app_config(root_dir=tmp_path)


def test_translation_config_nested_and_legacy_batch_alias(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation_batch_size: 33
translation:
  context_before_lines: 4
  context_after_lines: 2
  style_prompt: ""
  refusal_detection:
    enabled: false
  repair:
    enabled: true
    max_attempts: 3
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.translation_batch_size == 33
    assert cfg.pipeline.translation.chunk_lines == 33
    assert cfg.pipeline.translation.context_before_lines == 4
    assert cfg.pipeline.translation.context_after_lines == 2
    assert cfg.pipeline.translation.style_prompt == ""
    assert cfg.pipeline.translation.refusal_detection.enabled is False
    assert cfg.pipeline.translation.repair.max_attempts == 3


def test_translation_asr_uncertainty_hints_default_and_override(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation:
  asr_uncertainty_hints:
    enabled: true
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.translation.asr_uncertainty_hints.enabled is True

    cfg2 = load_app_config(root_dir=tmp_path, cli_overrides={"translation_asr_uncertainty_hints_enabled": "false"})
    assert cfg2.pipeline.translation.asr_uncertainty_hints.enabled is False


def test_prompt_files_can_override_defaults(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    prompt_dir = tmp_path / "prompts" / "user"
    prompt_dir.mkdir(parents=True)
    (prompt_dir / "translation_system.md").write_text("Custom translation system.", encoding="utf-8")
    (prompt_dir / "translation_style.md").write_text("Custom subtitle style.", encoding="utf-8")
    (prompt_dir / "memory_patch_system.md").write_text("Custom memory curator.", encoding="utf-8")
    (tmp_path / "pipeline.yaml").write_text(
        """
prompts:
  translation_system: prompts/user/translation_system.md
  translation_style: prompts/user/translation_style.md
  memory_patch_system: prompts/user/memory_patch_system.md
memory:
  enabled: true
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.translation.system_prompt == "Custom translation system."
    assert cfg.pipeline.translation.style_prompt == "Custom subtitle style."
    assert cfg.pipeline.memory.patch.system_prompt == "Custom memory curator."


def test_memory_config_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  enabled: false
  chunking:
    min_initial_chunk_lines: 96
    max_initial_chunks: 12
  inject:
    enabled: false
    intensity: max
    proposed: false
    max_prompt_tokens: 3600
    format: v2
  patch:
    enabled: false
  merge:
    auto_confirm_high_confidence: true
  consistency_check:
    enabled: false
    enforcement_policy: true
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.memory.enabled is False
    assert cfg.pipeline.memory.chunking.min_initial_chunk_lines == 96
    assert cfg.pipeline.memory.chunking.max_initial_chunks == 12
    assert cfg.pipeline.memory.inject.intensity == "max"
    assert cfg.pipeline.memory.inject.enabled is False
    assert cfg.pipeline.memory.inject.proposed is False
    assert cfg.pipeline.memory.inject.max_prompt_tokens == 3600
    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.patch.mode == "serial"
    assert cfg.pipeline.memory.merge.auto_confirm_high_confidence is True
    assert cfg.pipeline.memory.consistency_check.enabled is False
    assert not hasattr(cfg.pipeline.memory.inject, "format")
    assert not hasattr(cfg.pipeline.memory.consistency_check, "enforcement_policy")


def test_memory_inject_format_rejects_legacy_values(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    format: v1
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="Unsupported memory.inject.format: v1; only v2 is supported"):
        load_app_config(root_dir=tmp_path)


def test_memory_inject_rejects_legacy_limit_fields(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    strategy: full
    max_entries_per_chunk: 12
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="Unsupported legacy memory.inject fields"):
        load_app_config(root_dir=tmp_path)


def test_memory_inject_rejects_unknown_intensity(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    intensity: extreme
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="Unsupported memory.inject.intensity"):
        load_app_config(root_dir=tmp_path)


def test_memory_inject_rejects_none_intensity(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    intensity: none
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="Unsupported memory.inject.intensity"):
        load_app_config(root_dir=tmp_path)


def test_memory_patch_can_run_without_inject_enabled(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  inject:
    enabled: false
  patch:
    enabled: true
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)
    plan = resolve_memory_plan(cfg.pipeline.memory)

    assert cfg.pipeline.memory.inject.enabled is False
    assert cfg.pipeline.memory.patch.enabled is True
    assert plan.translates_with_memory is False
    assert plan.dynamic_updates_enabled is True


def test_memory_patch_rejects_after_each_window(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  patch:
    after_each_window: true
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="memory.patch.after_each_window is no longer supported"):
        load_app_config(root_dir=tmp_path)


def test_translation_chunking_rejects_legacy_memory_entry_tokens(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation:
  chunking:
    memory_entry_tokens: 55
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="translation.chunking.memory_entry_tokens is no longer supported"):
        load_app_config(root_dir=tmp_path)


def test_translation_batching_rejects_legacy_grow_after_successes(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
translation:
  batching:
    grow_after_successes: 3
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="translation.batching.grow_after_successes is no longer supported"):
        load_app_config(root_dir=tmp_path)


def test_memory_consistency_check_rejects_disabled_policy_switch(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  consistency_check:
    enforcement_policy: false
        """.strip(),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="set memory.consistency_check.enabled=false"):
        load_app_config(root_dir=tmp_path)


def test_memory_enabled_can_disable_memory(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  enabled: false
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.memory.enabled is False


def test_legacy_memory_workflow_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  workflow: auto_bootstrap
        """.strip(),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="memory.workflow is no longer supported"):
        load_app_config(root_dir=tmp_path)


def test_legacy_memory_mode_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
memory:
  mode: bootstrap_first
        """.strip(),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="memory.mode is no longer supported"):
        load_app_config(root_dir=tmp_path)


def test_subtitle_reflow_config_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
subtitle:
  reflow:
    enabled: true
    trigger: warn_and_fail
    batch_windows: 4
    max_windows: 9
    max_window_segments: 5
    context_before_segments: 6
    context_after_segments: 7
    max_input_chars: 12345
    max_output_replacements: 11
    memory: false
    max_attempts: 3
    allow_merge: false
    allow_drop: true
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path, cli_overrides={"subtitle_reflow_enabled": "false"})
    assert cfg.pipeline.subtitle.reflow.enabled is False
    assert cfg.pipeline.subtitle.reflow.trigger == "warn_and_fail"
    assert cfg.pipeline.subtitle.reflow.batch_windows == 4
    assert cfg.pipeline.subtitle.reflow.max_windows == 9
    assert cfg.pipeline.subtitle.reflow.max_window_segments == 5
    assert cfg.pipeline.subtitle.reflow.context_before_segments == 6
    assert cfg.pipeline.subtitle.reflow.context_after_segments == 7
    assert cfg.pipeline.subtitle.reflow.max_input_chars == 12345
    assert cfg.pipeline.subtitle.reflow.max_output_replacements == 11
    assert cfg.pipeline.subtitle.reflow.memory is False
    assert cfg.pipeline.subtitle.reflow.max_attempts == 3
    assert cfg.pipeline.subtitle.reflow.allow_merge is False
    assert cfg.pipeline.subtitle.reflow.allow_drop is True


def test_subtitle_reflow_defaults_are_conservative(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)
    reflow = cfg.pipeline.subtitle.reflow
    assert reflow.enabled is False
    assert reflow.batch_windows == 10
    assert reflow.max_windows == 30
    assert reflow.max_window_segments == 10
    assert reflow.context_before_segments == 8
    assert reflow.context_after_segments == 8
    assert reflow.max_input_chars == 60000
    assert reflow.max_output_replacements == 80
    assert reflow.memory is True
    assert reflow.max_attempts == 2


def test_translation_batch_override_updates_translation_chunk_lines(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("translation:\n  chunk_lines: 20\n", encoding="utf-8")
    monkeypatch.setenv("TVX_TRANSLATION_BATCH_SIZE", "12")
    cfg = load_app_config(root_dir=tmp_path, cli_overrides={"translation_batch_size": 7})
    assert cfg.pipeline.translation_batch_size == 7
    assert cfg.pipeline.translation.chunk_lines == 7


def test_translation_and_output_overrides_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "output_format": "both",
            "translation_style_preset": "localized",
            "translation_style_prompt": "Use punchy captions.",
            "translation_chunk_lines": 9,
            "translation_context_before_lines": 3,
            "translation_context_after_lines": 4,
            "translation_repair_enabled": "false",
            "subtitle_ass_style": {
                "font_name": "Arial",
                "font_size": 36,
                "bilingual_order": "source_target",
                "prefer_single_line": "false",
            },
        },
    )
    assert cfg.pipeline.output_format == "both"
    assert cfg.pipeline.translation.style_preset == "localized"
    assert cfg.pipeline.translation.style_prompt == "Use punchy captions."
    assert cfg.pipeline.translation.chunk_lines == 9
    assert cfg.pipeline.translation_batch_size == 9
    assert cfg.pipeline.translation.context_before_lines == 3
    assert cfg.pipeline.translation.context_after_lines == 4
    assert cfg.pipeline.translation.repair.enabled is False
    assert cfg.pipeline.subtitle_ass_style.font_name == "Arial"
    assert cfg.pipeline.subtitle_ass_style.font_size == 36
    assert cfg.pipeline.subtitle_ass_style.bilingual_order == "source_target"
    assert cfg.pipeline.subtitle_ass_style.prefer_single_line is False
    assert getattr(cfg.pipeline.subtitle_ass_style, "_explicit_fields") >= {
        "font_name",
        "font_size",
        "bilingual_order",
        "prefer_single_line",
    }


def test_cli_asr_overrides_parse(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  provider: remote_asr
asr_providers:
  - name: remote_asr
    kind: remote
    protocol: openai_transcriptions
    model: whisper-1
    base_url: https://asr.example.com
    auth:
      type: bearer
      env_key: ASR_API_KEY
      credential_id: asr
    execution:
      concurrency: 2
      max_concurrency: 2
      timeout_seconds: 120
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "asr_provider": "remote_asr",
            "asr_model": "whisper-large",
            "source_mode": "embedded_subtitle",
            "subtitle_track": "3",
        },
    )
    assert cfg.pipeline.asr_provider == "remote_asr"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].kind == "remote"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].model == "whisper-large"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].base_url == "https://asr.example.com"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].credential_id == "asr"
    assert cfg.pipeline.source_mode == "embedded_subtitle"
    assert cfg.pipeline.subtitle_track == "3"


def test_asr_chunking_defaults(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: EXAMPLE_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    cfg = load_app_config(root_dir=tmp_path)

    provider = cfg.asr_providers[cfg.pipeline.asr_provider]
    assert provider.name == "faster_whisper_large_v3"
    assert provider.kind == "local_worker"
    assert provider.protocol == "faster_whisper"
    assert provider.runtime.source == "managed"
    assert provider.runtime.id == "managed:faster-whisper"
    assert provider.local.model_size == "large-v3"
    assert provider.local.device == "auto"
    assert provider.local.compute_type == "auto"
    assert provider.local.max_initial_timestamp == 30.0
    assert provider.local.beam_size == 5
    assert provider.local.temperature == 0.0
    assert provider.local.condition_on_previous_text is False
    assert provider.local.hotwords == ""
    assert provider.chunking.mode == "silence"
    assert provider.chunking.window_seconds == 300
    assert provider.chunking.max_window_seconds == 120
    assert provider.chunking.min_window_seconds == 12
    assert provider.chunking.overlap_seconds == 5
    assert provider.chunking.short_audio_seconds == 300
    assert provider.chunking.max_upload_mb == 24.0
    assert provider.chunking.silence.noise_db == -35.0
    assert provider.execution.concurrency == 1
    assert provider.execution.adaptive_concurrency is False
    assert cfg.pipeline.asr_audio_track == "auto"
    assert provider.chunking.fuzzy_dedupe is True
    assert cfg.pipeline.source_mode == "auto"
    assert cfg.pipeline.subtitle_track == "auto"
