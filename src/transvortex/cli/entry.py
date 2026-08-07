from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from ..artifacts.result_workspace import (
    open_task_result,
    promote_task_memory_entries,
    reexport_task,
    save_task_segments,
    update_task_memory_entry,
)
from ..artifacts.catalog import TaskCatalog
from ..artifacts.runtime import TaskRuntime
from ..artifacts.task_store import TaskStore
from ..app.asr_admin import activate_asr_resources
from ..app.asr_operations import AsrOperationError, AsrOperationManager
from ..app.config import apply_route_overrides, load_app_config, resolve_providers_file
from ..app.credentials import (
    auth_file_path,
    delete_auth_credential,
    provider_credential_id,
    read_auth_credentials,
    resolve_credential,
    resolve_provider_credential,
    write_auth_credential,
)
from ..app.desktop_api import auth_list_payload, auth_status_payload, config_payload, task_payload
from ..app.desktop_requests import (
    RequestValidationError,
    load_resume_request,
    load_run_request,
    resume_request_from_payload,
    resume_request_from_flags,
    resume_request_to_payload,
    run_request_from_payload,
    run_request_from_flags,
    run_request_to_payload,
)
from ..app.doctor import doctor_report, format_doctor_report
from ..app.asr_runtime import (
    asr_provider_endpoint_policy_code,
    probe_external_accelerator,
    probe_external_model,
)
from ..app.asr_testing import run_asr_connection_test
from ..formats.exporter import export_ass, export_lrc, export_srt, export_vtt, subtitle_delivery_report
from ..formats.srt import parse_srt_file
from ..app.models import Segment
from ..core.orchestrator import (
    create_pipeline_task,
    execute_pipeline_task,
    queue_resume_task,
    resume_pipeline,
    run_pipeline,
    task_status_json,
)
from ..providers.probe import probe_exit_code, probe_provider
from ..memory.exporter import (
    MemoryPresetBootstrapOptions,
    MemoryPresetExportOptions,
    bootstrap_memory_preset,
    export_runtime_memory_to_preset,
)
from ..memory.collections import (
    build_selected_collections_snapshot,
    collection_payload,
    collection_store_for_config,
    collection_summary,
)
from ..providers.admin import (
    custom_adapter_template_payload,
    delete_provider_config,
    fetch_provider_models,
    protocol_templates_payload,
    provider_presets_payload,
    provider_templates_payload,
    providers_file_version,
    run_provider_connection_test,
    save_provider_config,
    save_provider_routing,
)
from ..prompts.asr_admin import (
    delete_asr_prompt_profile,
    list_asr_prompt_profiles,
    save_asr_prompt_profile,
)
from ..protocol.agent_protocol import agent_info_payload
from ..protocol.agent_setup import (
    SETUP_SCOPES,
    provider_test_contract_payload,
    provider_test_error_payload,
    setup_failure_payload,
    setup_plan_payload,
    setup_verify_payload,
)
from ..protocol.errors import PipelineTaskError, classify_exception
from ..protocol.redaction import redact
from ..utils import read_json, to_plain, utc_now_iso
from ..utils import read_jsonl


def _common_overrides(args: argparse.Namespace) -> dict:
    return {
        "chunk_seconds": args.chunk_seconds,
        "chunk_overlap_seconds": args.chunk_overlap_seconds,
        "translation_batch_size": args.translation_batch_size,
        "default_concurrency": args.concurrency,
        "asr_provider": getattr(args, "asr_provider", None),
        "asr_model": args.asr_model,
        "asr_audio_track": getattr(args, "asr_audio_track", None),
        "asr_prompt_profile": getattr(args, "asr_prompt_profile", None),
        "asr_prompt_text": getattr(args, "asr_prompt_text", None),
        "asr_prompt_enabled": getattr(args, "asr_prompt_enabled", None),
        "asr_prompt_include_previous_text": getattr(args, "asr_prompt_include_previous_text", None),
        "asr_prompt_max_chars": getattr(args, "asr_prompt_max_chars", None),
        "source_mode": getattr(args, "source_mode", None),
        "subtitle_track": getattr(args, "subtitle_track", None),
        "output_format": getattr(args, "output_format", None),
        "subtitle_ass_style": _subtitle_ass_style_overrides(args),
        "translation_style_preset": getattr(args, "translation_style_preset", None),
        "translation_style_prompt": getattr(args, "translation_style_prompt", None),
        "translation_chunk_lines": getattr(args, "translation_chunk_lines", None),
        "translation_context_before_lines": getattr(args, "translation_context_before_lines", None),
        "translation_context_after_lines": getattr(args, "translation_context_after_lines", None),
        "translation_repair_enabled": getattr(args, "translation_repair_enabled", None),
        "translation_batching_mode": getattr(args, "translation_batching_mode", None),
        "translation_min_chunk_lines": getattr(args, "translation_min_chunk_lines", None),
        "translation_chunking_mode": getattr(args, "translation_chunking_mode", None),
        "translation_experiment_logging_enabled": getattr(args, "translation_experiment_logging_enabled", None),
        "translation_experiment_label": getattr(args, "translation_experiment_label", None),
        "provider_timeout_seconds": getattr(args, "provider_timeout_seconds", None),
        "provider_retry": getattr(args, "provider_retry", None),
        "provider_http2": getattr(args, "provider_http2", None),
        "provider_streaming_enabled": getattr(args, "provider_streaming_enabled", None),
        "provider_connect_timeout_seconds": getattr(args, "provider_connect_timeout_seconds", None),
        "provider_read_timeout_seconds": getattr(args, "provider_read_timeout_seconds", None),
        "subtitle_quality_mode": getattr(args, "subtitle_quality_mode", None),
        "subtitle_compression_enabled": getattr(args, "subtitle_compression_enabled", None),
        "subtitle_reflow_enabled": getattr(args, "subtitle_reflow_enabled", None),
        "memory_enabled": getattr(args, "memory_enabled", None),
        "memory_bootstrap_enabled": getattr(args, "memory_bootstrap_enabled", None),
        "memory_inject_enabled": getattr(args, "memory_inject_enabled", None),
        "memory_patch_enabled": getattr(args, "memory_patch_enabled", None),
        "memory_intensity": getattr(args, "memory_intensity", None),
        "memory_patch_window_chunks": getattr(args, "memory_patch_window_chunks", None),
        "memory_collections": _parse_memory_collection_arg(getattr(args, "memory_collection", None)),
        "memory_presets": _parse_memory_preset_arg(getattr(args, "memory_preset", None)),
    }


def _parse_memory_preset_arg(raw: str | None) -> list[dict[str, str]] | None:
    if raw is None:
        return None
    out: list[dict[str, str]] = []
    for token in str(raw).split(","):
        token = token.strip()
        if not token:
            continue
        if ":" in token:
            ref_id, override = token.split(":", 1)
            out.append({"id": ref_id.strip(), "override_status": override.strip()})
        else:
            out.append({"id": token})
    return out


def _parse_memory_collection_arg(raw: str | None) -> list[dict[str, str]] | None:
    if raw is None:
        return None
    return [
        {"id": token.strip()}
        for token in str(raw).split(",")
        if token.strip()
    ]


def _subtitle_ass_style_overrides(args: argparse.Namespace) -> dict[str, object] | None:
    out: dict[str, object] = {}
    bilingual_order = getattr(args, "subtitle_bilingual_order", None)
    if bilingual_order is not None:
        out["bilingual_order"] = bilingual_order
    prefer_single_line = getattr(args, "subtitle_prefer_single_line", None)
    if prefer_single_line is not None:
        out["prefer_single_line"] = prefer_single_line
    return out or None


def _load_cli_segments_input(path: Path) -> list[Segment]:
    if path.suffix.lower() == ".srt":
        return parse_srt_file(path)
    rows = read_jsonl(path)
    segments: list[Segment] = []
    for idx, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            continue
        payload = dict(row)
        payload.setdefault("id", idx)
        if "text_src" not in payload and "text" in payload:
            payload["text_src"] = payload.pop("text")
        segments.append(Segment(**payload))
    return sorted(segments, key=lambda item: item.id)


