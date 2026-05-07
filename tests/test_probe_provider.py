from __future__ import annotations

from pathlib import Path

from transvortex.probe import probe_exit_code, probe_provider


def _write_provider_file(
    path: Path,
    *,
    response_paths: str = "content[].text",
    env_key: str = "TVX_MODEL_API_KEY",
) -> None:
    path.write_text(
        f"""
providers:
  - name: vector_anthropic
    api_type: anthropic
    compat_mode: anthropic_messages
    base_url: https://api.vectorengine.ai/v1
    env_key: {env_key}
    models: [claude-haiku-4-5-20251001]
    auth:
      type: header
      header_name: x-api-key
      prefix: ""
    endpoint:
      path_template: /v1/messages
      method: POST
    request_mapping:
      style: anthropic_messages
      max_tokens: 128
    response_mapping:
      text_paths: ["{response_paths}"]
routing:
  primary: {{provider: vector_anthropic, model: claude-haiku-4-5-20251001}}
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
    assert "TVX_MODEL_API_KEY" in checks["env_key_present"]["message"]
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
