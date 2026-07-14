from __future__ import annotations

import importlib.metadata
import importlib.util
import platform
import sys
from pathlib import Path
from typing import Any

import httpx

from .config import load_app_config, resolve_providers_file
from .credentials import resolve_credential
from .asr_runtime import asr_provider_readiness
from ..core.media_tools import resolve_media_executable
from ..providers.probe import probe_provider

FASTER_WHISPER_MIN_VERSION = "1.0.2"


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
    path = resolve_media_executable(binary)
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
        f"{binary} not found in the bundled media tools or PATH",
        f"未找到 {binary}。请修复应用安装，或在开发环境中把它加入 PATH。",
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


def _faster_whisper_version() -> str | None:
    try:
        return importlib.metadata.version("faster-whisper")
    except importlib.metadata.PackageNotFoundError:
        return None


def _version_lt(actual: str, minimum: str) -> bool:
    def parse(value: str) -> list[int]:
        parts: list[int] = []
        for chunk in value.split("."):
            digits = ""
            for char in chunk:
                if char.isdigit():
                    digits += char
                else:
                    break
            if digits:
                parts.append(int(digits))
            else:
                parts.append(0)
        return parts

    actual_parts = parse(actual)
    minimum_parts = parse(minimum)
    length = max(len(actual_parts), len(minimum_parts))
    actual_parts.extend([0] * (length - len(actual_parts)))
    minimum_parts.extend([0] * (length - len(minimum_parts)))
    return actual_parts < minimum_parts


def _env_key_check(
    *,
    root_dir: Path,
    env_key: str,
    name: str,
    message_subject: str,
    credential_id: str | None = None,
    provider_name: str = "",
) -> dict[str, Any]:
    credential = resolve_credential(
        env_key=env_key,
        credential_id=credential_id or env_key,
        provider_name=provider_name,
        root_dir=root_dir,
    )
    if credential.found:
        return _check(
            name,
            "PASS",
            "env_key_present",
            f"{message_subject} credential is configured via {credential.source}",
            f"{env_key} 已配置，来源：{credential.source}。",
            details={
                "env_key": env_key,
                "credential_id": credential.credential_id,
                "credential_source": credential.source,
            },
        )
    legacy_keys = sorted(_dotenv_keys(root_dir) & {"OPENAI_API_KEY", "VECTORENGINE_API_KEY"})
    hint = f"缺少 {env_key}。请在 .env 中写入 {env_key}=你的key，或在桌面端保存 key。"
    if legacy_keys and env_key == "TVX_MODEL_API_KEY":
        hint += f" 检测到旧 key 名 {', '.join(legacy_keys)}，请复制为 TVX_MODEL_API_KEY。"
    return _check(
        name,
        "FAIL",
        "missing_env",
        f"Missing credential: {credential.credential_id or env_key}",
        hint,
        details={
            "env_key": env_key,
            "credential_id": credential.credential_id,
            "credential_source": credential.source,
            "legacy_keys_present": legacy_keys,
        },
    )


