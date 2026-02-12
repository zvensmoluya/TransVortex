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
