from __future__ import annotations

import argparse
import configparser
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable

from .. import __version__
from ..utils import write_json


AGENT_ENTRY_SCHEMA_VERSION = 1
AGENT_PROTOCOL_VERSION = "0.1"
INSTALL_APP_ID = "TransVortex"
INSTALL_MARKER_NAME = ".transvortex-install.ini"
AGENT_ENTRY_DIRECTORY_NAME = "Agent"
AGENT_ENTRY_DOCUMENT_NAME = "README.md"
AGENT_ENTRY_STATE_NAME = "current.json"
ASR_SETUP_SCOPES = (
    "inspect",
    "prepare_model",
    "prepare_accelerator",
    "register",
    "full",
)
ASR_ENVIRONMENT_SCOPES = (*ASR_SETUP_SCOPES[:-1], "funasr_launcher", "full")


class AgentEntryError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def agent_entry_root(config_root: Path) -> Path:
    root = config_root.expanduser().resolve()
    if root.name.casefold() != "config":
        raise AgentEntryError(
            "agent_entry_config_root_invalid",
            "The installed Agent entry requires the dedicated TransVortex Config directory",
        )
    return root.parent / AGENT_ENTRY_DIRECTORY_NAME


def find_registered_install_root(executable: Path | None = None) -> Path | None:
    for candidate in _ancestor_directories(executable or Path(sys.executable)):
        if _is_registered_install(candidate):
            return candidate
    return None


def cli_argv_prefix(*, root_dir: Path, executable: Path | None = None) -> list[str]:
    context = runtime_agent_context(root_dir=root_dir, executable=executable)
    return list(context["cli_argv_prefix"])


def runtime_agent_context(*, root_dir: Path, executable: Path | None = None) -> dict[str, Any]:
    config_root = root_dir.expanduser().resolve()
    executable_path = (executable or Path(sys.executable)).expanduser().resolve()
    install_root = find_registered_install_root(executable_path)
    if install_root is not None:
        return build_installed_agent_entry(install_root=install_root, config_root=config_root)

    portable_root = _find_portable_root(executable_path)
    if portable_root is not None:
        return _build_context(
            install_kind="portable",
            install_root=portable_root,
            config_root=config_root,
            docs_root=portable_root / "agent",
            python_executable=portable_root / "runtime" / "python" / "python.exe",
            registered=False,
        )

    docs_root = _find_source_docs_root()
    return _build_context(
        install_kind="source",
        install_root=None,
        config_root=config_root,
        docs_root=docs_root,
        python_executable=executable_path,
        registered=False,
    )


def build_installed_agent_entry(*, install_root: Path, config_root: Path) -> dict[str, Any]:
    root = install_root.expanduser().resolve()
    config = config_root.expanduser().resolve()
    if not _is_registered_install(root):
        raise AgentEntryError(
            "agent_install_invalid",
            "The requested directory is not a registered TransVortex installation",
        )
    docs_root = root / "agent"
    missing = [str(path) for path in _required_document_paths(docs_root) if not path.is_file()]
    if missing:
        raise AgentEntryError(
            "agent_documents_missing",
            "The installed TransVortex Agent documents are incomplete",
        )
    python_executable = root / "runtime" / "python" / "python.exe"
    if not python_executable.is_file():
        raise AgentEntryError(
            "agent_cli_missing",
            "The installed TransVortex Python runtime is missing",
        )
    return _build_context(
        install_kind="windows_user_install",
        install_root=root,
        config_root=config,
        docs_root=docs_root,
        python_executable=python_executable,
        registered=True,
    )


def register_agent_entry(*, install_root: Path, config_root: Path) -> dict[str, Any]:
    payload = build_installed_agent_entry(install_root=install_root, config_root=config_root)
    entry_root = agent_entry_root(config_root)
    entry_root.mkdir(parents=True, exist_ok=True)
    _atomic_write_text(
        entry_root / AGENT_ENTRY_DOCUMENT_NAME,
        _entry_document(payload),
    )
    write_json(entry_root / AGENT_ENTRY_STATE_NAME, payload)
    return payload


def reconcile_installed_agent_entry(
    *,
    config_root: Path,
    executable: Path | None = None,
) -> dict[str, Any]:
    install_root = find_registered_install_root(executable)
    if install_root is None:
        raise AgentEntryError(
            "agent_install_not_registered",
            "The running TransVortex instance is not a registered installation",
        )
    return register_agent_entry(install_root=install_root, config_root=config_root)


def remove_agent_entry(*, config_root: Path) -> dict[str, Any]:
    entry_root = agent_entry_root(config_root)
    removed: list[str] = []
    for name in (AGENT_ENTRY_STATE_NAME, AGENT_ENTRY_DOCUMENT_NAME):
        target = entry_root / name
        if target.is_file() or target.is_symlink():
            target.unlink()
            removed.append(str(target))
    try:
        entry_root.rmdir()
    except FileNotFoundError:
        pass
    except OSError:
        # Preserve any file not owned by this helper.
        pass
    return {"ok": True, "removed": removed, "entry_root": str(entry_root)}


