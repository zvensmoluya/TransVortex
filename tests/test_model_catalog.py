from __future__ import annotations

from pathlib import Path

from transvortex.app.config import load_app_config
from transvortex.app.models import CapabilityConfig, ModelConfig, ProviderConfig
from transvortex.providers.model_catalog import (
    CATALOG_VERIFIED_AT,
    model_catalog_payload,
    model_catalog_runtime_config,
    resolve_model_catalog,
)


def test_catalog_resolves_only_reviewed_exact_aliases() -> None:
    assert resolve_model_catalog("openai/gpt-5.6-terra").id == "gpt-5.6-terra"
    assert resolve_model_catalog("models/gemini-2.5-pro").id == "gemini-2.5-pro"
    assert resolve_model_catalog("anthropic/claude-haiku-4.5").id == "claude-haiku-4-5-20251001"
    assert resolve_model_catalog("gpt-5.6-terra:extended") is None
    assert resolve_model_catalog("my-gpt-5.6-terra-proxy") is None


def test_catalog_payload_separates_runtime_recommendation_and_reference_price() -> None:
    entries = {row["id"]: row for row in model_catalog_payload()}
    terra = entries["gpt-5.6-terra"]
    assert terra["max_context_tokens"] == 1_050_000
    assert terra["runtime"]["max_batch_lines"] == 240
    assert terra["pricing"]["threshold_input_tokens"] == 272_000
    assert terra["pricing"]["above_threshold_input_multiplier"] == 2.0
    assert terra["reasoning_efforts"] == ["none", "low", "medium", "high", "xhigh", "max"]
    assert terra["verified_at"] == CATALOG_VERIFIED_AT

    assert entries["gpt-5.5"]["reasoning_efforts"] == ["none", "low", "medium", "high", "xhigh"]
    assert entries["gpt-4.1"]["reasoning_efforts"] == []

    gemini = entries["gemini-2.5-pro"]
    assert gemini["pricing"]["input_per_million_usd"] == 1.25
    assert gemini["pricing"]["above_threshold_output_per_million_usd"] == 15


def test_provider_uses_catalog_between_user_override_and_provider_fallback() -> None:
    provider = ProviderConfig(
        name="gateway",
        api_type="openai-compatible",
        base_url="https://gateway.example/v1",
        env_key="KEY",
        models=["openai/gpt-5.6-terra"],
        model_configs={
            "openai/gpt-5.6-terra": ModelConfig(max_batch_lines=180),
        },
        catalog_model_configs={
            "openai/gpt-5.6-terra": ModelConfig(
                **model_catalog_runtime_config("openai/gpt-5.6-terra")
            ),
        },
        capabilities=CapabilityConfig(
            max_batch_lines=1000,
            max_context_tokens=0,
            max_output_tokens=16_384,
            recommended_output_tokens=8_192,
        ),
    )

    resolved = provider.model_config("openai/gpt-5.6-terra")
    assert resolved.max_batch_lines == 180
    assert resolved.max_context_tokens == 1_050_000
    assert resolved.max_output_tokens == 128_000
    assert provider.capabilities_for_model("openai/gpt-5.6-terra").recommended_output_tokens == 32_768


def test_config_load_attaches_catalog_without_materializing_user_overrides(tmp_path: Path) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: gateway
    api_type: openai-compatible
    compat_mode: openai_responses
    base_url: https://gateway.example/v1
    env_key: EXAMPLE_KEY
    models: [openai/gpt-5.6-terra]
    model_configs:
      openai/gpt-5.6-terra:
        max_batch_lines: 180
routing:
  primary: {provider: gateway, model: openai/gpt-5.6-terra}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")

    provider = load_app_config(root_dir=tmp_path).providers["gateway"]

    assert provider.model_configs["openai/gpt-5.6-terra"].max_batch_lines == 180
    assert provider.model_configs["openai/gpt-5.6-terra"].max_context_tokens == 0
    assert provider.model_config("openai/gpt-5.6-terra").max_context_tokens == 1_050_000
