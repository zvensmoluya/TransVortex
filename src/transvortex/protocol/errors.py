from __future__ import annotations

from typing import Any


class PipelineTaskError(RuntimeError):
    def __init__(self, task_id: str | None, error_info: dict[str, Any]) -> None:
        super().__init__(str(error_info.get("message", "")))
        self.task_id = task_id
        self.error_info = error_info


def error_info(
    *,
    code: str,
    error_type: str,
    message: str,
    stage: str | None = None,
    hint_zh: str = "",
    retryable: bool = False,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "code": code,
        "type": error_type,
        "stage": stage or "",
        "message": message,
        "hint_zh": hint_zh,
        "retryable": retryable,
        "details": details or {},
    }


def classify_exception(exc: Exception, *, stage: str | None = None) -> dict[str, Any]:
    message = str(exc)
    lowered = message.lower()
    if "task cancelled" in lowered:
        return error_info(
            code="task_cancelled",
            error_type="cancelled",
            stage=stage,
            message=message,
            hint_zh="任务已取消。",
            retryable=False,
        )
    if "task not found" in lowered:
        return error_info(
            code="task_not_found",
            error_type="input_error",
            stage=stage,
            message=message,
            hint_zh="找不到指定任务，请检查 task_id 或先用 tasks --json 查看任务列表。",
            retryable=False,
        )
    if "input file not found" in lowered or "input path is not a file" in lowered:
        return error_info(
            code="input_not_found",
            error_type="input_error",
            stage=stage,
            message=message,
            hint_zh="输入文件不存在或不是文件，请检查路径。",
            retryable=False,
        )
    if "missing environment variable" in lowered:
        return error_info(
            code="missing_env",
            error_type="config_error",
            stage=stage,
            message=message,
            hint_zh="缺少必要环境变量，请在 .env、系统环境变量或桌面端配置 key。",
            retryable=False,
        )
    if "required executable not found" in lowered:
        return error_info(
            code="missing_executable",
            error_type="environment_error",
            stage=stage,
            message=message,
            hint_zh="缺少必要命令行工具，请安装并加入 PATH。",
            retryable=False,
        )
    if "faster-whisper is required" in lowered:
        return error_info(
            code="missing_asr_dependency",
            error_type="environment_error",
            stage=stage,
            message=message,
            hint_zh="本地 ASR 缺少 faster-whisper，请安装 ASR 依赖或切换云端 ASR。",
            retryable=False,
        )
    if "provider preflight failed" in lowered:
        return error_info(
            code="provider_preflight_failed",
            error_type="provider_error",
            stage=stage,
            message=message,
            hint_zh="Provider 协议或 key 预检失败，请检查 provider 配置。",
            retryable=False,
        )
    if "provider not found" in lowered or "translation provider not found" in lowered:
        return error_info(
            code="provider_not_found",
            error_type="config_error",
            stage=stage,
            message=message,
            hint_zh="配置中找不到指定 provider，请检查 routing 或 --provider。",
            retryable=False,
        )
    if "missing or empty artifact" in lowered:
        return error_info(
            code="artifact_missing",
            error_type="artifact_error",
            stage=stage,
            message=message,
            hint_zh="任务中间产物缺失或为空，可以尝试 resume 重建。",
            retryable=True,
        )
    if "no subtitle segments parsed" in lowered:
        return error_info(
            code="no_segments",
            error_type="input_error",
            stage=stage,
            message=message,
            hint_zh="没有解析到可用字幕片段，请检查输入 SRT 或 segments 文件。",
            retryable=False,
        )
    if "gateway_timeout" in lowered or "http error 504" in lowered or "gateway timeout" in lowered:
        return error_info(
            code="provider_gateway_timeout",
            error_type="provider_timeout",
            stage=stage,
            message=message,
            hint_zh="Provider 网关超时，通常是网络、模型排队或请求过大导致。可以重试，或调低 chunk/context/reasoning。",
            retryable=True,
        )
    if "provider_timeout" in lowered or "timed out" in lowered:
        return error_info(
            code="provider_timeout",
            error_type="provider_timeout",
            stage=stage,
            message=message,
            hint_zh="Provider 请求超时，可以重试，或调低 chunk/context/reasoning。",
            retryable=True,
        )
    if any(marker in lowered for marker in ("bad_gateway", "service_unavailable", "provider_server_error")):
        return error_info(
            code="provider_retryable_http_error",
            error_type="provider_error",
            stage=stage,
            message=message,
            hint_zh="Provider 服务端或网关临时失败，可以重试。",
            retryable=True,
        )
    if "all translation routes failed" in lowered:
        return error_info(
            code="translation_failed",
            error_type="provider_error",
            stage=stage,
            message=message,
            hint_zh="所有翻译路由都失败了，请检查网络、key、模型名和 provider 配置。",
            retryable=True,
        )
    return error_info(
        code="runtime_error",
        error_type="runtime_error",
        stage=stage,
        message=message,
        hint_zh="任务运行失败，请查看 events.jsonl 和 stderr 日志。",
        retryable=False,
    )
