from __future__ import annotations

import os
from pathlib import Path

from transvortex.config import load_app_config


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
    load_app_config(root_dir=tmp_path)
    assert os.getenv("TVX_MODEL_API_KEY") == "from-dotenv"


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
