from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml

from ..http import close_shared_httpx_clients
from .models import NetworkConfig


NETWORK_MODES = {"system", "direct", "local_proxy"}


def pipeline_file_version(path: Path) -> dict[str, int] | None:
    if not path.exists():
        return None
    stat = path.stat()
    return {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size}


def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        payload = yaml.safe_load(handle) or {}
    if not isinstance(payload, dict):
        raise ValueError("pipeline.yaml must contain a YAML object")
    return payload


def _write_yaml(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump(payload, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )


def _expected_version(value: Any) -> dict[str, int] | None:
    if not isinstance(value, dict) or not value:
        return None
    try:
        return {
            "mtime_ns": int(value.get("mtime_ns", -1)),
            "size": int(value.get("size", -1)),
        }
    except (TypeError, ValueError):
        return {"mtime_ns": -1, "size": -1}


def _check_expected_version(path: Path, expected_version: Any) -> None:
    expected = _expected_version(expected_version)
    if expected is None:
        return
    current = pipeline_file_version(path)
    if current == expected:
        return
    raise ValueError(
        json.dumps(
            {
                "status": "FAIL",
                "code": "network_config_conflict",
                "message": "Network config changed on disk",
                "hint_zh": "网络设置已被其它窗口或进程修改，请刷新后重试。",
                "details": {"expected": expected, "current": current},
            },
            ensure_ascii=False,
        )
    )


def normalize_network_config(*, mode: Any, proxy_port: Any = 0) -> NetworkConfig:
    normalized_mode = str(mode or "system").strip().lower()
    if normalized_mode not in NETWORK_MODES:
        raise ValueError("网络连接方式无效，请选择跟随系统、直连或本地代理。")
    try:
        normalized_port = int(proxy_port or 0)
    except (TypeError, ValueError) as exc:
        raise ValueError("本地代理端口必须是 1 到 65535 之间的数字。") from exc
    if normalized_port < 0 or normalized_port > 65535:
        raise ValueError("本地代理端口必须是 1 到 65535 之间的数字。")
    if normalized_mode == "local_proxy" and normalized_port == 0:
        raise ValueError("使用本地代理时需要填写代理端口。")
    return NetworkConfig(mode=normalized_mode, proxy_port=normalized_port)


def save_network_config(
    *,
    root_dir: Path,
    mode: Any,
    proxy_port: Any = 0,
    expected_version: dict[str, Any] | None = None,
) -> dict[str, Any]:
    pipeline_file = root_dir / "pipeline.yaml"
    _check_expected_version(pipeline_file, expected_version)
    network = normalize_network_config(mode=mode, proxy_port=proxy_port)
    payload = _read_yaml(pipeline_file)
    row: dict[str, Any] = {"mode": network.mode}
    if network.proxy_port > 0:
        row["proxy_port"] = network.proxy_port
    payload["network"] = row
    _write_yaml(pipeline_file, payload)
    close_shared_httpx_clients()
    return {
        "ok": True,
        "network": {"mode": network.mode, "proxy_port": network.proxy_port},
        "pipeline_file": str(pipeline_file),
        "pipeline_file_version": pipeline_file_version(pipeline_file),
    }