def agent_entry_service_payload(*, config_root: Path, executable: Path | None = None) -> dict[str, Any]:
    payload = reconcile_installed_agent_entry(config_root=config_root, executable=executable)
    entry_document = str(agent_entry_root(config_root) / AGENT_ENTRY_DOCUMENT_NAME)
    result = dict(payload)
    result["handoff_text"] = _handoff_text(entry_document)
    workflow = str(payload["documents"]["asr_environment_setup"])
    asr_handoffs = {
        scope: _asr_handoff_text(entry_document, workflow=workflow, scope=scope)
        for scope in ASR_ENVIRONMENT_SCOPES
    }
    result["asr_environment_handoffs"] = asr_handoffs
    result["asr_environment_handoff_text"] = asr_handoffs["full"]
    return result


def _build_context(
    *,
    install_kind: str,
    install_root: Path | None,
    config_root: Path,
    docs_root: Path | None,
    python_executable: Path,
    registered: bool,
) -> dict[str, Any]:
    config = config_root.expanduser().resolve()
    python = python_executable.expanduser().resolve()
    argv_prefix = [str(python), "-B", "-m", "transvortex.cli", "--root", str(config)]
    documents = _document_payload(docs_root)
    entry_root = agent_entry_root(config) if registered else None
    return {
        "schema_version": AGENT_ENTRY_SCHEMA_VERSION,
        "product": "TransVortex",
        "app_version": __version__,
        "protocol_version": AGENT_PROTOCOL_VERSION,
        "install_kind": install_kind,
        "registered": registered,
        "install_root": str(install_root) if install_root is not None else None,
        "config_root": str(config),
        "agent_entry_root": str(entry_root) if entry_root is not None else None,
        "agent_entry_document": str(entry_root / AGENT_ENTRY_DOCUMENT_NAME) if entry_root is not None else None,
        "agent_entry_state": str(entry_root / AGENT_ENTRY_STATE_NAME) if entry_root is not None else None,
        "agent_docs_root": str(docs_root.resolve()) if docs_root is not None else None,
        "documents": documents,
        "cli_argv_prefix": argv_prefix,
        "capabilities_argv": [*argv_prefix, "agent-info", "--json"],
    }


def _document_payload(docs_root: Path | None) -> dict[str, str | None]:
    if docs_root is None:
        return {
            "start": None,
            "usage": None,
            "adaptation": None,
            "asr_environment_setup": None,
            "setup_contract_schema": None,
        }
    root = docs_root.expanduser().resolve()
    return {
        "start": str(root / "README.md"),
        "usage": str(root / "AGENT_USAGE.md"),
        "adaptation": str(root / "ADAPTATION_GUIDE.md"),
        "asr_environment_setup": str(root / "workflows" / "ASR_ENVIRONMENT_SETUP.md"),
        "setup_contract_schema": str(root / "references" / "setup_contract.schema.json"),
    }


def _required_document_paths(docs_root: Path) -> tuple[Path, ...]:
    documents = _document_payload(docs_root)
    return tuple(Path(value) for value in documents.values() if value is not None)


def _entry_document(payload: dict[str, Any]) -> str:
    documents = payload["documents"]
    return f"""# TransVortex Agent Entry

这是当前用户安装的 TransVortex 稳定入口。先读取同目录的 `current.json`，不要假设 `transvortex` 已加入 `PATH`。

- 当前文档入口：`{documents['start']}`
- 完整 CLI 手册：`{documents['usage']}`
- Agent 适配说明：`{documents['adaptation']}`
- ASR 环境准备：`{documents['asr_environment_setup']}`

执行 `current.json` 中的 `capabilities_argv` 可取得当前版本的机器可读能力契约。命令参数应按 JSON 数组逐项传递，不要拼接成 shell 字符串。

需要长期复用时，可以按 Agent 自身的扩展机制建立 skill、plugin、rules 或项目说明；TransVortex 不会自动修改这些目录。不要读取、输出或写入凭据值。
"""


def _handoff_text(entry_document: str, *, workflow: str | None = None) -> str:
    workflow_text = f"；本次 ASR 环境准备按 `{workflow}` 执行" if workflow else ""
    return (
        "请使用本机安装的 TransVortex。"
        f"稳定入口：`{entry_document}`。"
        "先读取该文件和同目录的 `current.json`，再执行其中的 `capabilities_argv` 获取当前能力契约"
        f"{workflow_text}。"
        "按用户当前任务只读取需要的文档并调用能力；"
        "只有需要长期复用时，再读取适配说明并按你自己的扩展机制建立薄适配。"
        "不要假设 `transvortex` 已加入 PATH，也不要读取或输出凭据值。"
    )


