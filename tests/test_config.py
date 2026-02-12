from __future__ import annotations

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
      text_paths: [candidates[0].content.parts[].text]
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