def _local_server_reachability_check(provider) -> dict[str, Any]:
    try:
        response = httpx.get(provider.base_url, timeout=2.0, follow_redirects=False)
    except Exception as exc:  # noqa: BLE001 - doctor should report availability, not fail hard
        return _check(
            "asr_local_server",
            "FAIL",
            "asr_local_server_unreachable",
            f"local ASR server is not reachable: {exc}",
            "本地 ASR 服务不可达。请确认 FunASR server 已启动，且 base_url 指向 localhost 服务。",
            details={"provider": provider.name, "base_url": provider.base_url},
        )
    status = "PASS" if response.status_code < 500 else "WARN"
    return _check(
        "asr_local_server",
        status,
        "asr_local_server_reachable",
        f"local ASR server responded with HTTP {response.status_code}",
        "本地 ASR 服务端口可达。doctor 不会上传音频做真实识别。",
        details={"provider": provider.name, "base_url": provider.base_url, "status_code": response.status_code},
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

    asr_provider = config.asr_providers.get(config.pipeline.asr_provider)
    if asr_provider is None:
        checks.append(
            _check(
                "asr_provider",
                "FAIL",
                "asr_provider_missing",
                f"ASR provider not found: {config.pipeline.asr_provider}",
                f"ASR provider 不存在：{config.pipeline.asr_provider}。",
                details={"provider": config.pipeline.asr_provider},
            )
        )
    else:
        checks.append(
            _check(
                "asr_provider",
                "PASS",
                "asr_provider_valid",
                "ASR provider configuration is valid",
                "ASR provider 配置有效。",
                details={"provider": asr_provider.name, "kind": asr_provider.kind, "protocol": asr_provider.protocol},
            )
        )

    if asr_provider is not None and asr_provider.kind == "local_inprocess":
        installed_version = _faster_whisper_version()
        if installed_version is None:
            checks.append(
                _check(
                    "faster_whisper",
                    "FAIL",
                    "faster_whisper_missing",
                    "faster-whisper is required for local in-process ASR",
                    "本地进程内 ASR 需要 faster-whisper。请执行 python -m pip install -e .[asr]。",
                    details={"provider": asr_provider.name, "kind": asr_provider.kind},
                )
            )
        elif _version_lt(installed_version, FASTER_WHISPER_MIN_VERSION):
            checks.append(
                _check(
                    "faster_whisper",
                    "FAIL",
                    "faster_whisper_version_too_old",
                    f"faster-whisper {installed_version} is installed, but {FASTER_WHISPER_MIN_VERSION}+ is required",
                    f"本地 ASR 需要 faster-whisper {FASTER_WHISPER_MIN_VERSION} 或更高版本，当前安装的是 {installed_version}。",
                    details={
                        "provider": asr_provider.name,
                        "kind": asr_provider.kind,
                        "installed_version": installed_version,
                        "required_version": FASTER_WHISPER_MIN_VERSION,
                    },
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
                    details={"provider": asr_provider.name, "kind": asr_provider.kind},
                )
            )
    elif asr_provider is not None and asr_provider.kind == "local_worker":
        readiness = asr_provider_readiness(asr_provider, root_dir=root_dir)
        state = str(readiness.get("state") or "unavailable")
        code = str(readiness.get("code") or "asr_unavailable")
        status = "PASS" if state == "ready" else "WARN" if state in {"needs_action", "checking"} else "FAIL"
        hint_by_code = {
            "runtime_missing": "请在语音识别设置中安装本机 Whisper 运行组件。",
            "runtime_unpublished": "本机 Whisper 运行组件尚未发布。",
            "model_missing": "请在语音识别设置中下载所选 Whisper 模型。",
            "device_unavailable": "请安装 NVIDIA 加速包，或把运算设备改为 CPU。",
            "hardware_untested": "请在语音识别设置中检查 NVIDIA 硬件。",
            "hardware_incompatible": "NVIDIA 硬件或驱动不兼容，请改用 CPU。",
            "environment_missing": "请选择已有的 faster-whisper Python 环境。",
            "environment_unavailable": "已选 Python 环境不可用，请重新选择并验证。",
        }
        checks.append(
            _check(
                "faster_whisper",
                status,
                code,
                f"Managed faster-whisper readiness: {state}/{code}",
                "本机 Whisper 已可用。" if state == "ready" else hint_by_code.get(code, "请在语音识别设置中处理本机 Whisper 状态。"),
                details={"provider": asr_provider.name, "kind": asr_provider.kind, "readiness": readiness},
            )
        )
    elif asr_provider is not None:
        checks.append(
            _check(
                "faster_whisper",
                "WARN",
                "faster_whisper_not_required",
                "faster-whisper is not required for the active ASR provider",
                "当前 ASR provider 不依赖 faster-whisper。",
                details={"provider": asr_provider.name, "kind": asr_provider.kind},
            )
        )

    if asr_provider is not None and asr_provider.kind == "local_server":
        if asr_provider.auth.type != "none":
            checks.append(
                _check(
                    "asr_auth",
                    "FAIL",
                    "asr_local_server_auth_not_none",
                    "local ASR server provider must use auth.type none",
                    "本地 ASR 服务应使用 auth.type: none，不应要求 API key。",
                    details={"provider": asr_provider.name, "auth_type": asr_provider.auth.type},
                )
            )
        else:
            checks.append(
                _check(
                    "asr_auth",
                    "PASS",
                    "asr_auth_not_required",
                    "local ASR server does not require credentials",
                    "本地 ASR 服务不需要凭据。",
                    details={"provider": asr_provider.name},
                )
            )
        checks.append(_local_server_reachability_check(asr_provider))
    elif asr_provider is not None and asr_provider.kind == "remote":
        if asr_provider.auth.type == "bearer":
            checks.append(
                _env_key_check(
                    root_dir=root_dir,
                    env_key=asr_provider.env_key,
                    credential_id=asr_provider.credential_id,
                    provider_name="",
                    name="asr_env_key",
                    message_subject="ASR",
                )
            )
        else:
            checks.append(
                _check(
                    "asr_auth",
                    "FAIL",
                    "asr_remote_auth_not_bearer",
                    "remote ASR provider must use bearer auth in the first provider gateway version",
                    "远端 ASR provider 当前只支持 bearer 凭据。",
                    details={"provider": asr_provider.name, "auth_type": asr_provider.auth.type},
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

    active_profile = config.active_routing_profile
    routing_profile_warnings = []
    for profile in config.routing_profiles:
        routes = [("primary", profile.primary)] + [(f"fallback[{idx}]", item) for idx, item in enumerate(profile.fallback)]
        for route_name, route_item in routes:
            if profile.id == active_profile and route_name == "primary":
                continue
            route_provider = config.providers.get(route_item.provider)
            if route_provider is None:
                routing_profile_warnings.append(
                    {
                        "profile_id": profile.id,
                        "profile_name": profile.name,
                        "route": route_name,
                        "provider": route_item.provider,
                        "model": route_item.model,
                        "issue": "provider_missing",
                    }
                )
            elif route_item.model not in route_provider.models:
                routing_profile_warnings.append(
                    {
                        "profile_id": profile.id,
                        "profile_name": profile.name,
                        "route": route_name,
                        "provider": route_item.provider,
                        "model": route_item.model,
                        "issue": "model_not_listed",
                        "provider_models": route_provider.models,
                    }
                )
    if routing_profile_warnings:
        checks.append(
            _check(
                "routing_profiles",
                "WARN",
                "routing_profile_references_invalid",
                "some route profile references are unavailable",
                "部分 Route profile 引用了不可用的 provider 或 model，请检查 fallback 和未启用配置。",
                details={"references": routing_profile_warnings},
            )
        )

    if provider is not None:
        checks.append(
            _env_key_check(
                root_dir=root_dir,
                env_key=provider.env_key,
                credential_id=provider.credential_id or provider.name,
                provider_name=provider.name,
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
