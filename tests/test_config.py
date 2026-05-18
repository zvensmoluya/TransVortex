from __future__ import annotations

import os
from pathlib import Path

import pytest

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
    assert capabilities.max_output_tokens == 65536
    assert capabilities.recommended_output_tokens == 32768
    assert capabilities.output_token_param == "max_completion_tokens"


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
  enabled: true
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
    assert cfg.pipeline.memory.patch.after_each_window is False
    assert cfg.pipeline.memory.patch.window_chunks == 4


def test_memory_patch_enabled_implies_after_each_window(tmp_path: Path) -> None:
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
    enabled: true
        """.strip(),
        encoding="utf-8",
    )

    cfg = load_app_config(root_dir=tmp_path)

    assert cfg.pipeline.memory.patch.enabled is True
    assert cfg.pipeline.memory.patch.after_each_window is True


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
    assert cfg.pipeline.memory.patch.after_each_window is False


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
  mode: cloud
  cloud:
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: OPENAI_API_KEY
    credential_id: openai_asr
    timeout_seconds: 180
        """.strip(),
        encoding="utf-8",
    )
    cfg = load_app_config(root_dir=tmp_path)
    assert cfg.pipeline.asr_mode == "cloud"
    assert cfg.pipeline.asr_cloud.base_url == "https://api.openai.com"
    assert cfg.pipeline.asr_cloud.endpoint == "/v1/audio/transcriptions"
    assert cfg.pipeline.asr_cloud.model == "whisper-1"
    assert cfg.pipeline.asr_cloud.env_key == "OPENAI_API_KEY"
    assert cfg.pipeline.asr_cloud.credential_id == "openai_asr"
    assert cfg.pipeline.asr_cloud.timeout_seconds == 180
    assert cfg.pipeline.asr_provider == "openai_whisper_legacy"
    assert cfg.asr_providers["openai_whisper_legacy"].base_url == "https://api.openai.com"
    assert cfg.asr_providers["openai_whisper_legacy"].credential_id == "openai_asr"


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
    (tmp_path / "pipeline.yaml").write_text(
        """
asr:
  mode: cloud
  provider: openai_whisper
  audio_track: "2"
  execution:
    cloud_concurrency: 12
    adaptive_concurrency: true
    min_cloud_concurrency: 2
    max_cloud_concurrency: 12
    max_inflight_upload_mb: 256
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
  prompt:
    enabled: true
    text: "Use known character names."
    include_previous_text: false
    max_chars: 120
asr_providers:
  - name: openai_whisper
    protocol: openai_transcriptions
    base_url: https://api.openai.com/v1
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: OPENAI_API_KEY
    credential_id: openai_asr
    timeout_seconds: 180
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

    assert cfg.pipeline.asr_mode == "cloud"
    assert cfg.pipeline.asr_provider == "openai_whisper"
    assert cfg.pipeline.asr_audio_track == "2"
    assert cfg.pipeline.asr_execution.cloud_concurrency == 12
    assert cfg.pipeline.asr_execution.min_cloud_concurrency == 2
    assert cfg.pipeline.asr_execution.max_cloud_concurrency == 12
    assert cfg.pipeline.asr_execution.max_inflight_upload_mb == 256
    assert cfg.pipeline.asr_chunking.mode == "silence"
    assert cfg.pipeline.asr_chunking.max_window_seconds == 45
    assert cfg.pipeline.asr_chunking.min_window_seconds == 10
    assert cfg.pipeline.asr_chunking.overlap_seconds == 3
    assert cfg.pipeline.asr_chunking.max_upload_mb == 20
    assert cfg.pipeline.asr_chunking.silence.noise_db == -38
    assert cfg.pipeline.asr_chunking.silence.min_silence_seconds == 0.3
    assert cfg.pipeline.asr_chunking.silence.cut_padding_seconds == 0.2
    provider = cfg.asr_providers["openai_whisper"]
    assert provider.protocol == "openai_transcriptions"
    assert provider.base_url == "https://api.openai.com/v1"
    assert provider.endpoint == "/v1/audio/transcriptions"
    assert provider.model == "whisper-1"
    assert provider.env_key == "OPENAI_API_KEY"
    assert provider.credential_id == "openai_asr"
    assert provider.timeout_seconds == 180
    assert provider.request.response_format == "verbose_json"
    assert provider.request.temperature == 0.25
    assert provider.request.timestamp_granularities == ["segment", "word"]
    assert provider.request.include == ["logprobs"]
    assert provider.request.array_format == "brackets"
    assert provider.request.extra_form_fields == {"custom_flag": True, "custom_list": ["a", "b"]}
    assert cfg.pipeline.asr_prompt.enabled is True
    assert cfg.pipeline.asr_prompt.text == "Use known character names."
    assert cfg.pipeline.asr_prompt.include_previous_text is False
    assert cfg.pipeline.asr_prompt.max_chars == 120


def test_asr_prompt_profile_overrides_legacy_text(tmp_path: Path) -> None:
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
    text: "legacy text"
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

    assert cfg.pipeline.asr_prompt.active_profile == ""
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
  preprocessing:
    cloud_trim_silence:
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
    trim = cfg.pipeline.asr_preprocessing.cloud_trim_silence
    assert trim.enabled is False
    assert trim.backend == "ffmpeg_silencedetect"
    assert trim.noise_db == -42
    assert trim.min_silence_seconds == 0.4
    assert trim.keep_preroll_seconds == 0.5
    assert trim.trim_trailing is False
    assert trim.keep_postroll_seconds == 0.2
    assert trim.min_upload_seconds == 1.2


def test_asr_mode_rejects_legacy_openai_value(tmp_path: Path) -> None:
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

    with pytest.raises(ValueError, match="Unsupported asr.mode: openai"):
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
  enabled: true
  mode: consistency_first
  chunking:
    min_initial_chunk_lines: 96
    max_initial_chunks: 12
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
    assert cfg.pipeline.memory.chunking.min_initial_chunk_lines == 96
    assert cfg.pipeline.memory.chunking.max_initial_chunks == 12
    assert cfg.pipeline.memory.inject.strategy == "full"
    assert cfg.pipeline.memory.inject.proposed is False
    assert cfg.pipeline.memory.inject.max_entries_per_chunk == 12
    assert cfg.pipeline.memory.patch.enabled is False
    assert cfg.pipeline.memory.patch.after_each_window is False
    assert cfg.pipeline.memory.merge.auto_confirm_high_confidence is True
    assert cfg.pipeline.memory.consistency_check.enabled is False


def test_memory_enabled_cli_override(tmp_path: Path) -> None:
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
    cfg = load_app_config(root_dir=tmp_path, cli_overrides={"memory_enabled": "true"})
    assert cfg.pipeline.memory.enabled is True


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
            "asr_mode": "cloud",
            "asr_device": "cuda",
            "asr_model_size": "medium",
            "asr_compute_type": "float16",
            "asr_max_initial_timestamp": 8.5,
            "asr_cloud_model": "whisper-large",
            "asr_cloud_base_url": "https://asr.example.com",
            "asr_cloud_endpoint": "/v1/audio/transcriptions",
            "asr_cloud_env_key": "ASR_API_KEY",
            "asr_cloud_credential_id": "asr",
            "asr_cloud_timeout_seconds": 240,
            "asr_chunking_mode": "fixed",
            "asr_window_seconds": 420,
            "asr_overlap_seconds": 45,
            "asr_max_upload_mb": 16,
            "source_mode": "embedded_subtitle",
            "subtitle_track": "3",
        },
    )
    assert cfg.pipeline.asr_mode == "cloud"
    assert cfg.pipeline.asr_local.device == "cuda"
    assert cfg.pipeline.asr_local.model_size == "medium"
    assert cfg.pipeline.asr_local.compute_type == "float16"
    assert cfg.pipeline.asr_local.max_initial_timestamp == 8.5
    assert cfg.pipeline.asr_cloud.model == "whisper-large"
    assert cfg.pipeline.asr_cloud.base_url == "https://asr.example.com"
    assert cfg.pipeline.asr_cloud.endpoint == "/v1/audio/transcriptions"
    assert cfg.pipeline.asr_cloud.env_key == "ASR_API_KEY"
    assert cfg.pipeline.asr_cloud.credential_id == "asr"
    assert cfg.pipeline.asr_cloud.timeout_seconds == 240
    assert cfg.asr_providers[cfg.pipeline.asr_provider].model == "whisper-large"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].base_url == "https://asr.example.com"
    assert cfg.asr_providers[cfg.pipeline.asr_provider].credential_id == "asr"
    assert cfg.pipeline.asr_chunking.mode == "fixed"
    assert cfg.pipeline.asr_chunking.window_seconds == 420
    assert cfg.pipeline.asr_chunking.overlap_seconds == 45
    assert cfg.pipeline.asr_chunking.max_upload_mb == 16.0
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

    assert cfg.pipeline.asr_local.device == "auto"
    assert cfg.pipeline.asr_local.max_initial_timestamp == 30.0
    assert cfg.pipeline.asr_chunking.mode == "silence"
    assert cfg.pipeline.asr_chunking.window_seconds == 300
    assert cfg.pipeline.asr_chunking.max_window_seconds == 120
    assert cfg.pipeline.asr_chunking.min_window_seconds == 12
    assert cfg.pipeline.asr_chunking.overlap_seconds == 5
    assert cfg.pipeline.asr_chunking.short_audio_seconds == 300
    assert cfg.pipeline.asr_chunking.max_upload_mb == 24.0
    assert cfg.pipeline.asr_chunking.silence.noise_db == -35.0
    assert cfg.pipeline.asr_execution.cloud_concurrency == 8
    assert cfg.pipeline.asr_execution.adaptive_concurrency is True
    assert cfg.pipeline.asr_audio_track == "auto"
    assert cfg.pipeline.asr_chunking.fuzzy_dedupe is True
    assert cfg.pipeline.source_mode == "auto"
    assert cfg.pipeline.subtitle_track == "auto"
