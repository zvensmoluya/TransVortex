from __future__ import annotations

import argparse
import json
from pathlib import Path

from .config import load_app_config
from .orchestrator import resume_pipeline, run_pipeline
from .probe import probe_exit_code, probe_provider
from .task_store import TaskStore


def _common_overrides(args: argparse.Namespace) -> dict:
    return {
        "chunk_seconds": args.chunk_seconds,
        "chunk_overlap_seconds": args.chunk_overlap_seconds,
        "translation_batch_size": args.translation_batch_size,
        "default_concurrency": args.concurrency,
    }


def _add_providers_file_arg(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument("--providers-file", default=None, help="Optional providers config file path")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="transvortex")
    parser.add_argument("--root", default=".", help="Project root (contains providers.yaml/pipeline.yaml)")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run", help="Run a new task")
    _add_providers_file_arg(run_p)
    run_p.add_argument("--input", required=True, help="Input video file")
    run_p.add_argument("--src", required=True, help="Source language")
    run_p.add_argument("--tgt", required=True, help="Target language")
    run_p.add_argument("--bilingual", action="store_true", help="Output bilingual subtitle")
    run_p.add_argument("--output", help="Output subtitle file path")
    run_p.add_argument("--chunk-seconds", type=int, default=None)
    run_p.add_argument("--chunk-overlap-seconds", type=int, default=None)
    run_p.add_argument("--translation-batch-size", type=int, default=None)
    run_p.add_argument("--concurrency", type=int, default=None)

    resume_p = sub.add_parser("resume", help="Resume an existing task")
    _add_providers_file_arg(resume_p)
    resume_p.add_argument("--task-id", required=True)
    resume_p.add_argument("--output", help="Optional output override")
    resume_p.add_argument("--chunk-seconds", type=int, default=None)
    resume_p.add_argument("--chunk-overlap-seconds", type=int, default=None)
    resume_p.add_argument("--translation-batch-size", type=int, default=None)
    resume_p.add_argument("--concurrency", type=int, default=None)

    status_p = sub.add_parser("status", help="Show task status")
    _add_providers_file_arg(status_p)
    status_p.add_argument("--task-id", required=True)

    probe_p = sub.add_parser("probe-provider", help="Run local provider protocol checks (no network)")
    _add_providers_file_arg(probe_p)
    probe_p.add_argument("--provider", default=None, help="Provider name, defaults to routing.primary.provider")
    probe_p.add_argument("--model", default=None, help="Model name, defaults to routing.primary.model")
    probe_p.add_argument("--source-lang", default="en")
    probe_p.add_argument("--target-lang", default="zh-CN")
    probe_p.add_argument("--strict", action="store_true", help="Return exit code 1 if any FAIL check exists")
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    root = Path(args.root).resolve()
    providers_file = Path(args.providers_file).resolve() if args.providers_file else None
    if args.command == "run":
        task_id = run_pipeline(
            root_dir=root,
            input_file=Path(args.input).resolve(),
            source_lang=args.src,
            target_lang=args.tgt,
            bilingual=args.bilingual,
            output_file=Path(args.output).resolve() if args.output else None,
            providers_file=providers_file,
            cli_overrides=_common_overrides(args),
        )
        print(task_id)
        return

    if args.command == "resume":
        task_id = resume_pipeline(
            root_dir=root,
            task_id=args.task_id,
            output_file=Path(args.output).resolve() if args.output else None,
            providers_file=providers_file,
            cli_overrides=_common_overrides(args),
        )
        print(task_id)
        return

    if args.command == "status":
        config = load_app_config(root_dir=root, providers_file=providers_file)
        store = TaskStore(config.pipeline.artifacts_dir)
        task = store.load_task(args.task_id)
        print(
            {
                "task_id": task.task_id,
                "status": task.status,
                "updated_at": task.updated_at,
                "output_path": task.output_path,
                "error": task.error,
            }
        )
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
        print(json.dumps(report, ensure_ascii=False, indent=2))
        raise SystemExit(probe_exit_code(report, strict=args.strict))


if __name__ == "__main__":
    main()
