from __future__ import annotations

from pathlib import Path

from transvortex.providers.probe import probe_exit_code, probe_provider


def _write_provider_file(
    path: Path,
    *,
    response_paths: str = "content[].text",
    env_key: str = "TVX_MODEL_API_KEY",
) -> None:
    path.write_text(
        f"""
providers:
  - name: example_anthropic_gateway
    api_type: anthropic
    compat_mode: anthropic_messages
    base_url: https://gateway.example.invalid/v1
    env_key: {env_key}
    models: [example-model]
    auth:
      type: header
      header_name: x-api-key
      prefix: ""
    endpoint:
      path_template: /messages
      method: POST
    request_mapping:
      style: anthropic_messages
      max_tokens: 128
    response_mapping:
      text_paths: ["{response_paths}"]
routing:
  primary: {{provider: example_anthropic_gateway, model: example-model}}
  fallback: []
        """.strip(),
        encoding="utf-8",
    )


def test_probe_provider_missing_env_fails_without_secret(tmp_path: Path, monkeypatch) -> None:
    _write_provider_file(tmp_path / "providers.yaml")
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    monkeypatch.delenv("TVX_MODEL_API_KEY", raising=False)
    report = probe_provider(root_dir=tmp_path)
    checks = {row["name"]: row for row in report["checks"]}
    assert checks["env_key_present"]["status"] == "FAIL"
    assert checks["env_key_present"]["details"]["env_key"] == "TVX_MODEL_API_KEY"
    assert checks["env_key_present"]["details"]["credential_source"] == "missing"
    assert "DUMMY_API_KEY" not in str(report)
    assert probe_exit_code(report, strict=True) == 1


def test_probe_provider_payload_and_mapping_pass(tmp_path: Path, monkeypatch) -> None:
    _write_provider_file(tmp_path / "providers.yaml")
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    monkeypatch.setenv("TVX_MODEL_API_KEY", "abc123456")
    report = probe_provider(root_dir=tmp_path)
    checks = {row["name"]: row for row in report["checks"]}
    assert checks["request_payload_build"]["status"] == "PASS"
    assert checks["response_mapping_extract"]["status"] == "PASS"
    assert checks["url_and_auth_build"]["status"] == "PASS"
    assert probe_exit_code(report, strict=True) == 0


def test_probe_provider_bad_response_mapping_fails_strict(tmp_path: Path, monkeypatch) -> None:
    _write_provider_file(tmp_path / "providers.yaml", response_paths="not.exists")
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    monkeypatch.setenv("TVX_MODEL_API_KEY", "abc123456")
    report = probe_provider(root_dir=tmp_path)
    checks = {row["name"]: row for row in report["checks"]}
    assert checks["response_mapping_extract"]["status"] == "FAIL"
    assert probe_exit_code(report, strict=True) == 1


def test_probe_provider_accepts_openai_responses(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "providers.yaml").write_text(
        """
providers:
  - name: responses
    api_type: openai-compatible
    compat_mode: openai_responses
    base_url: https://example.com/v1
    env_key: TVX_MODEL_API_KEY
    models: [gpt-x]
routing:
  primary: {provider: responses, model: gpt-x}
  fallback: []
        """.strip(),
        encoding="utf-8",
    )
    (tmp_path / "pipeline.yaml").write_text("{}", encoding="utf-8")
    monkeypatch.setenv("TVX_MODEL_API_KEY", "abc123456")
    report = probe_provider(root_dir=tmp_path)
    checks = {row["name"]: row for row in report["checks"]}
    assert checks["compat_mode_valid"]["status"] == "PASS"
    assert checks["response_mapping_extract"]["status"] == "PASS"