def _asr_handoff_text(entry_document: str, *, workflow: str, scope: str) -> str:
    if scope == "funasr_launcher":
        return (
            "请使用本机安装的 TransVortex。"
            f"稳定入口：`{entry_document}`；参考工作流：`{workflow}`。"
            "先读取入口、current.json 和 capabilities_argv 返回的当前契约。"
            "本次只为这台电脑上已经部署且可由用户正常启动的 FunASR 服务配置点火器："
            "先侦查并实际验证可执行文件、参数数组、工作目录、loopback 服务地址和健康检查地址；"
            "不要把整条 PowerShell/CMD 命令保存为字符串，不要读取或写入凭据。"
            "除非用户在当前对话中另外明确授权，否则不要下载、安装、升级、修复或替换 FunASR、模型、Python、CUDA 和驱动。"
            "验证启动配方后，使用 agent-info 广告的 `asr funasr-launcher-save` 命令保存；"
            "再用 `asr funasr-launcher-status --json` 确认配置可读。"
            "点火器的启动、停止和健康等待由 TransVortex 桌面端 Local Service 持有；"
            "结果直接在当前 Agent 对话中说明，不写入其他产品配置。"
        )
    goals = {
        "inspect": "侦查这台电脑当前的 ASR、GPU、驱动、磁盘和可复用资源，只给出结论与可执行方案，暂不准备或接入资源",
        "prepare_model": "侦查本机后选择并准备一个适合本机与用户任务的 Whisper 模型；可调用 TransVortex 托管下载，也可用你自己的工具准备外部模型，并在完成后注册、激活和验证",
        "prepare_accelerator": "侦查本机 NVIDIA GPU、驱动和用户态 CUDA 资源后准备可用的 GPU 加速；可调用 TransVortex 托管下载，也可用你自己的工具准备外部资源，并在完成后注册、激活和验证",
        "register": "接入用户已经准备好的模型或 GPU 加速资源；先探测，随后使用 TransVortex 广告的注册、激活和验证命令，不重新下载资源",
        "full": "侦查这台电脑并把本地 ASR 环境准备到可用；TransVortex runtime 使用产品托管版本，模型和 GPU 加速可分别选择托管资源或由你准备外部资源，最后注册、激活并完成严格验证",
    }
    goal = goals.get(scope, goals["full"])
    verification = (
        f"最后执行契约广告的 `setup-verify --scope {scope}`，以 `scope_result.complete` 判断本范围是否完成；完整 ASR 是否可用单独读取 `asr_ready`"
        if scope != "full"
        else "最后执行契约广告的 `setup-verify --scope full --strict`，以严格结构化结果确认完整 ASR 已可用"
    )
    return (
        "请使用本机安装的 TransVortex。"
        f"稳定入口：`{entry_document}`；ASR 环境与资源工作流：`{workflow}`。"
        "先读取入口、current.json 和 capabilities_argv 返回的当前契约。"
        f"本次范围：{goal}。"
        f"执行契约广告的 `setup-plan --scope {scope}`；当前配置只作为侦查基线，不是强制目标。"
        "请在侦查后自行选择合适的模型、CPU 或 CUDA 路径，以及 managed 或 external 资源来源；候选动作是互斥或按需依赖，不要全部执行。"
        f"{verification}。结果直接在当前 Agent 对话中说明，不写回 TransVortex UI。"
    )


def _atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def _ancestor_directories(path: Path) -> Iterable[Path]:
    resolved = path.expanduser().resolve()
    current = resolved if resolved.is_dir() else resolved.parent
    yield current
    yield from current.parents


def _is_registered_install(root: Path) -> bool:
    marker = root / INSTALL_MARKER_NAME
    if not marker.is_file():
        return False
    metadata = _read_install_metadata(marker)
    return metadata.get("appid", "").casefold() == INSTALL_APP_ID.casefold()


def _read_install_metadata(marker: Path) -> dict[str, str]:
    try:
        raw = marker.read_bytes()
    except OSError:
        return {}
    encodings = ("utf-8-sig", "utf-16", "cp1252")
    for encoding in encodings:
        try:
            text = raw.decode(encoding)
            parser = configparser.ConfigParser(interpolation=None)
            parser.read_string(text)
            if parser.has_section("Install"):
                return {key.casefold(): value.strip() for key, value in parser.items("Install")}
        except (UnicodeError, configparser.Error):
            continue
    return {}


def _find_portable_root(executable: Path) -> Path | None:
    for candidate in _ancestor_directories(executable):
        if (
            (candidate / "runtime" / "python" / "python.exe").is_file()
            and (candidate / "agent" / "README.md").is_file()
        ):
            return candidate
    return None


def _find_source_docs_root() -> Path | None:
    for candidate in Path(__file__).resolve().parents:
        docs_root = candidate / "agent"
        if (docs_root / "README.md").is_file():
            return docs_root
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="transvortex.app.agent_entry")
    sub = parser.add_subparsers(dest="command", required=True)

    register = sub.add_parser("register")
    register.add_argument("--install-root", required=True)
    register.add_argument("--config-root", required=True)
    register.add_argument("--json", action="store_true")

    remove = sub.add_parser("remove")
    remove.add_argument("--config-root", required=True)
    remove.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    try:
        if args.command == "register":
            result = register_agent_entry(
                install_root=Path(args.install_root),
                config_root=Path(args.config_root),
            )
        else:
            result = remove_agent_entry(config_root=Path(args.config_root))
    except AgentEntryError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
