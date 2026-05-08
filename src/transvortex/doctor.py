from __future__ import annotations

import importlib.metadata
import importlib.util
import os
import platform
import shutil
import sys
from pathlib import Path
from typing import Any

from .config import load_app_config, resolve_providers_file
from .probe import probe_provider


def _check(
    name: str,
    status: str,
    code: str,
    message: str,
    hint_zh: str,
    *,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "name": name,
        "status": status,
        "code": code,
        "message": message,
        "hint_zh": hint_zh,
    }
    if details:
        item["details"] = details
    return item


def _overall_status(checks: list[dict[str, Any]]) -> str:
    if any(item.get("status") == "FAIL" for item in checks):
        return "FAIL"
    if any(item.get("status") == "WARN" for item in checks):
        return "WARN"
    return "PASS"


def _binary_check(binary: str) -> dict[str, Any]:
    path = shutil.which(binary)
    if path:
        return _check(
            binary,
            "PASS",
            f"{binary}_found",
            f"{binary} found",
            f"{binary} 已可用。",
            details={"path": path},
        )
    return _check(
        binary,
        "FAIL",
        f"{binary}_missing",
        f"{binary} not found in PATH",
        f"未找到 {binary}。请安装并加入 PATH。",
    )


def _dotenv_keys(root_dir: Path) -> set[str]:
    dotenv_file = root_dir / ".env"
    if not dotenv_file.exists():
        return set()
    keys: set[str] = set()
    for raw in dotenv_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, _value = line.split("=", 1)
        key = key.strip()
        if key:
            keys.add(key)
    return keys


def _artifacts_check(artifacts_dir: Path) -> dict[str, Any]:
    probe_file = artifacts_dir / ".tvx_doctor_write_probe"
    try:
        artifacts_dir.mkdir(parents=True, exist_ok=True)
        probe_file.write_text("ok", encoding="utf-8")
        probe_file.unlink(missing_ok=True)
    except Exception as exc:
        return _check(
            "artifacts",
            "FAIL",
            "artifacts_not_writable",
            f"artifacts directory is not writable: {exc}",
            "artifacts 目录不可写。请检查路径和权限。",
            details={"path": str(artifacts_dir)},
        )
    return _check(
        "artifacts",
        "PASS",
        "artifacts_writable",
        "artifacts directory is writable",
        "artifacts 目录可写。",
        details={"path": str(artifacts_dir)},
    )


def _package_version() -> str:
    try:
        return importlib.metadata.version("transvortex")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def _env_key_check(
    *,
    root_dir: Path,
    env_key: str,
    name: str,
    message_subject: str,
) -> dict[str, Any]:
    if os.getenv(env_key):
        return _check(
            name,
            "PASS",
            "env_key_present",
            f"{message_subject} environment variable is set",
            f"{env_key} 已配置。",
            details={"env_key": env_key},
        )
    legacy_keys = sorted(_dotenv_keys(root_dir) & {"OPENAI_API_KEY", "VECTORENGINE_API_KEY"})
    hint = f"缺少 {env_key}。请在 .env 中写入 {env_key}=你的key，或在桌面端保存 key。"
    if legacy_keys and env_key == "TVX_MODEL_API_KEY":
        hint += f" 检测到旧 key 名 {', '.join(legacy_keys)}，请复制为 TVX_MODEL_API_KEY。"
    return _check(
        name,
        "FAIL",
        "missing_env",
        f"Missing environment variable: {env_key}",
        hint,
        details={"env_key": env_key, "legacy_keys_present": legacy_keys},
    )