def _add_providers_file_arg(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--providers-file", default=None, help="Optional providers config file path")


_CURRENT_ROOT: Path | None = None


def _print_json(data: object) -> None:
    payload = redact(data, root_dir=_CURRENT_ROOT)
    print(json.dumps(payload, ensure_ascii=True, indent=2), flush=True)


def _print_jsonl_event(event: dict[str, Any]) -> None:
    payload = redact(event, root_dir=_CURRENT_ROOT)
    print(json.dumps(payload, ensure_ascii=True), flush=True)


def _print_jsonl_error(task_id: str | None, err: dict[str, Any]) -> None:
    event = {
        "type": "error",
        "task_id": task_id or "",
        "created_at": utc_now_iso(),
        "level": "error",
        "stage": err.get("stage", ""),
        "message": err.get("message", ""),
        "details": {"error_info": err},
    }
    _print_jsonl_event(event)


def _error_payload(task_id: str | None, err: dict[str, Any]) -> dict[str, Any]:
    return {
        "ok": False,
        "task_id": task_id,
        "status": "FAILED",
        "error": err.get("message"),
        "error_info": err,
    }


def _add_pipeline_override_args(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--chunk-seconds", type=int, default=None)
    subparser.add_argument("--chunk-overlap-seconds", type=int, default=None)
    subparser.add_argument("--translation-batch-size", type=int, default=None)
    subparser.add_argument("--concurrency", type=int, default=None)
    subparser.add_argument(
        "--asr-engine",
        dest="asr_provider",
        default=None,
        help="Selected ASR engine override",
    )
    subparser.add_argument("--asr-model", default=None, help="ASR model override for the selected ASR engine")
    subparser.add_argument("--asr-audio-track", default=None)
    subparser.add_argument("--asr-prompt-profile", default=None)
    subparser.add_argument("--asr-prompt-text", default=None)
    subparser.add_argument("--asr-prompt-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--asr-prompt-include-previous-text", choices=["true", "false"], default=None)
    subparser.add_argument("--asr-prompt-max-chars", type=int, default=None)
    subparser.add_argument("--source-mode", choices=["auto", "asr", "embedded_subtitle"], default=None)
    subparser.add_argument("--subtitle-track", default=None)
    subparser.add_argument("--output-format", choices=["srt", "ass", "vtt", "webvtt", "lrc", "both"], default=None)
    subparser.add_argument("--translation-style-preset", default=None)
    subparser.add_argument("--translation-style-prompt", default=None)
    subparser.add_argument("--translation-chunk-lines", type=int, default=None)
    subparser.add_argument("--translation-context-before-lines", type=int, default=None)
    subparser.add_argument("--translation-context-after-lines", type=int, default=None)
    subparser.add_argument("--translation-repair-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--translation-batching-mode", choices=["fixed", "adaptive"], default=None)
    subparser.add_argument("--translation-min-chunk-lines", type=int, default=None)
    subparser.add_argument("--translation-chunking-mode", choices=["capacity_aware", "fixed"], default=None)
    subparser.add_argument("--translation-experiment-logging-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--translation-experiment-label", default=None)
    subparser.add_argument("--provider-timeout-seconds", type=int, default=None)
    subparser.add_argument("--provider-retry", type=int, default=None)
    subparser.add_argument("--provider-http2", choices=["true", "false"], default=None)
    subparser.add_argument("--provider-streaming-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--provider-connect-timeout-seconds", type=float, default=None)
    subparser.add_argument("--provider-read-timeout-seconds", type=float, default=None)
    subparser.add_argument("--subtitle-quality-mode", choices=["off", "conservative", "balanced"], default=None)
    subparser.add_argument("--subtitle-compression-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--subtitle-reflow-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--subtitle-bilingual-order", choices=["target_source", "source_target"], default=None)
    subparser.add_argument("--subtitle-prefer-single-line", choices=["true", "false"], default=None)
    subparser.add_argument("--memory-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--memory-bootstrap-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--memory-inject-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--memory-patch-enabled", choices=["true", "false"], default=None)
    subparser.add_argument("--memory-intensity", choices=["low", "auto", "high", "max"], default=None)
    subparser.add_argument("--memory-patch-window-chunks", type=int, default=None)
    subparser.add_argument(
        "--memory-collection",
        default=None,
        help="Comma-separated persistent memory collection ids to snapshot for this task",
    )
    subparser.add_argument(
        "--memory-preset",
        default=None,
        help="Comma-separated preset ids; append :status to override (e.g. rezero,anime-honorifics:locked)",
    )


def _add_route_override_args(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--provider", default=None, help="Translation provider override")
    subparser.add_argument("--model", default=None, help="Translation model override")


def _task_payload(task, artifacts_dir: Path | None = None) -> dict[str, Any]:
    return task_payload(task, artifacts_dir)


def _capability_payload(name: str, task, artifacts_dir: Path | None = None) -> dict[str, Any]:
    payload = _task_payload(task, artifacts_dir)
    payload["capability"] = name
    return payload


def _config_show_payload(root: Path, providers_file: Path | None) -> dict[str, Any]:
    return config_payload(root, providers_file)


def _auth_status_payload(root: Path, providers_file: Path | None) -> dict[str, Any]:
    return auth_status_payload(root, providers_file)


def _auth_list_payload() -> dict[str, Any]:
    return auth_list_payload()


def _read_auth_set_value(args: argparse.Namespace) -> str:
    if args.api_key and args.stdin:
        raise ValueError("Use only one of --api-key or --stdin")
    if args.stdin:
        value = sys.stdin.read().strip()
    elif args.api_key is not None:
        value = args.api_key.strip()
    else:
        value = getpass.getpass("API key: ").strip()
    if not value:
        raise ValueError("credential value is required")
    return value


def _read_json_arg(raw: str) -> dict[str, Any]:
    if raw.startswith("@"):
        raw = Path(raw[1:]).read_text(encoding="utf-8")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("JSON payload must be an object")
    return payload


def _request_path_arg(value: str | None) -> Path | None:
    return Path(value).resolve() if value else None


def _load_run_request_arg(value: str | None):
    if not value:
        raise RequestValidationError("request JSON is required")
    raw = str(value)
    if raw.lstrip().startswith("{"):
        return run_request_from_payload(json.loads(raw))
    return load_run_request(Path(raw).resolve())


def _load_resume_request_arg(value: str | None):
    if not value:
        raise RequestValidationError("request JSON is required")
    raw = str(value)
    if raw.lstrip().startswith("{"):
        return resume_request_from_payload(json.loads(raw))
    return load_resume_request(Path(raw).resolve())


def _optional_path_arg(value: str | None) -> Path | None:
    return Path(value).resolve() if value else None


def _output_path_from_request(value: str) -> Path | None:
    return Path(value).resolve() if value else None


def _append_optional(args: list[str], flag: str, value: Any) -> None:
    if value is None:
        return
    if isinstance(value, bool):
        if value:
            args.append(flag)
        return
    raw = str(value)
    if raw:
        args.extend([flag, raw])


def _append_common_overrides_to_args(args: list[str], ns: argparse.Namespace) -> None:
    def bool_text(value: Any) -> str | None:
        if isinstance(value, bool):
            return "true" if value else "false"
        return value

    mapping = [
        ("--chunk-seconds", getattr(ns, "chunk_seconds", None)),
        ("--chunk-overlap-seconds", getattr(ns, "chunk_overlap_seconds", None)),
        ("--translation-batch-size", getattr(ns, "translation_batch_size", None)),
        ("--concurrency", getattr(ns, "concurrency", None)),
        ("--asr-engine", getattr(ns, "asr_provider", None)),
        ("--asr-model", getattr(ns, "asr_model", None)),
        ("--asr-audio-track", getattr(ns, "asr_audio_track", None)),
        ("--asr-prompt-profile", getattr(ns, "asr_prompt_profile", None)),
        ("--asr-prompt-text", getattr(ns, "asr_prompt_text", None)),
        ("--asr-prompt-enabled", bool_text(getattr(ns, "asr_prompt_enabled", None))),
        ("--asr-prompt-include-previous-text", bool_text(getattr(ns, "asr_prompt_include_previous_text", None))),
        ("--asr-prompt-max-chars", getattr(ns, "asr_prompt_max_chars", None)),
        ("--source-mode", getattr(ns, "source_mode", None)),
        ("--subtitle-track", getattr(ns, "subtitle_track", None)),
        ("--output-format", getattr(ns, "output_format", None)),
        ("--subtitle-bilingual-order", getattr(ns, "subtitle_bilingual_order", None)),
        ("--subtitle-prefer-single-line", getattr(ns, "subtitle_prefer_single_line", None)),
        ("--translation-style-preset", getattr(ns, "translation_style_preset", None)),
        ("--translation-style-prompt", getattr(ns, "translation_style_prompt", None)),
        ("--translation-chunk-lines", getattr(ns, "translation_chunk_lines", None)),
        ("--translation-context-before-lines", getattr(ns, "translation_context_before_lines", None)),
        ("--translation-context-after-lines", getattr(ns, "translation_context_after_lines", None)),
        ("--translation-repair-enabled", getattr(ns, "translation_repair_enabled", None)),
        ("--translation-batching-mode", getattr(ns, "translation_batching_mode", None)),
        ("--translation-min-chunk-lines", getattr(ns, "translation_min_chunk_lines", None)),
        ("--translation-chunking-mode", getattr(ns, "translation_chunking_mode", None)),
        ("--translation-experiment-logging-enabled", getattr(ns, "translation_experiment_logging_enabled", None)),
        ("--translation-experiment-label", getattr(ns, "translation_experiment_label", None)),
        ("--provider-timeout-seconds", getattr(ns, "provider_timeout_seconds", None)),
        ("--provider-retry", getattr(ns, "provider_retry", None)),
        ("--provider-http2", getattr(ns, "provider_http2", None)),
        ("--provider-streaming-enabled", getattr(ns, "provider_streaming_enabled", None)),
        ("--provider-connect-timeout-seconds", getattr(ns, "provider_connect_timeout_seconds", None)),
        ("--provider-read-timeout-seconds", getattr(ns, "provider_read_timeout_seconds", None)),
        ("--subtitle-quality-mode", getattr(ns, "subtitle_quality_mode", None)),
        ("--subtitle-compression-enabled", getattr(ns, "subtitle_compression_enabled", None)),
        ("--subtitle-reflow-enabled", getattr(ns, "subtitle_reflow_enabled", None)),
        ("--memory-enabled", getattr(ns, "memory_enabled", None)),
        ("--memory-bootstrap-enabled", getattr(ns, "memory_bootstrap_enabled", None)),
        ("--memory-inject-enabled", getattr(ns, "memory_inject_enabled", None)),
        ("--memory-patch-enabled", getattr(ns, "memory_patch_enabled", None)),
        ("--memory-intensity", getattr(ns, "memory_intensity", None)),
        ("--memory-patch-window-chunks", getattr(ns, "memory_patch_window_chunks", None)),
        ("--memory-collection", getattr(ns, "memory_collection", None)),
        ("--memory-preset", getattr(ns, "memory_preset", None)),
    ]
    for flag, value in mapping:
        _append_optional(args, flag, value)


def _append_request_overrides_to_args(args: list[str], overrides: dict[str, Any]) -> None:
    def bool_text(value: Any) -> str | None:
        if isinstance(value, bool):
            return "true" if value else "false"
        return value

    subtitle_style = overrides.get("subtitle_ass_style") if isinstance(overrides.get("subtitle_ass_style"), dict) else {}
    mapping = [
        ("--chunk-seconds", overrides.get("chunk_seconds")),
        ("--chunk-overlap-seconds", overrides.get("chunk_overlap_seconds")),
        ("--translation-batch-size", overrides.get("translation_batch_size")),
        ("--concurrency", overrides.get("default_concurrency")),
        ("--asr-engine", overrides.get("asr_provider")),
        ("--asr-model", overrides.get("asr_model")),
        ("--asr-audio-track", overrides.get("asr_audio_track")),
        ("--asr-prompt-profile", overrides.get("asr_prompt_profile")),
        ("--asr-prompt-text", overrides.get("asr_prompt_text")),
        ("--asr-prompt-enabled", bool_text(overrides.get("asr_prompt_enabled"))),
        ("--asr-prompt-include-previous-text", bool_text(overrides.get("asr_prompt_include_previous_text"))),
        ("--asr-prompt-max-chars", overrides.get("asr_prompt_max_chars")),
        ("--source-mode", overrides.get("source_mode")),
        ("--subtitle-track", overrides.get("subtitle_track")),
        ("--output-format", overrides.get("output_format")),
        ("--subtitle-bilingual-order", subtitle_style.get("bilingual_order")),
        ("--subtitle-prefer-single-line", bool_text(subtitle_style.get("prefer_single_line"))),
        ("--translation-style-preset", overrides.get("translation_style_preset")),
        ("--translation-style-prompt", overrides.get("translation_style_prompt")),
        ("--translation-chunk-lines", overrides.get("translation_chunk_lines")),
        ("--translation-context-before-lines", overrides.get("translation_context_before_lines")),
        ("--translation-context-after-lines", overrides.get("translation_context_after_lines")),
        ("--translation-repair-enabled", bool_text(overrides.get("translation_repair_enabled"))),
        ("--translation-batching-mode", overrides.get("translation_batching_mode")),
        ("--translation-min-chunk-lines", overrides.get("translation_min_chunk_lines")),
        ("--translation-chunking-mode", overrides.get("translation_chunking_mode")),
        ("--translation-experiment-logging-enabled", bool_text(overrides.get("translation_experiment_logging_enabled"))),
        ("--translation-experiment-label", overrides.get("translation_experiment_label")),
        ("--provider-timeout-seconds", overrides.get("provider_timeout_seconds")),
        ("--provider-retry", overrides.get("provider_retry")),
        ("--provider-http2", bool_text(overrides.get("provider_http2"))),
        ("--provider-streaming-enabled", bool_text(overrides.get("provider_streaming_enabled"))),
        ("--provider-connect-timeout-seconds", overrides.get("provider_connect_timeout_seconds")),
        ("--provider-read-timeout-seconds", overrides.get("provider_read_timeout_seconds")),
        ("--subtitle-quality-mode", overrides.get("subtitle_quality_mode")),
        ("--subtitle-compression-enabled", bool_text(overrides.get("subtitle_compression_enabled"))),
        ("--subtitle-reflow-enabled", bool_text(overrides.get("subtitle_reflow_enabled"))),
        ("--memory-enabled", bool_text(overrides.get("memory_enabled"))),
        ("--memory-bootstrap-enabled", bool_text(overrides.get("memory_bootstrap_enabled"))),
        ("--memory-inject-enabled", bool_text(overrides.get("memory_inject_enabled"))),
        ("--memory-patch-enabled", bool_text(overrides.get("memory_patch_enabled"))),
        ("--memory-intensity", overrides.get("memory_intensity")),
        ("--memory-patch-window-chunks", overrides.get("memory_patch_window_chunks")),
        ("--memory-collection", _memory_collections_arg(overrides.get("memory_collections"))),
        ("--memory-preset", _memory_presets_arg(overrides.get("memory_presets"))),
    ]
    for flag, value in mapping:
        _append_optional(args, flag, value)


def _memory_presets_arg(value: Any) -> str | None:
    if not isinstance(value, list):
        return None
    tokens: list[str] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        preset_id = str(item.get("id") or "").strip()
        if not preset_id:
            continue
        override = str(item.get("override_status") or "").strip()
        tokens.append(f"{preset_id}:{override}" if override else preset_id)
    return ",".join(tokens) or None


def _memory_collections_arg(value: Any) -> str | None:
    if not isinstance(value, list):
        return None
    tokens = [
        str(item.get("id") or "").strip()
        for item in value
        if isinstance(item, dict) and str(item.get("id") or "").strip()
    ]
    return ",".join(tokens) or None


def _request_mode_business_flags(ns: argparse.Namespace, command: str) -> list[str]:
    flag_names = {
        "input": "--input",
        "input_type": "--input-type",
        "src": "--src",
        "tgt": "--tgt",
        "bilingual": "--bilingual",
        "output": "--output",
        "provider": "--provider",
        "model": "--model",
        "chunk_seconds": "--chunk-seconds",
        "chunk_overlap_seconds": "--chunk-overlap-seconds",
        "translation_batch_size": "--translation-batch-size",
        "concurrency": "--concurrency",
        "asr_provider": "--asr-engine",
        "asr_model": "--asr-model",
        "asr_audio_track": "--asr-audio-track",
        "asr_prompt_profile": "--asr-prompt-profile",
        "asr_prompt_text": "--asr-prompt-text",
        "asr_prompt_enabled": "--asr-prompt-enabled",
        "asr_prompt_include_previous_text": "--asr-prompt-include-previous-text",
        "asr_prompt_max_chars": "--asr-prompt-max-chars",
        "source_mode": "--source-mode",
        "subtitle_track": "--subtitle-track",
        "output_format": "--output-format",
        "subtitle_bilingual_order": "--subtitle-bilingual-order",
        "subtitle_prefer_single_line": "--subtitle-prefer-single-line",
        "translation_style_preset": "--translation-style-preset",
        "translation_style_prompt": "--translation-style-prompt",
        "translation_chunk_lines": "--translation-chunk-lines",
        "translation_context_before_lines": "--translation-context-before-lines",
        "translation_context_after_lines": "--translation-context-after-lines",
        "translation_repair_enabled": "--translation-repair-enabled",
        "translation_batching_mode": "--translation-batching-mode",
        "translation_min_chunk_lines": "--translation-min-chunk-lines",
        "translation_chunking_mode": "--translation-chunking-mode",
        "translation_experiment_logging_enabled": "--translation-experiment-logging-enabled",
        "translation_experiment_label": "--translation-experiment-label",
        "provider_timeout_seconds": "--provider-timeout-seconds",
        "provider_retry": "--provider-retry",
        "provider_http2": "--provider-http2",
        "provider_streaming_enabled": "--provider-streaming-enabled",
        "provider_connect_timeout_seconds": "--provider-connect-timeout-seconds",
        "provider_read_timeout_seconds": "--provider-read-timeout-seconds",
        "subtitle_quality_mode": "--subtitle-quality-mode",
        "subtitle_compression_enabled": "--subtitle-compression-enabled",
        "subtitle_reflow_enabled": "--subtitle-reflow-enabled",
        "memory_enabled": "--memory-enabled",
        "memory_bootstrap_enabled": "--memory-bootstrap-enabled",
        "memory_inject_enabled": "--memory-inject-enabled",
        "memory_patch_enabled": "--memory-patch-enabled",
        "memory_intensity": "--memory-intensity",
        "memory_patch_window_chunks": "--memory-patch-window-chunks",
        "memory_collection": "--memory-collection",
        "memory_preset": "--memory-preset",
    }
    if command == "resume":
        flag_names.pop("input", None)
        flag_names.pop("input_type", None)
        flag_names.pop("src", None)
        flag_names.pop("tgt", None)
        flag_names.pop("bilingual", None)
        flag_names["task_id"] = "--task-id"
    provided: list[str] = []
    for name, flag in flag_names.items():
        value = getattr(ns, name, None)
        if value is True or (value not in {None, False, ""}):
            provided.append(flag)
    return provided


def _raise_request_validation(message: str) -> None:
    raise RequestValidationError(message)


def _spawn_detached_worker(
    *,
    root: Path,
    task_dir: Path,
    worker_args: list[str],
) -> dict[str, Any]:
    log_dir = task_dir / "worker"
    log_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = log_dir / "stdout.log"
    stderr_path = log_dir / "stderr.log"
    stdout = stdout_path.open("ab")
    stderr = stderr_path.open("ab")
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PYTHONUTF8", "1")
    try:
        proc = subprocess.Popen(
            [sys.executable, "-m", "transvortex.cli", "--root", str(root), *worker_args],
            cwd=root,
            stdout=stdout,
            stderr=stderr,
            stdin=subprocess.DEVNULL,
            close_fds=False,
            creationflags=creationflags,
            env=env,
        )
    finally:
        stdout.close()
        stderr.close()
    return {
        "pid": proc.pid,
        "stdout_log": str(stdout_path),
        "stderr_log": str(stderr_path),
    }


def _detach_response(
    *,
    task_id: str,
    artifacts_dir: Path,
    worker: dict[str, Any],
    command: str,
) -> dict[str, Any]:
    task_dir = artifacts_dir / task_id
    return {
        "ok": True,
        "task_id": task_id,
        "status": "QUEUED",
        "detached": True,
        "terminal": False,
        "message": "Task queued; follow events or status for the terminal result.",
        "task_dir": str(task_dir),
        "worker": worker,
        "next_commands": {
            "status": f"transvortex status --task-id {task_id} --json",
            "events": f"transvortex events --task-id {task_id} --follow",
            "cancel": f"transvortex cancel --task-id {task_id} --json",
        },
        "command": command,
    }


def _task_and_artifacts(root: Path, providers_file: Path | None, task_id: str):
    config = load_app_config(root_dir=root, providers_file=providers_file)
    store = TaskStore(config.pipeline.artifacts_dir)
    return store.load_task(task_id), config.pipeline.artifacts_dir


def _runtime_for(root: Path, providers_file: Path | None) -> TaskRuntime:
    config = load_app_config(root_dir=root, providers_file=providers_file)
    return TaskRuntime(config.pipeline.artifacts_dir)


def _print_task_json(root: Path, providers_file: Path | None, task_id: str, *, capability: str | None = None) -> None:
    task, artifacts_dir = _task_and_artifacts(root, providers_file, task_id)
    payload = _task_payload(task, artifacts_dir) if capability is None else _capability_payload(capability, task, artifacts_dir)
    _print_json(payload)


def _print_task_json_or_exit(root: Path, providers_file: Path | None, task_id: str, *, capability: str | None = None) -> None:
    _run_or_exit(
        lambda: _print_task_json(root, providers_file, task_id, capability=capability),
        json_mode=True,
        stream_events=False,
        task_id_hint=task_id,
    )


def _handle_pipeline_error(
    exc: Exception,
    *,
    json_mode: bool,
    stream_events: bool,
    task_id_hint: str | None = None,
) -> None:
    if isinstance(exc, PipelineTaskError):
        task_id = exc.task_id or task_id_hint
        err = exc.error_info
    else:
        task_id = task_id_hint
        err = classify_exception(exc)
    if json_mode:
        _print_json(_error_payload(task_id, err))
    elif stream_events and not isinstance(exc, PipelineTaskError):
        _print_jsonl_error(task_id, err)
    elif not stream_events:
        print(err.get("message", str(exc)), file=sys.stderr)
    raise SystemExit(1)


def _run_or_exit(fn, *, json_mode: bool, stream_events: bool, task_id_hint: str | None = None):
    try:
        return fn()
    except Exception as exc:  # noqa: BLE001 - converted to stable CLI error contract
        _handle_pipeline_error(exc, json_mode=json_mode, stream_events=stream_events, task_id_hint=task_id_hint)


def _mark_task_failed(root: Path, providers_file: Path | None, task_id: str, err: dict[str, Any]) -> None:
    try:
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        store.update_task_status(task_id, "FAILED", error=err.get("message"), error_info=err)
        store.append_event(
            task_id,
            "error",
            stage=err.get("stage") or "QUEUED",
            message=err.get("message", ""),
            level="error",
            details={"error_info": err},
        )
    except Exception:
        pass


def _handle_detached_worker_error(
    exc: Exception,
    *,
    root: Path,
    providers_file: Path | None,
    task_id: str,
    json_mode: bool,
) -> None:
    err = classify_exception(RuntimeError(f"Detached worker start failed: {exc}"))
    _mark_task_failed(root, providers_file, task_id, err)
    _handle_pipeline_error(PipelineTaskError(task_id, err), json_mode=json_mode, stream_events=False)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="transvortex")
    parser.add_argument(
        "--root",
        default=".",
        help="Project/config root (installed Windows app: %LOCALAPPDATA%\\TransVortex\\Config)",
    )
    public_commands = (
        "{agent-info,run,resume,status,events,cancel,tasks,doctor,config,catalog,"
        "probe-provider,provider,auth,result,memory,runtime,reexport,asr,translate,export}"
    )
    sub = parser.add_subparsers(dest="command", required=True, metavar=public_commands)

    agent_p = sub.add_parser("agent-info", help="Show machine-readable agent protocol information")
    agent_p.add_argument("--json", action="store_true", help="Print machine-readable protocol information")

    run_p = sub.add_parser("run", help="Run a new task")
    _add_providers_file_arg(run_p)
    run_p.add_argument("--request-json", default=None, help="Desktop/API request JSON file")
    run_p.add_argument("--input", help="Input video file")
    run_p.add_argument("--input-type", choices=["video", "srt", "video_asr_translate", "srt_translate"], default=None)
    run_p.add_argument("--src", help="Source language")
    run_p.add_argument("--tgt", help="Target language")
    run_p.add_argument("--bilingual", action="store_true", help="Output bilingual subtitle")
    run_p.add_argument("--output", help="Output subtitle file path")
    _add_pipeline_override_args(run_p)
    _add_route_override_args(run_p)
    run_p.add_argument("--json", action="store_true", help="Print machine-readable task status")
    run_p.add_argument("--stream-events", action="store_true", help="Stream task events as JSONL")
    run_p.add_argument("--detach", action="store_true", help="Start task in a detached worker and return immediately")

    resume_p = sub.add_parser("resume", help="Resume an existing task")
    _add_providers_file_arg(resume_p)
    resume_p.add_argument("--request-json", default=None, help="Desktop/API request JSON file")
    resume_p.add_argument("--task-id")
    resume_p.add_argument("--output", help="Optional output override")
    _add_pipeline_override_args(resume_p)
    _add_route_override_args(resume_p)
    resume_p.add_argument("--json", action="store_true", help="Print machine-readable task status")
    resume_p.add_argument("--stream-events", action="store_true", help="Stream task events as JSONL")
    resume_p.add_argument("--detach", action="store_true", help="Resume task in a detached worker and return immediately")

    status_p = sub.add_parser("status", help="Show task status")
    _add_providers_file_arg(status_p)
    status_p.add_argument("--task-id", required=True)
    status_p.add_argument("--json", action="store_true", help="Print machine-readable task status")

    events_p = sub.add_parser("events", help="Print task events as JSONL")
    _add_providers_file_arg(events_p)
    events_p.add_argument("--task-id", required=True)
    events_p.add_argument("--follow", action="store_true", help="Follow events until the task reaches a terminal state")

    cancel_p = sub.add_parser("cancel", help="Request cancellation for a task")
    _add_providers_file_arg(cancel_p)
    cancel_p.add_argument("--task-id", required=True)
    cancel_p.add_argument("--force", action="store_true", help="Terminate the active worker for this task")
    cancel_p.add_argument("--force-after-grace", type=float, default=None, help="Force cancel after this many seconds")
    cancel_p.add_argument("--json", action="store_true", help="Print machine-readable task status")

    tasks_p = sub.add_parser("tasks", help="List known tasks")
    _add_providers_file_arg(tasks_p)
    tasks_p.add_argument("--json", action="store_true", help="Print machine-readable task list")

    doctor_p = sub.add_parser("doctor", help="Check local runtime, config, provider, and artifact health")
    _add_providers_file_arg(doctor_p)
    doctor_p.add_argument("--json", action="store_true", help="Print machine-readable doctor report")

    config_p = sub.add_parser("config", help="Inspect resolved configuration")
    config_sub = config_p.add_subparsers(dest="config_command", required=True)
    config_show_p = config_sub.add_parser("show", help="Show resolved configuration")
    _add_providers_file_arg(config_show_p)
    config_show_p.add_argument("--json", action="store_true", help="Print machine-readable configuration")

    catalog_p = sub.add_parser("catalog", help="Inspect or rebuild the local task catalog")
    catalog_sub = catalog_p.add_subparsers(dest="catalog_command", required=True)
    catalog_status_p = catalog_sub.add_parser("status", help="Show task catalog status")
    _add_providers_file_arg(catalog_status_p)
    catalog_status_p.add_argument("--json", action="store_true")
    catalog_rebuild_p = catalog_sub.add_parser("rebuild", help="Rebuild task catalog from artifacts")
    _add_providers_file_arg(catalog_rebuild_p)
    catalog_rebuild_p.add_argument("--json", action="store_true")

    probe_p = sub.add_parser("probe-provider", help="Run local provider protocol checks (no network)")
    _add_providers_file_arg(probe_p)
    probe_p.add_argument("--provider", default=None, help="Provider name, defaults to routing.primary.provider")
    probe_p.add_argument("--model", default=None, help="Model name, defaults to routing.primary.model")
    probe_p.add_argument("--source-lang", default="en")
    probe_p.add_argument("--target-lang", default="zh-CN")
    probe_p.add_argument("--strict", action="store_true", help="Return exit code 1 if any FAIL check exists")

    provider_p = sub.add_parser("provider", help="Manage providers")
    provider_sub = provider_p.add_subparsers(dest="provider_command", required=True)
    provider_save_p = provider_sub.add_parser("save", help="Save provider config to providers.local.yaml")
    provider_save_p.add_argument("--json-payload", required=True)
    provider_save_p.add_argument("--api-key", default=None)
    provider_save_p.add_argument("--expected-version", default=None)
    provider_save_p.add_argument("--json", action="store_true")

    provider_delete_p = provider_sub.add_parser("delete", help="Delete provider config from providers.local.yaml")
    provider_delete_p.add_argument("--name", required=True)
    provider_delete_p.add_argument("--expected-version", default=None)
    provider_delete_p.add_argument("--json", action="store_true")

    provider_models_p = provider_sub.add_parser("models", help="Fetch provider models from network")
    provider_models_p.add_argument("--json-payload", required=True)
    provider_models_p.add_argument("--api-key", default=None)
    provider_models_p.add_argument("--json", action="store_true")

    provider_test_p = provider_sub.add_parser("test", help="Run a minimal provider network test")
    provider_test_p.add_argument("--json-payload", required=True)
    provider_test_p.add_argument("--model", required=True)
    provider_test_p.add_argument("--api-key", default=None)
    provider_test_p.add_argument("--json", action="store_true")

    provider_routing_p = provider_sub.add_parser("routing", help="Save primary/fallback provider routing")
    provider_routing_p.add_argument("--json-payload", required=True)
    provider_routing_p.add_argument("--json", action="store_true")

    prompt_p = sub.add_parser("prompt", help="Manage prompt profiles")
    prompt_sub = prompt_p.add_subparsers(dest="prompt_command", required=True)
    asr_prompt_p = prompt_sub.add_parser("asr", help="Manage ASR prompt profiles")
    asr_prompt_sub = asr_prompt_p.add_subparsers(dest="asr_prompt_command", required=True)
    asr_prompt_list_p = asr_prompt_sub.add_parser("list", help="List ASR prompt profiles")
    asr_prompt_list_p.add_argument("--json", action="store_true")
    asr_prompt_save_p = asr_prompt_sub.add_parser("save", help="Save an ASR prompt profile")
    asr_prompt_save_p.add_argument("--json-payload", required=True)
    asr_prompt_save_p.add_argument("--json", action="store_true")
    asr_prompt_delete_p = asr_prompt_sub.add_parser("delete", help="Delete an ASR prompt profile")
    asr_prompt_delete_p.add_argument("--id", required=True)
    asr_prompt_delete_p.add_argument("--json", action="store_true")

    auth_p = sub.add_parser("auth", help="Manage saved API credentials")
    auth_sub = auth_p.add_subparsers(dest="auth_command", required=True)
    auth_set_p = auth_sub.add_parser("set", help="Save a credential to auth.json")
    auth_set_p.add_argument("credential_id")
    auth_set_p.add_argument("--api-key", default=None, help="Credential value. Prefer prompt or --stdin to avoid shell history.")
    auth_set_p.add_argument("--stdin", action="store_true", help="Read credential value from standard input")
    auth_set_p.add_argument("--json", action="store_true")
    auth_delete_p = auth_sub.add_parser("delete", help="Delete a credential from auth.json")
    auth_delete_p.add_argument("credential_id")
    auth_delete_p.add_argument("--json", action="store_true")
    auth_list_p = auth_sub.add_parser("list", help="List credential ids in auth.json")
    auth_list_p.add_argument("--json", action="store_true")
    auth_status_p = auth_sub.add_parser("status", help="Show provider credential status")
    _add_providers_file_arg(auth_status_p)
    auth_status_p.add_argument("--json", action="store_true")

    result_p = sub.add_parser("result", help="Inspect or edit task results")
    result_sub = result_p.add_subparsers(dest="result_command", required=True)
    result_open_p = result_sub.add_parser("open", help="Open task result data")
    result_open_p.add_argument("--task-id", required=True)
    result_open_p.add_argument("--json", action="store_true")
    result_save_p = result_sub.add_parser("save", help="Save edited task segments")
    result_save_p.add_argument("--task-id", required=True)
    result_save_p.add_argument("--json-payload", required=True)
    result_save_p.add_argument("--json", action="store_true")
    result_memory_p = result_sub.add_parser("memory-entry", help="Update a task runtime memory entry")
    result_memory_p.add_argument("--task-id", required=True)
    result_memory_p.add_argument("--entry-id", required=True)
    result_memory_p.add_argument("--status", choices=["proposed", "confirmed", "locked"], required=True)
    result_memory_p.add_argument("--json", action="store_true")

    memory_p = sub.add_parser("memory", help="Manage persistent translation memory and legacy presets")
    memory_sub = memory_p.add_subparsers(dest="memory_command", required=True)
    memory_list_p = memory_sub.add_parser("collections", help="List persistent memory collections")
    memory_list_p.add_argument("--json", action="store_true")
    memory_get_p = memory_sub.add_parser("collection-get", help="Read one persistent memory collection")
    memory_get_p.add_argument("--collection-id", required=True)
    memory_get_p.add_argument("--json", action="store_true")
    memory_create_p = memory_sub.add_parser("collection-create", help="Create a persistent memory collection")
    memory_create_p.add_argument("--collection-id", default="")
    memory_create_p.add_argument("--name", required=True)
    memory_create_p.add_argument("--description", default="")
    memory_create_p.add_argument("--language-pair", action="append", default=[])
    memory_create_p.add_argument("--tag", action="append", default=[])
    memory_create_p.add_argument("--json", action="store_true")
    memory_update_p = memory_sub.add_parser("collection-update", help="Update collection metadata with revision protection")
    memory_update_p.add_argument("--collection-id", required=True)
    memory_update_p.add_argument("--json-payload", required=True)
    memory_update_p.add_argument("--expected-revision", type=int, required=True)
    memory_update_p.add_argument("--dry-run", action="store_true")
    memory_update_p.add_argument("--json", action="store_true")
    memory_delete_p = memory_sub.add_parser("collection-delete", help="Delete a persistent memory collection")
    memory_delete_p.add_argument("--collection-id", required=True)
    memory_delete_p.add_argument("--expected-revision", type=int, required=True)
    memory_delete_p.add_argument("--yes", action="store_true")
    memory_delete_p.add_argument("--json", action="store_true")
    memory_entry_upsert_p = memory_sub.add_parser("entry-upsert", help="Create or edit a collection entry")
    memory_entry_upsert_p.add_argument("--collection-id", required=True)
    memory_entry_upsert_p.add_argument("--json-payload", required=True)
    memory_entry_upsert_p.add_argument("--expected-revision", type=int, required=True)
    memory_entry_upsert_p.add_argument("--dry-run", action="store_true")
    memory_entry_upsert_p.add_argument("--json", action="store_true")
    memory_entry_delete_p = memory_sub.add_parser("entry-delete", help="Delete a collection entry")
    memory_entry_delete_p.add_argument("--collection-id", required=True)
    memory_entry_delete_p.add_argument("--entry-id", required=True)
    memory_entry_delete_p.add_argument("--expected-revision", type=int, required=True)
    memory_entry_delete_p.add_argument("--dry-run", action="store_true")
    memory_entry_delete_p.add_argument("--yes", action="store_true")
    memory_entry_delete_p.add_argument("--json", action="store_true")
    memory_promote_p = memory_sub.add_parser("promote", help="Promote selected task candidates into a collection")
    memory_promote_p.add_argument("--task-id", required=True)
    memory_promote_p.add_argument("--collection-id", required=True)
    memory_promote_p.add_argument("--entry-id", action="append", required=True)
    memory_promote_p.add_argument("--status", choices=["proposed", "confirmed", "locked"], default="confirmed")
    memory_promote_p.add_argument("--expected-revision", type=int, required=True)
    memory_promote_p.add_argument("--conflict-policy", choices=["skip", "replace"], default="skip")
    memory_promote_p.add_argument("--dry-run", action="store_true")
    memory_promote_p.add_argument("--json", action="store_true")
    memory_resolve_p = memory_sub.add_parser("resolve", help="Preview the exact collection snapshot for a task")
    memory_resolve_p.add_argument("--collection-id", action="append", required=True)
    memory_resolve_p.add_argument("--src", required=True)
    memory_resolve_p.add_argument("--tgt", required=True)
    memory_resolve_p.add_argument("--json", action="store_true")
    memory_bootstrap_p = memory_sub.add_parser("bootstrap", help="Generate a draft memory preset from segments or SRT")
    _add_providers_file_arg(memory_bootstrap_p)
    memory_bootstrap_p.add_argument("--segments", required=True)
    memory_bootstrap_p.add_argument("--src", required=True)
    memory_bootstrap_p.add_argument("--tgt", required=True)
    memory_bootstrap_p.add_argument("--preset-id", required=True)
    memory_bootstrap_p.add_argument("--name", default="")
    memory_bootstrap_p.add_argument("--description", default="")
    memory_bootstrap_p.add_argument("--default-status", choices=["proposed", "confirmed", "locked"], default="proposed")
    memory_bootstrap_p.add_argument("--overwrite", action="store_true")
    memory_bootstrap_p.add_argument("--dry-run", action="store_true")
    memory_bootstrap_p.add_argument("--json", action="store_true")
    memory_export_p = memory_sub.add_parser("export-preset", help="Export runtime memory to a draft preset")
    memory_export_p.add_argument("--task-id", required=True)
    memory_export_p.add_argument("--preset-id", required=True)
    memory_export_p.add_argument("--name", default="")
    memory_export_p.add_argument("--description", default="")
    memory_export_p.add_argument("--default-status", choices=["proposed", "confirmed", "locked"], default="proposed")
    memory_export_p.add_argument("--overwrite", action="store_true")
    memory_export_p.add_argument("--dry-run", action="store_true")
    memory_export_p.add_argument("--json", action="store_true")

    runtime_p = sub.add_parser("runtime", help="Manage local task runtime")
    runtime_sub = runtime_p.add_subparsers(dest="runtime_command", required=True)
    runtime_submit_run_p = runtime_sub.add_parser("submit-run", help="Queue a run request")
    _add_providers_file_arg(runtime_submit_run_p)
    runtime_submit_run_p.add_argument("--request-json", required=True)
    runtime_submit_run_p.add_argument("--json", action="store_true")
    runtime_submit_resume_p = runtime_sub.add_parser("submit-resume", help="Queue a resume request")
    _add_providers_file_arg(runtime_submit_resume_p)
    runtime_submit_resume_p.add_argument("--request-json", required=True)
    runtime_submit_resume_p.add_argument("--json", action="store_true")
    runtime_acquire_p = runtime_sub.add_parser("acquire-next", help="Acquire the next queued task")
    _add_providers_file_arg(runtime_acquire_p)
    runtime_acquire_p.add_argument("--json", action="store_true")
    runtime_snapshot_p = runtime_sub.add_parser("snapshot", help="Show runtime state")
    _add_providers_file_arg(runtime_snapshot_p)
    runtime_snapshot_p.add_argument("--json", action="store_true")
    runtime_reconcile_p = runtime_sub.add_parser("reconcile", help="Repair stale runtime state")
    _add_providers_file_arg(runtime_reconcile_p)
    runtime_reconcile_p.add_argument("--json", action="store_true")
    runtime_release_p = runtime_sub.add_parser("release-active", help="Release a claimed active task")
    _add_providers_file_arg(runtime_release_p)
    runtime_release_p.add_argument("--task-id", required=True)
    runtime_release_p.add_argument("--state", choices=["interrupted", "queued"], default="interrupted")
    runtime_release_p.add_argument("--reason", default="worker_launch_failed")
    runtime_release_p.add_argument("--json", action="store_true")

    reexport_p = sub.add_parser("reexport", help="Re-export subtitles from task final segments")
    reexport_p.add_argument("--task-id", required=True)
    reexport_p.add_argument("--output-format", choices=["srt", "ass", "vtt", "webvtt", "lrc", "both"], default=None)
    reexport_p.add_argument("--bilingual", choices=["true", "false"], default=None)
    reexport_p.add_argument("--subtitle-bilingual-order", choices=["target_source", "source_target"], default=None)
    reexport_p.add_argument("--subtitle-prefer-single-line", choices=["true", "false"], default=None)
    reexport_p.add_argument("--json", action="store_true")

    asr_p = sub.add_parser("asr", help="Run ASR only and emit source segments, or inspect Agent setup")
    _add_providers_file_arg(asr_p)
    # Keep the historical ``asr --input ...`` form while allowing a nested,
    # machine-readable setup contract: ``asr setup-plan --scope <scope> --json``.  The input
    # and source flags are validated in the legacy branch below so argparse
    # can also parse the nested commands without making them mandatory.
    asr_p.add_argument("--input", required=False)
    asr_p.add_argument("--src", required=False)
    _add_pipeline_override_args(asr_p)
    asr_p.add_argument("--json", action="store_true")
    asr_p.add_argument("--detach", action="store_true")
    asr_sub = asr_p.add_subparsers(dest="asr_command")
    asr_setup_plan_p = asr_sub.add_parser("setup-plan", help="Print a read-only Agent environment setup plan")
    asr_setup_plan_p.add_argument("--providers-file", dest="setup_providers_file", default=None)
    asr_setup_plan_p.add_argument("--scope", dest="setup_scope", choices=SETUP_SCOPES, default="full")
    asr_setup_plan_p.add_argument("--json", action="store_true", help="Print machine-readable setup contract")
    asr_setup_verify_p = asr_sub.add_parser("setup-verify", help="Verify the active ASR environment without changing it")
    asr_setup_verify_p.add_argument("--providers-file", dest="setup_providers_file", default=None)
    asr_setup_verify_p.add_argument("--scope", dest="setup_scope", choices=SETUP_SCOPES, default="full")
    asr_setup_verify_p.add_argument("--json", action="store_true", help="Print machine-readable verification result")
    asr_setup_verify_p.add_argument("--strict", action="store_true", help="Exit with code 1 when the requested scope is incomplete")
    asr_setup_apply_p = asr_sub.add_parser(
        "setup-apply",
        help="Apply a TransVortex-managed ASR resource action and wait for completion",
    )
    asr_setup_apply_p.add_argument("--providers-file", dest="setup_providers_file", default=None)
    asr_setup_apply_p.add_argument(
        "--resource",
        choices=["setup", "runtime", "model", "accelerator"],
        required=True,
    )
    asr_setup_apply_p.add_argument("--item-id", default="")
    asr_setup_apply_p.add_argument("--json", action="store_true")
    for command_name, save_result in (("model-probe", False), ("model-register", True)):
        command = asr_sub.add_parser(
            command_name,
            help=("Register" if save_result else "Probe") + " an Agent- or user-prepared Whisper model",
        )
        command.add_argument("--model-path", required=True)
        if save_result:
            command.add_argument(
                "--label",
                default=None,
                help="Optional user-facing name for a registered external model",
            )
        command.add_argument("--providers-file", dest="setup_providers_file", default=None)
        command.add_argument("--device", choices=["auto", "cpu", "cuda"], default="auto")
        command.add_argument("--compute-type", default="auto")
        command.add_argument("--accelerator-root", default=None)
        command.add_argument("--timeout-seconds", type=float, default=120.0)
        command.add_argument("--json", action="store_true")
    for command_name, save_result in (("accelerator-probe", False), ("accelerator-register", True)):
        command = asr_sub.add_parser(
            command_name,
            help=("Register" if save_result else "Probe") + " an Agent-prepared NVIDIA accelerator directory",
        )
        command.add_argument("--accelerator-root", required=True)
        command.add_argument("--providers-file", dest="setup_providers_file", default=None)
        command.add_argument("--accelerator-id", default="nvidia-cuda12")
        command.add_argument("--compute-type", default="auto")
        command.add_argument("--timeout-seconds", type=float, default=120.0)
        command.add_argument("--json", action="store_true")
    asr_resources_activate_p = asr_sub.add_parser(
        "resources-activate",
        help="Attach registered or managed ASR resources to a local worker configuration",
    )
    asr_resources_activate_p.add_argument(
        "--engine",
        default="",
        help="ASR engine id; defaults to the active engine",
    )
    asr_resources_activate_p.add_argument("--providers-file", dest="setup_providers_file", default=None)
    asr_resources_activate_p.add_argument("--managed-model-id", default="")
    asr_resources_activate_p.add_argument("--model-registration-id", default="")
    asr_resources_activate_p.add_argument("--managed-accelerator-id", default="")
    asr_resources_activate_p.add_argument("--accelerator-registration-id", default="")
    asr_resources_activate_p.add_argument("--device", choices=["auto", "cpu", "cuda"], default="")
    asr_resources_activate_p.add_argument("--compute-type", default="")
    asr_resources_activate_p.add_argument("--json", action="store_true")
    asr_provider_test_p = asr_sub.add_parser(
        "engine-test",
        help="Run an authorized ASR route probe and record its non-secret status",
    )
    asr_provider_test_p.add_argument("--providers-file", dest="setup_providers_file", default=None)
    asr_provider_test_p.add_argument(
        "--engine",
        default=None,
        help="ASR engine id; defaults to the active engine",
    )
    asr_provider_test_p.add_argument("--source-lang", default="en")
    asr_provider_test_p.add_argument(
        "--confirm-network",
        action="store_true",
        help="Confirm that this probe may contact a local or remote ASR endpoint and may upload a short sample",
    )
    asr_provider_test_p.add_argument(
        "--confirm-media",
        action="store_true",
        help="For remote providers, confirm that the short generated probe audio may leave this machine",
    )
    asr_provider_test_p.add_argument(
        "--confirm-cost",
        action="store_true",
        help="For remote providers, confirm that the probe may incur provider charges",
    )
    asr_provider_test_p.add_argument("--json", action="store_true", help="Print machine-readable probe result")

    translate_p = sub.add_parser("translate", help="Translate existing segments or SRT")
    _add_providers_file_arg(translate_p)
    translate_p.add_argument("--segments", required=True)
    translate_p.add_argument("--src", required=True)
    translate_p.add_argument("--tgt", required=True)
    translate_p.add_argument("--bilingual", action="store_true")
    translate_p.add_argument("--output", help="Output subtitle file path")
    _add_pipeline_override_args(translate_p)
    _add_route_override_args(translate_p)
    translate_p.add_argument("--json", action="store_true")
    translate_p.add_argument("--detach", action="store_true")

    export_p = sub.add_parser("export", help="Export final segments to subtitle files")
    export_p.add_argument("--segments", required=True)
    export_p.add_argument("--format", choices=["srt", "ass", "vtt", "webvtt", "lrc", "both"], required=True)
    export_p.add_argument("--output", required=True)
    export_p.add_argument("--bilingual", action="store_true")
    export_p.add_argument("--subtitle-bilingual-order", choices=["target_source", "source_target"], default=None)
    export_p.add_argument("--subtitle-prefer-single-line", choices=["true", "false"], default=None)
    export_p.add_argument("--json", action="store_true")

    worker_p = sub.add_parser("_worker", help=argparse.SUPPRESS)
    worker_p.add_argument("--task-id", required=True)
    worker_p.add_argument("--output", default=None)
    _add_providers_file_arg(worker_p)
    _add_pipeline_override_args(worker_p)
    _add_route_override_args(worker_p)
    for choice in list(getattr(sub, "_choices_actions", [])):
        if getattr(choice, "dest", "") == "_worker":
            sub._choices_actions.remove(choice)
    return parser


def main() -> None:
    global _CURRENT_ROOT
    parser = _build_parser()
    args = parser.parse_args()
    root = Path(args.root).resolve()
    _CURRENT_ROOT = root
    raw_providers_file = getattr(args, "setup_providers_file", None) or getattr(args, "providers_file", None)
    providers_file = Path(raw_providers_file).resolve() if raw_providers_file else None
    if args.command == "agent-info":
        payload = agent_info_payload(root_dir=root)
        if args.json:
            _print_json(payload)
        else:
            print(payload)
        return

    asr_command = getattr(args, "asr_command", None) if args.command == "asr" else None
    if asr_command == "setup-apply":
        operation_id = ""
        try:
            config = load_app_config(root_dir=root, providers_file=providers_file)
            manager = AsrOperationManager(root_dir=root, network=config.network)
            if args.resource == "setup":
                if not args.item_id:
                    raise AsrOperationError("model_required", "--item-id is required for a setup apply")
                operation = manager.start_setup(args.item_id)
            else:
                if args.resource in {"model", "accelerator"} and not args.item_id:
                    raise AsrOperationError("item_required", f"--item-id is required for {args.resource}")
                operation = manager.start_install(args.resource, args.item_id)
            operation_id = str(operation.get("id") or "")
            final = manager.wait(operation_id)
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": "managed_apply",
                "ok": final.get("state") == "completed",
                "executor": "transvortex",
                "ownership": "transvortex",
                "resource": args.resource,
                "operation": final,
            }
        except KeyboardInterrupt:
            if operation_id:
                manager.cancel(operation_id)
                final = manager.wait(operation_id)
            else:
                final = {}
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": "managed_apply",
                "ok": False,
                "executor": "transvortex",
                "ownership": "transvortex",
                "resource": args.resource,
                "operation": final,
                "error": {"code": "cancelled", "message": "Managed apply cancelled"},
            }
        except AsrOperationError as exc:
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": "managed_apply",
                "ok": False,
                "executor": "transvortex",
                "ownership": "transvortex",
                "resource": args.resource,
                "error": {"code": exc.code, "message": str(exc)},
            }
        except Exception as exc:  # noqa: BLE001 - keep Agent-facing mutations structured
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": "managed_apply",
                "ok": False,
                "executor": "transvortex",
                "ownership": "transvortex",
                "resource": args.resource,
                "error": {"code": "managed_apply_failed", "message": str(exc)},
            }
        _print_json(payload)
        if payload.get("ok") is not True:
            raise SystemExit(1)
        return

    if asr_command in {"model-probe", "model-register"}:
        try:
            payload = probe_external_model(
                root_dir=root,
                model_path=Path(args.model_path),
                device=args.device,
                compute_type=args.compute_type,
                accelerator_root=Path(args.accelerator_root) if args.accelerator_root else None,
                timeout_seconds=args.timeout_seconds,
                save=asr_command == "model-register",
                user_label=args.label if asr_command == "model-register" else None,
            )
            payload.update(
                {
                    "schema_version": 2,
                    "contract": "transvortex.agent_setup",
                    "kind": asr_command.replace("-", "_"),
                    "executor": "transvortex",
                    "ownership": "external",
                }
            )
        except Exception as exc:  # noqa: BLE001 - keep Agent-facing probes structured
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": asr_command.replace("-", "_"),
                "ok": False,
                "executor": "transvortex",
                "ownership": "external",
                "error": {"code": "model_probe_failed", "message": str(exc)},
            }
        _print_json(payload)
        if payload.get("ok") is not True:
            raise SystemExit(1)
        return

    if asr_command in {"accelerator-probe", "accelerator-register"}:
        try:
            payload = probe_external_accelerator(
                root_dir=root,
                accelerator_root=Path(args.accelerator_root),
                accelerator_id=args.accelerator_id,
                compute_type=args.compute_type,
                save=asr_command == "accelerator-register",
                timeout_seconds=args.timeout_seconds,
            )
            payload.update(
                {
                    "schema_version": 2,
                    "contract": "transvortex.agent_setup",
                    "kind": asr_command.replace("-", "_"),
                    "executor": "transvortex",
                    "ownership": "external",
                }
            )
        except Exception as exc:  # noqa: BLE001 - keep Agent-facing probes structured
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": asr_command.replace("-", "_"),
                "ok": False,
                "executor": "transvortex",
                "ownership": "external",
                "error": {"code": "accelerator_probe_failed", "message": str(exc)},
            }
        _print_json(payload)
        if payload.get("ok") is not True:
            raise SystemExit(1)
        return

    if asr_command == "resources-activate":
        try:
            payload = activate_asr_resources(
                root_dir=root,
                providers_file=providers_file,
                provider_name=args.engine,
                managed_model_id=args.managed_model_id,
                model_registration_id=args.model_registration_id,
                managed_accelerator_id=args.managed_accelerator_id,
                accelerator_registration_id=args.accelerator_registration_id,
                device=args.device,
                compute_type=args.compute_type,
            )
            payload.update(
                {
                    "schema_version": 2,
                    "contract": "transvortex.agent_setup",
                    "kind": "resources_activate",
                    "executor": "transvortex",
                    "ownership": "transvortex",
                }
            )
        except Exception as exc:  # noqa: BLE001 - keep Agent-facing config writes structured
            payload = {
                "schema_version": 2,
                "contract": "transvortex.agent_setup",
                "kind": "resources_activate",
                "ok": False,
                "executor": "transvortex",
                "ownership": "transvortex",
                "error": {"code": "resource_activation_failed", "message": str(exc)},
            }
        _print_json(payload)
        if payload.get("ok") is not True:
            raise SystemExit(1)
        return

    if args.command == "asr" and getattr(args, "asr_command", None) == "engine-test":
        try:
            config = load_app_config(root_dir=root, providers_file=providers_file)
        except Exception:  # noqa: BLE001 - keep the Agent probe contract structured
            _print_json(provider_test_error_payload("config_load_failed", provider_name=args.engine or ""))
            raise SystemExit(1)
        provider_name = args.engine or config.pipeline.asr_provider
        provider = config.asr_providers.get(provider_name)
        if provider is None:
            _print_json(provider_test_error_payload("asr_provider_missing", provider_name=provider_name))
            raise SystemExit(1)
        if provider.kind not in {"local_server", "remote"}:
            _print_json(provider_test_error_payload("route_probe_not_applicable", provider_name=provider.name, network_access=False))
            raise SystemExit(1)
        route_policy_code = asr_provider_endpoint_policy_code(provider)
        if route_policy_code:
            _print_json(
                provider_test_error_payload(
                    route_policy_code,
                    provider_name=provider.name,
                    network_access=False,
                )
            )
            raise SystemExit(1)
        required_confirmations: list[str] = []
        if not args.confirm_network:
            required_confirmations.append("confirm-network")
        if provider.kind == "remote" and not args.confirm_media:
            required_confirmations.append("confirm-media")
        if provider.kind == "remote" and not args.confirm_cost:
            required_confirmations.append("confirm-cost")
        if required_confirmations:
            _print_json(
                provider_test_error_payload(
                    "confirmation_required",
                    provider_name=provider.name,
                    required_confirmations=required_confirmations,
                )
            )
            raise SystemExit(2)
        try:
            payload = run_asr_connection_test(provider, root_dir=root, source_lang=args.source_lang)
        except Exception:  # noqa: BLE001 - keep probe/storage failures secret-free and structured
            _print_json(provider_test_error_payload("route_probe_failed", provider_name=provider.name))
            raise SystemExit(1)
        contract_payload = provider_test_contract_payload(provider, payload, root_dir=root)
        _print_json(contract_payload)
        raise SystemExit(0 if contract_payload.get("ok") is True else 1)

    if args.command == "asr" and getattr(args, "asr_command", None) in {"setup-plan", "setup-verify"}:
        if args.asr_command == "setup-plan":
            try:
                payload = setup_plan_payload(
                    root_dir=root,
                    providers_file=providers_file,
                    scope=args.setup_scope,
                )
            except Exception:  # noqa: BLE001 - the Agent contract must remain structured
                payload = setup_failure_payload(kind="setup_plan", root_dir=root, scope=args.setup_scope)
            if args.json:
                _print_json(payload)
            else:
                _print_json(payload)
            if payload.get("ok") is not True:
                raise SystemExit(1)
            return
        try:
            payload = setup_verify_payload(
                root_dir=root,
                providers_file=providers_file,
                scope=args.setup_scope,
            )
        except Exception:  # noqa: BLE001 - the Agent contract must remain structured
            payload = setup_failure_payload(kind="setup_verify", root_dir=root, scope=args.setup_scope)
        if args.json:
            _print_json(payload)
        else:
            _print_json(payload)
        scope_complete = (
            isinstance(payload.get("scope_result"), dict)
            and payload["scope_result"].get("complete") is True
        )
        if args.strict and not scope_complete:
            raise SystemExit(1)
        return

    if args.command == "_worker":
        def do_worker():
            runtime = _runtime_for(root, providers_file)
            runtime.register_worker(task_id=args.task_id, owner="python", command="_worker")
            saved_request = runtime.load_worker_request(args.task_id)
            try:
                if saved_request is not None:
                    _command, request = saved_request
                    result = execute_pipeline_task(
                        root_dir=root,
                        task_id=args.task_id,
                        output_file=_output_path_from_request(request.output),
                        providers_file=providers_file,
                        cli_overrides=request.overrides,
                        provider_name=request.provider or None,
                        model=request.model or None,
                        routing=request.routing or None,
                        event_sink=_print_jsonl_event,
                    )
                else:
                    result = execute_pipeline_task(
                        root_dir=root,
                        task_id=args.task_id,
                        output_file=_optional_path_arg(args.output),
                        providers_file=providers_file,
                        cli_overrides=_common_overrides(args),
                        provider_name=args.provider,
                        model=args.model,
                        event_sink=_print_jsonl_event,
                    )
                runtime.finish_worker(args.task_id, exit_code=0)
                return result
            except Exception:
                runtime.finish_worker(args.task_id, exit_code=1, state="failed")
                raise

        _run_or_exit(do_worker, json_mode=False, stream_events=True)
        return

    if args.command == "run":
        if args.json and args.stream_events:
            parser.error("run: --json and --stream-events cannot be used together")
        if args.detach and args.stream_events:
            parser.error("run: --detach and --stream-events cannot be used together")
        request_path = _request_path_arg(args.request_json)
        if request_path is not None:
            mixed = _request_mode_business_flags(args, "run")
            if mixed:
                _run_or_exit(
                    lambda: _raise_request_validation(
                        f"run: --request-json cannot be combined with {', '.join(mixed)}"
                    ),
                    json_mode=args.json,
                    stream_events=args.stream_events,
                )
            request = _run_or_exit(lambda: load_run_request(request_path), json_mode=args.json, stream_events=args.stream_events)
        else:
            if not args.input or not args.src or not args.tgt:
                parser.error("run: --input, --src and --tgt are required unless --request-json is used")
            request = _run_or_exit(
                lambda: run_request_from_flags(
                    input_path=args.input,
                    input_type=args.input_type or "video",
                    source_lang=args.src,
                    target_lang=args.tgt,
                    bilingual=args.bilingual,
                    output=args.output,
                    provider=args.provider,
                    model=args.model,
                    overrides=_common_overrides(args),
                ),
                json_mode=args.json,
                stream_events=args.stream_events,
            )
        if args.detach:
            task_id, artifacts_dir = _run_or_exit(
                lambda: create_pipeline_task(
                    root_dir=root,
                    input_file=Path(request.input),
                    source_lang=request.source_lang,
                    target_lang=request.target_lang,
                    bilingual=request.bilingual,
                    providers_file=providers_file,
                    cli_overrides=request.overrides,
                    provider_name=request.provider or None,
                    model=request.model or None,
                    routing=request.routing or None,
                    input_type=request.input_type,
                    status="QUEUED",
                ),
                json_mode=args.json,
                stream_events=False,
            )
            TaskRuntime(artifacts_dir).save_runtime_request(task_id, "run", run_request_to_payload(request))
            worker_args = ["_worker", "--task-id", task_id]
            _append_optional(worker_args, "--providers-file", str(providers_file) if providers_file else None)
            _append_optional(worker_args, "--output", request.output)
            _append_optional(worker_args, "--provider", request.provider)
            _append_optional(worker_args, "--model", request.model)
            _append_request_overrides_to_args(worker_args, request.overrides)
            try:
                worker = _spawn_detached_worker(root=root, task_dir=artifacts_dir / task_id, worker_args=worker_args)
            except Exception as exc:  # noqa: BLE001 - keep detach responses machine-readable
                _handle_detached_worker_error(exc, root=root, providers_file=providers_file, task_id=task_id, json_mode=args.json)
            payload = _detach_response(task_id=task_id, artifacts_dir=artifacts_dir, worker=worker, command="run")
            if args.json:
                _print_json(payload)
            else:
                print(task_id)
            return

        def do_run():
            return run_pipeline(
                root_dir=root,
                input_file=Path(request.input),
                source_lang=request.source_lang,
                target_lang=request.target_lang,
                bilingual=request.bilingual,
                output_file=_output_path_from_request(request.output),
                providers_file=providers_file,
                cli_overrides=request.overrides,
                provider_name=request.provider or None,
                model=request.model or None,
                routing=request.routing or None,
                input_type=request.input_type,
                event_sink=_print_jsonl_event if args.stream_events else None,
            )

        task_id = _run_or_exit(do_run, json_mode=args.json, stream_events=args.stream_events)
        if args.json:
            _print_task_json_or_exit(root, providers_file, task_id)
        elif not args.stream_events:
            print(task_id)
        else:
            sys.stdout.flush()
        return

    if args.command == "resume":
        if args.json and args.stream_events:
            parser.error("resume: --json and --stream-events cannot be used together")
        if args.detach and args.stream_events:
            parser.error("resume: --detach and --stream-events cannot be used together")
        request_path = _request_path_arg(args.request_json)
        if request_path is not None:
            mixed = _request_mode_business_flags(args, "resume")
            if mixed:
                _run_or_exit(
                    lambda: _raise_request_validation(
                        f"resume: --request-json cannot be combined with {', '.join(mixed)}"
                    ),
                    json_mode=args.json,
                    stream_events=args.stream_events,
                )
            request = _run_or_exit(lambda: load_resume_request(request_path), json_mode=args.json, stream_events=args.stream_events)
        else:
            if not args.task_id:
                parser.error("resume: --task-id is required unless --request-json is used")
            request = _run_or_exit(
                lambda: resume_request_from_flags(
                    task_id=args.task_id,
                    output=args.output,
                    provider=args.provider,
                    model=args.model,
                    overrides=_common_overrides(args),
                ),
                json_mode=args.json,
                stream_events=args.stream_events,
            )
        if args.detach:
            artifacts_dir = _run_or_exit(
                lambda: queue_resume_task(
                    root_dir=root,
                    task_id=request.task_id,
                    providers_file=providers_file,
                    cli_overrides=request.overrides,
                    provider_name=request.provider or None,
                    model=request.model or None,
                    routing=request.routing or None,
                ),
                json_mode=args.json,
                stream_events=False,
            )
            TaskRuntime(artifacts_dir).save_runtime_request(request.task_id, "resume", resume_request_to_payload(request))
            worker_args = ["_worker", "--task-id", request.task_id]
            _append_optional(worker_args, "--providers-file", str(providers_file) if providers_file else None)
            _append_optional(worker_args, "--output", request.output)
            _append_optional(worker_args, "--provider", request.provider)
            _append_optional(worker_args, "--model", request.model)
            _append_request_overrides_to_args(worker_args, request.overrides)
            try:
                worker = _spawn_detached_worker(root=root, task_dir=artifacts_dir / request.task_id, worker_args=worker_args)
            except Exception as exc:  # noqa: BLE001 - keep detach responses machine-readable
                _handle_detached_worker_error(
                    exc,
                    root=root,
                    providers_file=providers_file,
                    task_id=request.task_id,
                    json_mode=args.json,
                )
            payload = _detach_response(task_id=request.task_id, artifacts_dir=artifacts_dir, worker=worker, command="resume")
            if args.json:
                _print_json(payload)
            else:
                print(request.task_id)
            return

        def do_resume():
            return resume_pipeline(
                root_dir=root,
                task_id=request.task_id,
                output_file=_output_path_from_request(request.output),
                providers_file=providers_file,
                cli_overrides=request.overrides,
                provider_name=request.provider or None,
                model=request.model or None,
                routing=request.routing or None,
                event_sink=_print_jsonl_event if args.stream_events else None,
            )

        task_id = _run_or_exit(do_resume, json_mode=args.json, stream_events=args.stream_events)
        if args.json:
            _print_task_json_or_exit(root, providers_file, task_id)
        elif not args.stream_events:
            print(task_id)
        else:
            sys.stdout.flush()
        return

    if args.command == "runtime":
        runtime = _runtime_for(root, providers_file)
        if args.runtime_command == "submit-run":
            payload = _run_or_exit(
                lambda: runtime.submit_run(
                    root_dir=root,
                    request=_load_run_request_arg(args.request_json),
                    providers_file=providers_file,
                ),
                json_mode=True,
                stream_events=False,
            )
            _print_json(payload)
            return
        if args.runtime_command == "submit-resume":
            payload = _run_or_exit(
                lambda: runtime.submit_resume(
                    root_dir=root,
                    request=_load_resume_request_arg(args.request_json),
                    providers_file=providers_file,
                ),
                json_mode=True,
                stream_events=False,
            )
            _print_json(payload)
            return
        if args.runtime_command == "acquire-next":
            payload = _run_or_exit(
                lambda: runtime.acquire_next(root_dir=root, providers_file=providers_file),
                json_mode=True,
                stream_events=False,
            )
            _print_json(payload)
            return
        if args.runtime_command == "snapshot":
            _print_json(runtime.snapshot())
            return
        if args.runtime_command == "reconcile":
            _print_json(runtime.reconcile())
            return
        if args.runtime_command == "release-active":
            payload = _run_or_exit(
                lambda: runtime.release_active(args.task_id, state=args.state, reason=args.reason),
                json_mode=True,
                stream_events=False,
            )
            _print_json(payload)
            return

    if args.command == "status":
        def do_status():
            config = load_app_config(root_dir=root, providers_file=providers_file)
            TaskRuntime(config.pipeline.artifacts_dir).reconcile()
            store = TaskStore(config.pipeline.artifacts_dir)
            task = store.load_task(args.task_id)
            return _task_payload(task, config.pipeline.artifacts_dir)

        payload = _run_or_exit(do_status, json_mode=args.json, stream_events=False, task_id_hint=args.task_id)
        if args.json:
            _print_json(payload)
        else:
            print(payload)
        return

    if args.command == "events":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        store = TaskStore(config.pipeline.artifacts_dir)
        emitted = 0
        terminal_event_types = {"done", "error", "cancelled", "interrupted"}
        terminal_statuses = {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}
        while True:
            events = store.read_events(args.task_id)
            for event in events[emitted:]:
                _print_jsonl_event(event)
            emitted = len(events)
            if not args.follow:
                return
            if any(event.get("type") in terminal_event_types for event in events):
                return
            try:
                task = store.load_task(args.task_id)
            except Exception:
                return
            if task.status in terminal_statuses:
                return
            time.sleep(0.5)
        return

    if args.command == "cancel":
        def do_cancel():
            config = load_app_config(root_dir=root, providers_file=providers_file)
            store = TaskStore(config.pipeline.artifacts_dir)
            runtime = TaskRuntime(config.pipeline.artifacts_dir)
            if args.force:
                task = runtime.force_cancel(args.task_id, reason="force_cancel")
            else:
                task = store.request_cancel(args.task_id)
                if args.force_after_grace is not None:
                    deadline = time.time() + max(0.0, float(args.force_after_grace))
                    while time.time() < deadline:
                        latest = store.load_task(args.task_id)
                        if latest.status in {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}:
                            return task_status_json(latest, store=store)
                        time.sleep(0.2)
                    latest = store.load_task(args.task_id)
                    if latest.status not in {"DONE", "FAILED", "CANCELLED", "INTERRUPTED"}:
                        task = runtime.force_cancel(args.task_id, reason="force_after_grace")
            return task_status_json(task, store=store)

        payload = _run_or_exit(do_cancel, json_mode=args.json, stream_events=False, task_id_hint=args.task_id)
        if args.json:
            _print_json(payload)
        else:
            print(f"{payload['task_id']} {payload['status']}")
        return

    if args.command == "tasks":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        TaskRuntime(config.pipeline.artifacts_dir).reconcile()
        store = TaskStore(config.pipeline.artifacts_dir)
        payload = [_task_payload(task, config.pipeline.artifacts_dir) for task in store.list_tasks()]
        if args.json:
            _print_json(payload)
        else:
            for task in payload:
                print(f"{task['task_id']} {task['status']} {task['updated_at']}")
        return

    if args.command == "catalog":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        catalog = TaskCatalog(config.pipeline.artifacts_dir)
        if args.catalog_command == "status":
            payload = _run_or_exit(catalog.status, json_mode=args.json, stream_events=False)
        elif args.catalog_command == "rebuild":
            payload = _run_or_exit(catalog.rebuild, json_mode=args.json, stream_events=False)
        else:
            parser.error("catalog: unknown command")
        if args.json:
            _print_json(payload)
        else:
            print(payload)
        return

    if args.command == "doctor":
        payload = doctor_report(root_dir=root, providers_file=providers_file)
        if args.json:
            _print_json(payload)
        else:
            print(format_doctor_report(payload))
        return

    if args.command == "config" and args.config_command == "show":
        payload = _config_show_payload(root, providers_file)
        if args.json:
            _print_json(payload)
        else:
            print(payload)
        return

    if args.command == "probe-provider":
        report = probe_provider(
            root_dir=root,
            providers_file=providers_file,
            provider_name=args.provider,
            model=args.model,
            source_lang=args.source_lang,
            target_lang=args.target_lang,
        )
        _print_json(report)
        raise SystemExit(probe_exit_code(report, strict=args.strict))

    if args.command == "provider" and args.provider_command == "save":
        payload = save_provider_config(
            root_dir=root,
            provider_draft=_read_json_arg(args.json_payload),
            api_key=args.api_key,
            expected_version=_read_json_arg(args.expected_version) if args.expected_version else None,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "delete":
        payload = delete_provider_config(
            root_dir=root,
            name=args.name,
            expected_version=_read_json_arg(args.expected_version) if args.expected_version else None,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "models":
        network = load_app_config(root_dir=root, providers_file=providers_file).network
        payload = fetch_provider_models(
            provider_draft=_read_json_arg(args.json_payload),
            api_key=args.api_key,
            root_dir=root,
            network=network,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "test":
        network = load_app_config(root_dir=root, providers_file=providers_file).network
        payload = run_provider_connection_test(
            provider_draft=_read_json_arg(args.json_payload),
            model=args.model,
            api_key=args.api_key,
            root_dir=root,
            network=network,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "routing":
        payload = save_provider_routing(root_dir=root, routing=_read_json_arg(args.json_payload))
        _print_json(payload)
        return

    if args.command == "prompt" and args.prompt_command == "asr" and args.asr_prompt_command == "list":
        payload = list_asr_prompt_profiles(root_dir=root)
        _print_json(payload)
        return

    if args.command == "prompt" and args.prompt_command == "asr" and args.asr_prompt_command == "save":
        payload = save_asr_prompt_profile(root_dir=root, profile=_read_json_arg(args.json_payload))
        _print_json(payload)
        return

    if args.command == "prompt" and args.prompt_command == "asr" and args.asr_prompt_command == "delete":
        payload = delete_asr_prompt_profile(root_dir=root, profile_id=args.id)
        _print_json(payload)
        return

    if args.command == "auth" and args.auth_command == "set":
        path = write_auth_credential(args.credential_id, _read_auth_set_value(args))
        payload = {"ok": True, "credential_id": args.credential_id, "auth_file": str(path)}
        if args.json:
            _print_json(payload)
        else:
            print(args.credential_id)
        return

    if args.command == "auth" and args.auth_command == "delete":
        deleted = delete_auth_credential(args.credential_id)
        payload = {
            "ok": True,
            "deleted": deleted,
            "credential_id": args.credential_id,
            "auth_file": str(auth_file_path()),
        }
        if args.json:
            _print_json(payload)
        else:
            print(f"{args.credential_id} {'deleted' if deleted else 'not_found'}")
        return

    if args.command == "auth" and args.auth_command == "list":
        payload = _auth_list_payload()
        if args.json:
            _print_json(payload)
        else:
            for row in payload["credentials"]:
                print(row["credential_id"])
        return

    if args.command == "auth" and args.auth_command == "status":
        payload = _auth_status_payload(root, providers_file)
        if args.json:
            _print_json(payload)
        else:
            for row in payload["providers"]:
                print(f"{row['provider']} {row['credential_id']} {row['source']}")
        return

    if args.command == "result" and args.result_command == "open":
        payload = _run_or_exit(
            lambda: open_task_result(root_dir=root, task_id=args.task_id),
            json_mode=True,
            stream_events=False,
            task_id_hint=args.task_id,
        )
        _print_json(payload)
        return

    if args.command == "result" and args.result_command == "save":
        def do_result_save():
            raw = _read_json_arg(args.json_payload)
            segments = raw.get("segments", [])
            if not isinstance(segments, list):
                raise ValueError("segments must be a list")
            return save_task_segments(root_dir=root, task_id=args.task_id, segments_payload=segments)

        _print_json(_run_or_exit(do_result_save, json_mode=True, stream_events=False, task_id_hint=args.task_id))
        return

    if args.command == "result" and args.result_command == "memory-entry":
        _print_json(
            _run_or_exit(
                lambda: update_task_memory_entry(
                    root_dir=root,
                    task_id=args.task_id,
                    entry_id=args.entry_id,
                    status=args.status,
                ),
                json_mode=True,
                stream_events=False,
                task_id_hint=args.task_id,
            )
        )
        return

    if args.command == "memory" and args.memory_command in {
        "collections",
        "collection-get",
        "collection-create",
        "collection-update",
        "collection-delete",
        "entry-upsert",
        "entry-delete",
        "promote",
        "resolve",
    }:
        config = load_app_config(root_dir=root, providers_file=providers_file)
        collection_store = collection_store_for_config(root_dir=root, config=config)

        def do_memory_command() -> dict[str, Any]:
            if args.memory_command == "collections":
                return {
                    "collections": [collection_summary(item) for item in collection_store.list()],
                    "root": str(collection_store.root),
                }
            if args.memory_command == "collection-get":
                return {"collection": collection_payload(collection_store.get(args.collection_id))}
            if args.memory_command == "collection-create":
                collection = collection_store.create(
                    name=args.name,
                    collection_id=args.collection_id,
                    description=args.description,
                    language_pairs=args.language_pair,
                    tags=args.tag,
                    actor="agent",
                )
                return {"ok": True, "collection": collection_payload(collection)}
            if args.memory_command == "collection-update":
                collection = collection_store.update(
                    args.collection_id,
                    _read_json_arg(args.json_payload),
                    expected_revision=args.expected_revision,
                    actor="agent",
                    dry_run=args.dry_run,
                )
                return {"ok": True, "dry_run": args.dry_run, "collection": collection_payload(collection)}
            if args.memory_command == "collection-delete":
                if not args.yes:
                    raise ValueError("collection-delete requires --yes")
                collection_store.delete(args.collection_id, expected_revision=args.expected_revision)
                return {"ok": True, "collection_id": args.collection_id}
            if args.memory_command == "entry-upsert":
                collection, entry = collection_store.upsert_entry(
                    args.collection_id,
                    _read_json_arg(args.json_payload),
                    expected_revision=args.expected_revision,
                    actor="agent",
                    dry_run=args.dry_run,
                )
                return {
                    "ok": True,
                    "dry_run": args.dry_run,
                    "collection": collection_payload(collection),
                    "entry": to_plain(entry),
                }
            if args.memory_command == "entry-delete":
                if not args.dry_run and not args.yes:
                    raise ValueError("entry-delete requires --yes unless --dry-run is used")
                collection = collection_store.delete_entry(
                    args.collection_id,
                    args.entry_id,
                    expected_revision=args.expected_revision,
                    actor="agent",
                    dry_run=args.dry_run,
                )
                return {"ok": True, "dry_run": args.dry_run, "collection": collection_payload(collection)}
            if args.memory_command == "promote":
                return promote_task_memory_entries(
                    root_dir=root,
                    task_id=args.task_id,
                    collection_id=args.collection_id,
                    entry_ids=args.entry_id,
                    status=args.status,
                    expected_revision=args.expected_revision,
                    conflict_policy=args.conflict_policy,
                    actor="agent",
                    dry_run=args.dry_run,
                )
            return build_selected_collections_snapshot(
                collection_ids=args.collection_id,
                store=collection_store,
                source_lang=args.src,
                target_lang=args.tgt,
            )

        payload = _run_or_exit(do_memory_command, json_mode=args.json, stream_events=False)
        if args.json:
            _print_json(payload)
        elif args.memory_command == "collections":
            for row in payload["collections"]:
                print(f"{row['id']}\t{row['revision']}\t{row['entries']}\t{row['name']}")
        elif args.memory_command == "collection-delete":
            print(payload["collection_id"])
        else:
            _print_json(payload)
        return

    if args.command == "memory" and args.memory_command == "export-preset":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        payload = _run_or_exit(
            lambda: export_runtime_memory_to_preset(
                root_dir=root,
                artifacts_dir=config.pipeline.artifacts_dir,
                options=MemoryPresetExportOptions(
                    task_id=args.task_id,
                    preset_id=args.preset_id,
                    name=args.name,
                    description=args.description,
                    default_status=args.default_status,
                    overwrite=args.overwrite,
                    dry_run=args.dry_run,
                ),
            ),
            json_mode=args.json,
            stream_events=False,
            task_id_hint=args.task_id,
        )
        if args.json:
            _print_json(payload)
        else:
            print(payload["path"])
        return

    if args.command == "memory" and args.memory_command == "bootstrap":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        payload = _run_or_exit(
            lambda: bootstrap_memory_preset(
                root_dir=root,
                artifacts_dir=config.pipeline.artifacts_dir,
                config=config,
                options=MemoryPresetBootstrapOptions(
                    segments=_load_cli_segments_input(Path(args.segments).resolve()),
                    source_lang=args.src,
                    target_lang=args.tgt,
                    preset_id=args.preset_id,
                    name=args.name,
                    description=args.description,
                    default_status=args.default_status,
                    overwrite=args.overwrite,
                    dry_run=args.dry_run,
                ),
            ),
            json_mode=args.json,
            stream_events=False,
        )
        if args.json:
            _print_json(payload)
        else:
            print(payload["path"])
        return

    if args.command == "reexport":
        _print_json(
            _run_or_exit(
                lambda: reexport_task(
                    root_dir=root,
                    task_id=args.task_id,
                    output_format=args.output_format,
                    bilingual=args.bilingual,
                    subtitle_bilingual_order=args.subtitle_bilingual_order,
                    subtitle_prefer_single_line=args.subtitle_prefer_single_line,
                ),
                json_mode=True,
                stream_events=False,
                task_id_hint=args.task_id,
            )
        )
        return

    if args.command == "asr":
        if not args.input or not args.src:
            parser.error("asr requires --input and --src unless using setup-plan/setup-verify")
        input_type = "video_asr"
        if args.detach:
            task_id, artifacts_dir = _run_or_exit(
                lambda: create_pipeline_task(
                    root_dir=root,
                    input_file=Path(args.input).resolve(),
                    source_lang=args.src,
                    target_lang=args.src,
                    bilingual=False,
                    providers_file=providers_file,
                    cli_overrides=_common_overrides(args),
                    input_type=input_type,
                    status="QUEUED",
                ),
                json_mode=args.json,
                stream_events=False,
            )
            worker_args = ["_worker", "--task-id", task_id]
            _append_optional(worker_args, "--providers-file", str(providers_file) if providers_file else None)
            _append_common_overrides_to_args(worker_args, args)
            try:
                worker = _spawn_detached_worker(root=root, task_dir=artifacts_dir / task_id, worker_args=worker_args)
            except Exception as exc:  # noqa: BLE001 - keep detach responses machine-readable
                _handle_detached_worker_error(exc, root=root, providers_file=providers_file, task_id=task_id, json_mode=args.json)
            payload = _detach_response(task_id=task_id, artifacts_dir=artifacts_dir, worker=worker, command="asr")
            if args.json:
                _print_json(payload)
            else:
                print(task_id)
            return

        task_id = _run_or_exit(
            lambda: run_pipeline(
                root_dir=root,
                input_file=Path(args.input).resolve(),
                source_lang=args.src,
                target_lang=args.src,
                bilingual=False,
                providers_file=providers_file,
                cli_overrides=_common_overrides(args),
                input_type=input_type,
            ),
            json_mode=args.json,
            stream_events=False,
        )
        if args.json:
            _print_task_json_or_exit(root, providers_file, task_id, capability="asr")
        else:
            print(task_id)
        return

    if args.command == "translate":
        input_type = "segments_translate"
        if args.detach:
            task_id, artifacts_dir = _run_or_exit(
                lambda: create_pipeline_task(
                    root_dir=root,
                    input_file=Path(args.segments).resolve(),
                    source_lang=args.src,
                    target_lang=args.tgt,
                    bilingual=args.bilingual,
                    providers_file=providers_file,
                    cli_overrides=_common_overrides(args),
                    provider_name=args.provider,
                    model=args.model,
                    input_type=input_type,
                    status="QUEUED",
                ),
                json_mode=args.json,
                stream_events=False,
            )
            worker_args = ["_worker", "--task-id", task_id]
            _append_optional(worker_args, "--providers-file", str(providers_file) if providers_file else None)
            _append_optional(worker_args, "--output", str(Path(args.output).resolve()) if args.output else None)
            _append_optional(worker_args, "--provider", args.provider)
            _append_optional(worker_args, "--model", args.model)
            _append_common_overrides_to_args(worker_args, args)
            try:
                worker = _spawn_detached_worker(root=root, task_dir=artifacts_dir / task_id, worker_args=worker_args)
            except Exception as exc:  # noqa: BLE001 - keep detach responses machine-readable
                _handle_detached_worker_error(exc, root=root, providers_file=providers_file, task_id=task_id, json_mode=args.json)
            payload = _detach_response(task_id=task_id, artifacts_dir=artifacts_dir, worker=worker, command="translate")
            if args.json:
                _print_json(payload)
            else:
                print(task_id)
            return

        task_id = _run_or_exit(
            lambda: run_pipeline(
                root_dir=root,
                input_file=Path(args.segments).resolve(),
                source_lang=args.src,
                target_lang=args.tgt,
                bilingual=args.bilingual,
                output_file=_optional_path_arg(args.output),
                providers_file=providers_file,
                cli_overrides=_common_overrides(args),
                provider_name=args.provider,
                model=args.model,
                input_type=input_type,
            ),
            json_mode=args.json,
            stream_events=False,
        )
        if args.json:
            _print_task_json_or_exit(root, providers_file, task_id, capability="translate")
        else:
            print(task_id)
        return

    if args.command == "export":
        def do_export():
            config = load_app_config(
                root_dir=root,
                providers_file=providers_file,
                cli_overrides={"subtitle_ass_style": _subtitle_ass_style_overrides(args)}
                if _subtitle_ass_style_overrides(args)
                else None,
            )
            rows = read_json(Path(args.segments).resolve())
            segments = [Segment(**row) for row in rows]
            output = Path(args.output).resolve()
            output_format = "vtt" if args.format == "webvtt" else args.format
            output_paths: dict[str, str] = {}
            if output_format in {"srt", "both"}:
                srt_path = output.with_suffix(".srt")
                export_srt(segments, srt_path, args.bilingual)
                output_paths["srt"] = str(srt_path)
            if output_format in {"ass", "both"}:
                ass_path = output.with_suffix(".ass")
                export_ass(segments, ass_path, bilingual=args.bilingual, style=config.pipeline.subtitle_ass_style)
                output_paths["ass"] = str(ass_path)
            if output_format == "vtt":
                vtt_path = output.with_suffix(".vtt")
                export_vtt(segments, vtt_path, args.bilingual)
                output_paths["vtt"] = str(vtt_path)
            if output_format == "lrc":
                lrc_path = output.with_suffix(".lrc")
                export_lrc(segments, lrc_path, args.bilingual, style=config.pipeline.subtitle_ass_style)
                output_paths["lrc"] = str(lrc_path)
            delivery_reports = {
                fmt: subtitle_delivery_report(
                    segments,
                    output_format=fmt,
                    bilingual=args.bilingual,
                    style=config.pipeline.subtitle_ass_style,
                )
                for fmt in output_paths
                if fmt != "lrc"
            }
            return {
                "ok": True,
                "capability": "export",
                "output_format": output_format,
                "output_path": output_paths.get("srt") or output_paths.get("ass") or output_paths.get("vtt") or output_paths.get("lrc"),
                "output_paths": output_paths,
                "delivery": {fmt: report.get("summary", {}) for fmt, report in delivery_reports.items()},
            }

        payload = _run_or_exit(do_export, json_mode=args.json, stream_events=False)
        if args.json:
            _print_json(payload)
        else:
            print(payload["output_path"])
        return


if __name__ == "__main__":
    main()
