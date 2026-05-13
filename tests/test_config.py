from __future__ import annotations

import os
from pathlib import Path

from transvortex.app.config import load_app_config


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
    primary: {provider: p1, model: m2}
    fallback:
      - {provider: p1, model: m1}
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.active_routing_profile == "route_2"
    assert cfg.routing.primary.model == "m2"
    assert cfg.routing.fallback[0].model == "m1"
    assert [item.name for item in cfg.routing_profiles] == ["配置 1", "配置 2"]
    assert cfg.routing_profile_next_seq == 3


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


def test_asr_cloud_config_parse(tmp_path: Path) -> None:
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
  provider: p1
  model: whisper-1
  cloud:
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: OPENAI_API_KEY
    timeout_seconds: 180
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.asr_mode == "openai"
    assert cfg.pipeline.asr_provider == "p1"
    assert cfg.pipeline.asr_provider_model == "whisper-1"
    assert cfg.pipeline.asr_cloud_model == "whisper-1"
    assert cfg.pipeline.asr_cloud_timeout_seconds == 180


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
  enabled: true
  mode: consistency_first
  inject:
    strategy: full
    proposed: false
    max_entries_per_chunk: 12
  patch:
    enabled: false
  merge:
    auto_confirm_high_confidence: true
  consistency_check:
    enabled: false
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.memory.enabled is True
    assert cfg.pipeline.memory.mode == "consistency_first"
    assert cfg.pipeline.memory.inject.strategy == "full"
    assert cfg.pipeline.memory.inject.proposed is False
    assert cfg.pipeline.memory.inject.max_entries_per_chunk == 12
    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.merge.auto_confirm_high_confidence is True
    assert cfg.pipeline.memory.consistency_check.enabled is False


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
            "subtitle_ass_style": {"font_name": "Arial", "font_size": 36, "bilingual_order": "source_target"},
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
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    cfg = load_app_config(
        root_dir=tmp_path,
        cli_overrides={
            "asr_mode": "openai",
            "asr_device": "cuda",
            "asr_model_size": "medium",
            "asr_compute_type": "float16",
            "asr_provider": "p1",
            "asr_provider_model": "whisper-large",
        },
    )
    assert cfg.pipeline.asr_mode == "openai"
    assert cfg.pipeline.asr_device == "cuda"
    assert cfg.pipeline.asr_model_size == "medium"
    assert cfg.pipeline.asr_compute_type == "float16"
    assert cfg.pipeline.asr_provider == "p1"
    assert cfg.pipeline.asr_provider_model == "whisper-large"