def doctor_report(*, root_dir: Path, providers_file: Path | None = None) -> dict[str, Any]:
    root_dir = root_dir.resolve()
    resolved_providers_file = resolve_providers_file(root_dir, providers_file)
    checks: list[dict[str, Any]] = [
        _check(
            "python",
            "PASS",
            "python_found",
            "Python is available",
            "Python 已可用。",
            details={"executable": sys.executable, "version": platform.python_version()},
        ),
        _check(
            "transvortex_package",
            "PASS",
            "package_importable",
            "transvortex package is importable",
            "transvortex 包已可导入。",
            details={"version": _package_version()},
        ),
        _binary_check("ffmpeg"),
        _binary_check("ffprobe"),
    ]

    if resolved_providers_file.exists():
        checks.append(
            _check(
                "providers_file",
                "PASS",
                "providers_file_found",
                "providers file found",
                "provider 配置文件已找到。",
                details={"path": str(resolved_providers_file)},
            )
        )
    else:
        checks.append(
            _check(
                "providers_file",
                "FAIL",
                "providers_file_missing",
                "providers file not found",
                "未找到 provider 配置文件。请创建 providers.local.yaml 或使用 --providers-file。",
                details={"path": str(resolved_providers_file)},
            )
        )

    try:
        config = load_app_config(root_dir=root_dir, providers_file=providers_file)
    except Exception as exc:
        checks.append(
            _check(
                "config_load",
                "FAIL",
                "config_load_failed",
                f"failed to load config: {exc}",
                "配置加载失败。请检查 pipeline.yaml 和 provider YAML 格式。",
            )
        )
        return {
            "status": _overall_status(checks),
            "root_dir": str(root_dir),
            "providers_file": str(resolved_providers_file),
            "checks": checks,
        }

    checks.append(_artifacts_check(config.pipeline.artifacts_dir))

    if config.pipeline.asr_mode == "local":
        if importlib.util.find_spec("faster_whisper") is None:
            checks.append(
                _check(
                    "faster_whisper",
                    "FAIL",
                    "faster_whisper_missing",
                    "faster-whisper is required for local ASR",
                    "本地 ASR 需要 faster-whisper。请执行 python -m pip install -e .[asr]。",
                    details={"asr_mode": config.pipeline.asr_mode},
                )
            )
        else:
            checks.append(
                _check(
                    "faster_whisper",
                    "PASS",
                    "faster_whisper_found",
                    "faster-whisper is available",
                    "faster-whisper 已可用。",
                    details={"asr_mode": config.pipeline.asr_mode},
                )
            )
    else:
        checks.append(
            _check(
                "faster_whisper",
                "WARN",
                "faster_whisper_not_required",
                "faster-whisper is not required for current ASR mode",
                "当前 ASR 模式不依赖 faster-whisper。",
                details={"asr_mode": config.pipeline.asr_mode},
            )
        )

    route = config.routing.primary
    provider = config.providers.get(route.provider)
    if not route.provider or not route.model:
        checks.append(
            _check(
                "routing",
                "FAIL",
                "routing_primary_missing",
                "routing.primary provider/model is missing",
                "缺少 routing.primary.provider 或 routing.primary.model。",
            )
        )
    elif provider is None:
        checks.append(
            _check(
                "routing",
                "FAIL",
                "routing_provider_missing",
                f"routing provider not found: {route.provider}",
                f"routing 指向的 provider 不存在：{route.provider}。",
            )
        )
    elif route.model not in provider.models:
        checks.append(
            _check(
                "routing",
                "WARN",
                "routing_model_not_listed",
                "routing model is not listed in provider.models",
                "routing 使用的模型不在 provider.models 中，请确认是否拼写正确。",
                details={"provider": route.provider, "model": route.model, "provider_models": provider.models},
            )
        )
    else:
        checks.append(
            _check(
                "routing",
                "PASS",
                "routing_primary_valid",
                "routing.primary provider/model is valid",
                "routing.primary 配置有效。",
                details={"provider": route.provider, "model": route.model},
            )
        )

    if provider is not None:
        checks.append(
            _env_key_check(
                root_dir=root_dir,
                env_key=provider.env_key,
                name="provider_env_key",
                message_subject="provider",
            )
        )
        try:
            probe = probe_provider(
                root_dir=root_dir,
                providers_file=providers_file,
                provider_name=route.provider,
                model=route.model,
            )
            failures = [
                item
                for item in probe.get("checks", [])
                if item.get("status") == "FAIL" and item.get("name") != "env_key_present"
            ]
            if failures:
                checks.append(
                    _check(
                        "provider_protocol",
                        "FAIL",
                        "provider_protocol_failed",
                        "provider protocol preflight has failures",
                        "provider 协议预检失败。请检查 compat_mode、endpoint、request/response mapping。",
                        details={"failures": failures},
                    )
                )
            else:
                checks.append(
                    _check(
                        "provider_protocol",
                        "PASS",
                        "provider_protocol_valid",
                        "provider protocol preflight passed",
                        "provider 协议预检通过。",
                    )
                )
        except Exception as exc:
            checks.append(
                _check(
                    "provider_protocol",
                    "FAIL",
                    "provider_protocol_error",
                    f"provider protocol preflight failed: {exc}",
                    "provider 协议预检异常。请检查 provider 配置。",
                )
            )

    if config.pipeline.asr_mode == "openai":
        env_key = config.pipeline.asr_cloud_env_key
        if config.pipeline.asr_provider:
            asr_provider = config.providers.get(config.pipeline.asr_provider)
            if asr_provider is None:
                checks.append(
                    _check(
                        "asr_provider",
                        "FAIL",
                        "asr_provider_missing",
                        f"ASR provider not found: {config.pipeline.asr_provider}",
                        f"ASR provider 不存在：{config.pipeline.asr_provider}。",
                    )
                )
            else:
                env_key = asr_provider.env_key
        checks.append(
            _env_key_check(
                root_dir=root_dir,
                env_key=env_key,
                name="asr_env_key",
                message_subject="ASR",
            )
        )

    return {
        "status": _overall_status(checks),
        "root_dir": str(root_dir),
        "providers_file": str(resolved_providers_file),
        "artifacts_dir": str(config.pipeline.artifacts_dir),
        "checks": checks,
    }


def format_doctor_report(report: dict[str, Any]) -> str:
    lines = [f"TransVortex Doctor: {report.get('status', 'UNKNOWN')}"]
    for item in report.get("checks", []):
        status = item.get("status", "UNKNOWN")
        name = item.get("name", "unknown")
        message = item.get("message", "")
        lines.append(f"[{status}] {name}: {message}")
        hint = item.get("hint_zh")
        if hint:
            lines.append(f"  建议: {hint}")
    return "\n".join(lines)
