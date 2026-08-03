from __future__ import annotations

import json
from pathlib import Path

import pytest

from transvortex.app.agent_entry import (
    AgentEntryError,
    build_installed_agent_entry,
    agent_entry_service_payload,
    register_agent_entry,
    remove_agent_entry,
    runtime_agent_context,
)


def _installed_layout(tmp_path: Path, *, marker_encoding: str = "utf-8") -> tuple[Path, Path]:
    install_root = tmp_path / "Programs" / "TransVortex" / "App"
    config_root = tmp_path / "LocalAppData" / "TransVortex" / "Config"
    config_root.mkdir(parents=True)
    (install_root / ".transvortex-install.ini").parent.mkdir(parents=True)
    (install_root / ".transvortex-install.ini").write_text(
        "[Install]\nAppId=TransVortex\nVersion=0.1.0\n",
        encoding=marker_encoding,
    )
    (install_root / "runtime" / "python").mkdir(parents=True)
    (install_root / "runtime" / "python" / "python.exe").write_bytes(b"")
    documents = (
        install_root / "agent" / "README.md",
        install_root / "agent" / "AGENT_USAGE.md",
        install_root / "agent" / "ADAPTATION_GUIDE.md",
        install_root / "agent" / "workflows" / "ASR_ENVIRONMENT_SETUP.md",
        install_root / "agent" / "references" / "setup_contract.schema.json",
    )
    for path in documents:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(path.name, encoding="utf-8")
    return install_root, config_root


@pytest.mark.parametrize("marker_encoding", ["utf-8", "utf-16"])
def test_register_agent_entry_writes_stable_secret_free_locator(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    marker_encoding: str,
) -> None:
    install_root, config_root = _installed_layout(tmp_path, marker_encoding=marker_encoding)
    monkeypatch.setenv("EXAMPLE_API_TOKEN", "super-secret-value")
    monkeypatch.setenv("CI_TEST_PASSWORD", "root")

    payload = register_agent_entry(install_root=install_root, config_root=config_root)

    entry_root = config_root.parent / "Agent"
    raw = (entry_root / "current.json").read_text(encoding="utf-8")
    current = json.loads(raw)
    assert current == payload
    assert current["registered"] is True
    assert current["install_kind"] == "windows_user_install"
    assert current["install_root"] == str(install_root.resolve())
    assert current["config_root"] == str(config_root.resolve())
    assert current["cli_argv_prefix"] == [
        str((install_root / "runtime" / "python" / "python.exe").resolve()),
        "-B",
        "-m",
        "transvortex.cli",
        "--root",
        str(config_root.resolve()),
    ]
    assert current["capabilities_argv"][-2:] == ["agent-info", "--json"]
    assert current["documents"]["asr_environment_setup"].endswith("ASR_ENVIRONMENT_SETUP.md")
    assert "super-secret-value" not in raw
    entry_document = (entry_root / "README.md").read_text(encoding="utf-8")
    assert "current.json" in entry_document
    assert "不要假设 `transvortex` 已加入 `PATH`" in entry_document


def test_runtime_context_discovers_registered_install_from_nested_executable(tmp_path: Path) -> None:
    install_root, config_root = _installed_layout(tmp_path)
    executable = install_root / "runtime" / "python" / "python.exe"

    payload = runtime_agent_context(root_dir=config_root, executable=executable)

    assert payload["registered"] is True
    assert payload["install_root"] == str(install_root.resolve())
    assert payload["cli_argv_prefix"][0] == str(executable.resolve())


def test_agent_entry_service_payload_offers_scoped_asr_handoffs(tmp_path: Path) -> None:
    install_root, config_root = _installed_layout(tmp_path)
    executable = install_root / "runtime" / "python" / "python.exe"

    payload = agent_entry_service_payload(config_root=config_root, executable=executable)

    handoffs = payload["asr_environment_handoffs"]
    assert "长期复用" in payload["handoff_text"]
    assert "薄适配" in payload["handoff_text"]
    assert set(handoffs) == {"inspect", "prepare_model", "prepare_accelerator", "register", "full"}
    assert "暂不准备或接入资源" in handoffs["inspect"]
    assert "setup-plan --scope inspect" in handoffs["inspect"]
    assert "scope_result.complete" in handoffs["inspect"]
    assert "当前配置只作为侦查基线" in handoffs["inspect"]
    assert "模型" in handoffs["prepare_model"]
    assert "自行选择合适的模型、CPU 或 CUDA" in handoffs["prepare_model"]
    assert "NVIDIA" in handoffs["prepare_accelerator"]
    assert "不重新下载" in handoffs["register"]
    assert "setup-verify --scope full --strict" in handoffs["full"]
    assert "结果直接在当前 Agent 对话中说明" in handoffs["full"]
    assert payload["asr_environment_handoff_text"] == handoffs["full"]


def test_source_context_does_not_create_a_stable_entry(tmp_path: Path) -> None:
    config_root = tmp_path / "project"
    executable = tmp_path / "python" / "python.exe"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"")

    payload = runtime_agent_context(root_dir=config_root, executable=executable)

    assert payload["install_kind"] == "source"
    assert payload["registered"] is False
    assert payload["agent_entry_document"] is None
    assert not (tmp_path / "Agent").exists()


def test_remove_agent_entry_preserves_unowned_files(tmp_path: Path) -> None:
    install_root, config_root = _installed_layout(tmp_path)
    register_agent_entry(install_root=install_root, config_root=config_root)
    entry_root = config_root.parent / "Agent"
    retained = entry_root / "user-note.txt"
    retained.write_text("keep", encoding="utf-8")

    result = remove_agent_entry(config_root=config_root)

    assert result["ok"] is True
    assert not (entry_root / "README.md").exists()
    assert not (entry_root / "current.json").exists()
    assert retained.read_text(encoding="utf-8") == "keep"
    assert entry_root.is_dir()


def test_build_installed_agent_entry_rejects_unregistered_directory(tmp_path: Path) -> None:
    config_root = tmp_path / "TransVortex" / "Config"

    with pytest.raises(AgentEntryError) as exc_info:
        build_installed_agent_entry(install_root=tmp_path / "App", config_root=config_root)

    assert exc_info.value.code == "agent_install_invalid"
