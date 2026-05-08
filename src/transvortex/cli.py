from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from .config import apply_route_overrides, load_app_config, resolve_providers_file
from .doctor import doctor_report, format_doctor_report
from .orchestrator import resume_pipeline, run_pipeline, task_status_json
from .probe import probe_exit_code, probe_provider
from .provider_admin import (
    delete_provider_config,
    fetch_provider_models,
    provider_templates_payload,
    run_provider_connection_test,
    save_provider_config,
    save_provider_routing,
)
from .result_workspace import open_task_result, reexport_task, save_task_segments
from .task_store import TaskStore
from .utils import to_plain


def _common_overrides(args: argparse.Namespace) -> dict:
    return {
        "chunk_seconds": args.chunk_seconds,
        "chunk_overlap_seconds": args.chunk_overlap_seconds,
        "translation_batch_size": args.translation_batch_size,
        "default_concurrency": args.concurrency,
        "asr_mode": args.asr_mode,
        "asr_device": args.asr_device,
        "asr_model_size": args.asr_model_size,
        "asr_compute_type": args.asr_compute_type,
        "asr_provider": args.asr_provider,
        "asr_provider_model": args.asr_model,
        "output_format": getattr(args, "output_format", None),
        "translation_style_preset": getattr(args, "translation_style_preset", None),
        "translation_style_prompt": getattr(args, "translation_style_prompt", None),
        "translation_chunk_lines": getattr(args, "translation_chunk_lines", None),
        "translation_context_before_lines": getattr(args, "translation_context_before_lines", None),
        "translation_context_after_lines": getattr(args, "translation_context_after_lines", None),
        "translation_repair_enabled": getattr(args, "translation_repair_enabled", None),
    }


def _add_providers_file_arg(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--providers-file", default=None, help="Optional providers config file path")


def _print_json(data: object) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def _print_jsonl_event(event: dict[str, Any]) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def _add_pipeline_override_args(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--chunk-seconds", type=int, default=None)
    subparser.add_argument("--chunk-overlap-seconds", type=int, default=None)
    subparser.add_argument("--translation-batch-size", type=int, default=None)
    subparser.add_argument("--concurrency", type=int, default=None)
    subparser.add_argument("--asr-mode", choices=["local", "openai"], default=None)
    subparser.add_argument("--asr-device", default=None)
    subparser.add_argument("--asr-model-size", default=None)
    subparser.add_argument("--asr-compute-type", default=None)
    subparser.add_argument("--asr-provider", default=None)
    subparser.add_argument("--asr-model", default=None)
    subparser.add_argument("--output-format", choices=["srt", "ass", "both"], default=None)
    subparser.add_argument("--translation-style-preset", default=None)
    subparser.add_argument("--translation-style-prompt", default=None)
    subparser.add_argument("--translation-chunk-lines", type=int, default=None)
    subparser.add_argument("--translation-context-before-lines", type=int, default=None)
    subparser.add_argument("--translation-context-after-lines", type=int, default=None)
    subparser.add_argument("--translation-repair-enabled", choices=["true", "false"], default=None)


def _add_route_override_args(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--provider", default=None, help="Translation provider override")
    subparser.add_argument("--model", default=None, help="Translation model override")


def _task_payload(task, artifacts_dir: Path | None = None) -> dict[str, Any]:
    payload = task_status_json(task)
    if artifacts_dir is not None:
        payload["task_dir"] = str(artifacts_dir / task.task_id)
    return payload


def _config_show_payload(root: Path, providers_file: Path | None) -> dict[str, Any]:
    resolved_providers_file = resolve_providers_file(root, providers_file)
    config = load_app_config(root_dir=root, providers_file=providers_file)
    providers = []
    for provider in config.providers.values():
        providers.append(
            {
                "name": provider.name,
                "api_type": provider.api_type,
                "compat_mode": provider.compat_mode,
                "base_url": provider.base_url,
                "env_key": provider.env_key,
                "has_key": bool(os.getenv(provider.env_key)),
                "models": provider.models,
                "auth": to_plain(provider.auth),
                "endpoint": to_plain(provider.endpoint),
                "request_mapping": provider.mapping.request,
                "response_mapping": provider.mapping.response,
                "extra_headers": provider.extra_headers,
                "model_list": to_plain(provider.model_list),
                "limits": to_plain(provider.limits),
                "capabilities": to_plain(provider.capabilities),
            }
        )
    return {
        "root_dir": str(root),
        "providers_file": str(resolved_providers_file),
        "artifacts_dir": str(config.pipeline.artifacts_dir),
        "pipeline": to_plain(config.pipeline),
        "routing": to_plain(config.routing),
        "provider_templates": provider_templates_payload(),
        "providers": sorted(providers, key=lambda row: row["name"]),
    }


def _read_json_arg(raw: str) -> dict[str, Any]:
    if raw.startswith("@"):
        raw = Path(raw[1:]).read_text(encoding="utf-8")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("JSON payload must be an object")
    return payload


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="transvortex")
    parser.add_argument("--root", default=".", help="Project root (contains providers.yaml/pipeline.yaml)")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run", help="Run a new task")
    _add_providers_file_arg(run_p)
    run_p.add_argument("--input", required=True, help="Input video file")
    run_p.add_argument("--input-type", choices=["video", "srt", "video_asr_translate", "srt_translate"], default="video")
    run_p.add_argument("--src", required=True, help="Source language")
    run_p.add_argument("--tgt", required=True, help="Target language")
    run_p.add_argument("--bilingual", action="store_true", help="Output bilingual subtitle")
    run_p.add_argument("--output", help="Output subtitle file path")
    _add_pipeline_override_args(run_p)
    _add_route_override_args(run_p)
    run_p.add_argument("--json", action="store_true", help="Print machine-readable task status")
    run_p.add_argument("--stream-events", action="store_true", help="Stream task events as JSONL")

    resume_p = sub.add_parser("resume", help="Resume an existing task")
    _add_providers_file_arg(resume_p)
    resume_p.add_argument("--task-id", required=True)
    resume_p.add_argument("--output", help="Optional output override")
    _add_pipeline_override_args(resume_p)
    _add_route_override_args(resume_p)
    resume_p.add_argument("--json", action="store_true", help="Print machine-readable task status")
    resume_p.add_argument("--stream-events", action="store_true", help="Stream task events as JSONL")

    status_p = sub.add_parser("status", help="Show task status")
    _add_providers_file_arg(status_p)
    status_p.add_argument("--task-id", required=True)
    status_p.add_argument("--json", action="store_true", help="Print machine-readable task status")

    events_p = sub.add_parser("events", help="Print task events as JSONL")
    _add_providers_file_arg(events_p)
    events_p.add_argument("--task-id", required=True)

    cancel_p = sub.add_parser("cancel", help="Request cancellation for a task")
    _add_providers_file_arg(cancel_p)
    cancel_p.add_argument("--task-id", required=True)
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
    provider_save_p.add_argument("--json", action="store_true")

    provider_delete_p = provider_sub.add_parser("delete", help="Delete provider config from providers.local.yaml")
    provider_delete_p.add_argument("--name", required=True)
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

    result_p = sub.add_parser("result", help="Inspect or edit task results")
    result_sub = result_p.add_subparsers(dest="result_command", required=True)
    result_open_p = result_sub.add_parser("open", help="Open task result data")
    result_open_p.add_argument("--task-id", required=True)
    result_open_p.add_argument("--json", action="store_true")
    result_save_p = result_sub.add_parser("save", help="Save edited task segments")
    result_save_p.add_argument("--task-id", required=True)
    result_save_p.add_argument("--json-payload", required=True)
    result_save_p.add_argument("--json", action="store_true")

    reexport_p = sub.add_parser("reexport", help="Re-export subtitles from task final segments")
    reexport_p.add_argument("--task-id", required=True)
    reexport_p.add_argument("--output-format", choices=["srt", "ass", "both"], default=None)
    reexport_p.add_argument("--json", action="store_true")
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    root = Path(args.root).resolve()
    raw_providers_file = getattr(args, "providers_file", None)
    providers_file = Path(raw_providers_file).resolve() if raw_providers_file else None
    if args.command == "run":
        if args.json and args.stream_events:
            parser.error("run: --json and --stream-events cannot be used together")
        task_id = run_pipeline(
            root_dir=root,
            input_file=Path(args.input).resolve(),
            source_lang=args.src,
            target_lang=args.tgt,
            bilingual=args.bilingual,
            output_file=Path(args.output).resolve() if args.output else None,
            providers_file=providers_file,
            cli_overrides=_common_overrides(args),
            provider_name=args.provider,
            model=args.model,
            input_type="srt_translate" if args.input_type in {"srt", "srt_translate"} else "video_asr_translate",
            event_sink=_print_jsonl_event if args.stream_events else None,
        )
        if args.json:
            config = load_app_config(root_dir=root, providers_file=providers_file)
            config = apply_route_overrides(config, provider_name=args.provider, model=args.model)
            task = TaskStore(config.pipeline.artifacts_dir).load_task(task_id)
            _print_json(_task_payload(task, config.pipeline.artifacts_dir))
        elif not args.stream_events:
            print(task_id)
        else:
            sys.stdout.flush()
        return

    if args.command == "resume":
        if args.json and args.stream_events:
            parser.error("resume: --json and --stream-events cannot be used together")
        task_id = resume_pipeline(
            root_dir=root,
            task_id=args.task_id,
            output_file=Path(args.output).resolve() if args.output else None,
            providers_file=providers_file,
            cli_overrides=_common_overrides(args),
            provider_name=args.provider,
            model=args.model,
            event_sink=_print_jsonl_event if args.stream_events else None,
        )
        if args.json:
            config = load_app_config(root_dir=root, providers_file=providers_file)
            config = apply_route_overrides(config, provider_name=args.provider, model=args.model)
            task = TaskStore(config.pipeline.artifacts_dir).load_task(task_id)
            _print_json(_task_payload(task, config.pipeline.artifacts_dir))
        elif not args.stream_events:
            print(task_id)
        else:
            sys.stdout.flush()
        return

    if args.command == "status":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        task = store.load_task(args.task_id)
        payload = _task_payload(task, config.pipeline.artifacts_dir)
        if args.json:
            _print_json(payload)
        else:
            print(payload)
        return

    if args.command == "events":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        for event in store.read_events(args.task_id):
            print(json.dumps(event, ensure_ascii=False))
        return

    if args.command == "cancel":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        task = store.request_cancel(args.task_id)
        payload = task_status_json(task)
        if args.json:
            _print_json(payload)
        else:
            print(f"{task.task_id} {task.status}")
        return

    if args.command == "tasks":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        payload = [_task_payload(task, config.pipeline.artifacts_dir) for task in store.list_tasks()]
        if args.json:
            _print_json(payload)
        else:
            for task in payload:
                print(f"{task['task_id']} {task['status']} {task['updated_at']}")
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
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "delete":
        payload = delete_provider_config(root_dir=root, name=args.name)
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "models":
        payload = fetch_provider_models(
            provider_draft=_read_json_arg(args.json_payload),
            api_key=args.api_key,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "test":
        payload = run_provider_connection_test(
            provider_draft=_read_json_arg(args.json_payload),
            model=args.model,
            api_key=args.api_key,
        )
        _print_json(payload)
        return

    if args.command == "provider" and args.provider_command == "routing":
        payload = save_provider_routing(root_dir=root, routing=_read_json_arg(args.json_payload))
        _print_json(payload)
        return

    if args.command == "result" and args.result_command == "open":
        _print_json(open_task_result(root_dir=root, task_id=args.task_id))
        return

    if args.command == "result" and args.result_command == "save":
        raw = _read_json_arg(args.json_payload)
        segments = raw.get("segments", [])
        if not isinstance(segments, list):
            raise ValueError("segments must be a list")
        _print_json(save_task_segments(root_dir=root, task_id=args.task_id, segments_payload=segments))
        return

    if args.command == "reexport":
        _print_json(reexport_task(root_dir=root, task_id=args.task_id, output_format=args.output_format))
        return


if __name__ == "__main__":
    main()
