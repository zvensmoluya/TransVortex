from __future__ import annotations

import argparse
import csv
import json
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from ..app.config import load_app_config
from ..artifacts.task_store import TaskStore
from ..core.orchestrator import _execute_task, _task_paths, create_pipeline_task
from ..memory.store import MemoryStore
from ..utils import read_json, read_jsonl, utc_now_iso, write_json


@dataclass(frozen=True)
class InjectionTranslationCase:
    case_id: str
    memory_case: str
    memory_path: Path | None
    reasoning: str
    chunk_lines: int


def _repo_root_from_arg(value: str) -> Path:
    return Path(value).resolve()


def _load_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return data if isinstance(data, dict) else {}


def _write_yaml(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")


def _load_existing_runs(output_dir: Path) -> list[dict[str, Any]]:
    summary_path = output_dir / "summary.json"
    if not summary_path.exists():
        return []
    try:
        payload = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    runs = payload.get("runs") if isinstance(payload, dict) else []
    return [item for item in runs if isinstance(item, dict)]


def _provider_without_reasoning(provider: dict[str, Any]) -> dict[str, Any]:
    out = dict(provider)
    mapping = dict(out.get("request_mapping") or {})
    body_overrides = dict(mapping.get("body_overrides") or {})
    body_overrides.pop("reasoning", None)
    body_overrides.pop("reasoning_effort", None)
    mapping["body_overrides"] = body_overrides
    out["request_mapping"] = mapping
    return out


def _provider_with_reasoning(provider: dict[str, Any], effort: str) -> dict[str, Any]:
    if effort == "none":
        return _provider_without_reasoning(provider)
    out = dict(provider)
    mapping = dict(out.get("request_mapping") or {})
    body_overrides = dict(mapping.get("body_overrides") or {})
    body_overrides["reasoning"] = {"effort": effort}
    mapping["body_overrides"] = body_overrides
    out["request_mapping"] = mapping
    return out


def _apply_case_limits(provider: dict[str, Any], timeout_seconds: int, read_timeout_seconds: int) -> dict[str, Any]:
    out = dict(provider)
    limits = dict(out.get("limits") or {})
    limits["timeout_seconds"] = int(timeout_seconds)
    limits["read_timeout_seconds"] = int(read_timeout_seconds)
    out["limits"] = limits
    return out


def _build_case_providers(
    root: Path,
    base_provider: str,
    case: InjectionTranslationCase,
    output_dir: Path,
    timeout_seconds: int,
    read_timeout_seconds: int,
) -> Path:
    payload = _load_yaml(root / "providers.yaml")
    providers = list(payload.get("providers") or [])
    source = next((item for item in providers if isinstance(item, dict) and item.get("name") == base_provider), None)
    if source is None:
        raise RuntimeError(f"Provider not found in providers.yaml: {base_provider}")
    provider = _provider_with_reasoning(source, case.reasoning)
    provider = _apply_case_limits(provider, timeout_seconds, read_timeout_seconds)
    provider["name"] = f"{base_provider}_meminj_{case.case_id}"
    case_payload = {
        "providers": [provider],
        "routing": {
            "primary": {
                "provider": provider["name"],
                "model": (provider.get("models") or [""])[0],
            },
            "fallback": [],
        },
    }
    path = output_dir / "configs" / f"{case.case_id}.providers.yaml"
    _write_yaml(path, case_payload)
    return path


def _copy_experiment_output(root: Path, task_id: str, output_dir: Path, case: InjectionTranslationCase) -> Path:
    source = root / "artifacts" / task_id
    target = output_dir / "runs" / case.case_id / task_id
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    return target


def _sum_usage(metrics: list[dict[str, Any]]) -> dict[str, int]:
    totals: dict[str, int] = {}
    for row in metrics:
        usage = row.get("usage") if isinstance(row.get("usage"), dict) else {}
        for key, value in usage.items():
            if isinstance(value, int):
                totals[key] = totals.get(key, 0) + value
    return totals


def _first_byte_ms(provider_meta: dict[str, Any]) -> int:
    started = provider_meta.get("request_started_at")
    first = provider_meta.get("first_byte_at")
    if isinstance(started, (int, float)) and isinstance(first, (int, float)):
        return max(0, int(round((first - started) * 1000)))
    return 0


def _case_summary(
    case: InjectionTranslationCase,
    task_id: str,
    artifact_dir: Path,
    elapsed_ms_wall: int,
) -> dict[str, Any]:
    metrics = read_jsonl(artifact_dir / "translate" / "metrics.jsonl")
    provider_elapsed_ms = sum(
        int((row.get("provider_meta") or {}).get("elapsed_ms") or 0)
        for row in metrics
        if isinstance(row, dict)
    )
    first_byte_values = [
        _first_byte_ms(row.get("provider_meta") or {})
        for row in metrics
        if isinstance(row, dict) and isinstance(row.get("provider_meta"), dict)
    ]
    raw_chars = sum(int(row.get("raw_text_chars") or 0) for row in metrics if isinstance(row, dict))
    line_count = sum(int(row.get("line_count") or 0) for row in metrics if isinstance(row, dict))
    issue_count = sum(
        int((row.get("validation") or {}).get("issue_count") or 0)
        for row in metrics
        if isinstance(row, dict)
    )
    memory_entries_total = sum(int(row.get("memory_entries") or 0) for row in metrics if isinstance(row, dict))
    memory_prompt_chars_total = sum(int(row.get("memory_prompt_chars") or 0) for row in metrics if isinstance(row, dict))
    memory_doc_entries = 0
    if case.memory_path is not None:
        memory_doc_entries = len(MemoryStore(artifact_dir / "memory").load_runtime().entries)
    consistency_issues = len(read_jsonl(artifact_dir / "memory" / "consistency_issues.jsonl"))
    task_payload = read_json(artifact_dir / "task.json") if (artifact_dir / "task.json").exists() else {}
    output_paths = task_payload.get("output_paths") if isinstance(task_payload.get("output_paths"), dict) else {}
    return {
        "case_id": case.case_id,
        "task_id": task_id,
        "memory_case": case.memory_case,
        "memory_source": str(case.memory_path or ""),
        "memory_doc_entries": memory_doc_entries,
        "reasoning": case.reasoning,
        "chunk_lines": case.chunk_lines,
        "chunks": len(metrics),
        "lines": line_count,
        "elapsed_ms_wall": elapsed_ms_wall,
        "provider_elapsed_ms_sum": provider_elapsed_ms,
        "first_byte_ms_avg": int(round(sum(first_byte_values) / len(first_byte_values))) if first_byte_values else 0,
        "raw_text_chars": raw_chars,
        "validation_issues": issue_count,
        "memory_entries_total": memory_entries_total,
        "memory_entries_avg": round(memory_entries_total / len(metrics), 2) if metrics else 0,
        "memory_prompt_chars_total": memory_prompt_chars_total,
        "consistency_issues": consistency_issues,
        "usage": _sum_usage(metrics),
        "output_srt": output_paths.get("srt", ""),
        "artifact_dir": str(artifact_dir),
    }


def _write_summary(output_dir: Path, summaries: list[dict[str, Any]]) -> None:
    write_json(output_dir / "summary.json", {"created_at": utc_now_iso(), "runs": summaries})
    fieldnames = [
        "case_id",
        "memory_case",
        "reasoning",
        "chunk_lines",
        "chunks",
        "lines",
        "elapsed_ms_wall",
        "provider_elapsed_ms_sum",
        "first_byte_ms_avg",
        "validation_issues",
        "memory_doc_entries",
        "memory_entries_total",
        "memory_entries_avg",
        "memory_prompt_chars_total",
        "consistency_issues",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "task_id",
        "output_srt",
        "artifact_dir",
        "memory_source",
    ]
    rows = []
    for item in summaries:
        usage = item.get("usage") if isinstance(item.get("usage"), dict) else {}
        rows.append(
            {
                "case_id": item.get("case_id", ""),
                "memory_case": item.get("memory_case", ""),
                "reasoning": item.get("reasoning", ""),
                "chunk_lines": item.get("chunk_lines", ""),
                "chunks": item.get("chunks", ""),
                "lines": item.get("lines", ""),
                "elapsed_ms_wall": item.get("elapsed_ms_wall", ""),
                "provider_elapsed_ms_sum": item.get("provider_elapsed_ms_sum", ""),
                "first_byte_ms_avg": item.get("first_byte_ms_avg", ""),
                "validation_issues": item.get("validation_issues", ""),
                "memory_doc_entries": item.get("memory_doc_entries", ""),
                "memory_entries_total": item.get("memory_entries_total", ""),
                "memory_entries_avg": item.get("memory_entries_avg", ""),
                "memory_prompt_chars_total": item.get("memory_prompt_chars_total", ""),
                "consistency_issues": item.get("consistency_issues", ""),
                "input_tokens": usage.get("input_tokens", usage.get("prompt_tokens", "")),
                "output_tokens": usage.get("output_tokens", usage.get("completion_tokens", "")),
                "total_tokens": usage.get("total_tokens", ""),
                "task_id": item.get("task_id", ""),
                "output_srt": item.get("output_srt", ""),
                "artifact_dir": item.get("artifact_dir", ""),
                "memory_source": item.get("memory_source", ""),
            }
        )
    csv_path = output_dir / "summary.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _copy_case_inputs(case_dir: Path, providers_file: Path, sample: Path, memory_path: Path | None) -> None:
    inputs_dir = case_dir / "inputs"
    inputs_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(providers_file, inputs_dir / providers_file.name)
    shutil.copy2(sample, inputs_dir / sample.name)
    if memory_path is not None:
        shutil.copy2(memory_path, inputs_dir / f"{memory_path.parent.parent.name}.translation_memory.json")
        bootstrap_json = memory_path.with_name("bootstrap.json")
        if bootstrap_json.exists():
            shutil.copy2(bootstrap_json, inputs_dir / f"{memory_path.parent.parent.name}.bootstrap.json")


def _preload_memory(memory_dir: Path, memory_path: Path) -> None:
    memory_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(memory_path, memory_dir / "translation_memory.json")


def _configure_for_case(config: Any, case: InjectionTranslationCase, memory_intensity: str) -> None:
    config.pipeline.translation.chunk_lines = case.chunk_lines
    config.pipeline.translation.context_before_lines = 40
    config.pipeline.translation.context_after_lines = 20
    config.pipeline.translation.batching.mode = "fixed"
    config.pipeline.translation.chunking.mode = "fixed"
    config.pipeline.translation.experiment_logging.enabled = True
    config.pipeline.translation.experiment_logging.save_raw_text = True
    config.pipeline.translation.experiment_logging.save_metrics = True
    config.pipeline.translation.experiment_logging.label = case.case_id
    config.pipeline.memory.patch.enabled = False
    if case.memory_path is None:
        config.pipeline.memory.enabled = False
        return
    config.pipeline.memory.enabled = True
    config.pipeline.memory.bootstrap.enabled = False
    config.pipeline.memory.inject.enabled = True
    config.pipeline.memory.inject.locked = True
    config.pipeline.memory.inject.confirmed = True
    config.pipeline.memory.inject.proposed = True
    config.pipeline.memory.inject.intensity = str(memory_intensity or "high")


def _run_case(
    *,
    root: Path,
    sample: Path,
    output_dir: Path,
    base_provider: str,
    case: InjectionTranslationCase,
    timeout_seconds: int,
    provider_timeout_seconds: int,
    provider_read_timeout_seconds: int,
    memory_intensity: str,
) -> dict[str, Any]:
    providers_file = _build_case_providers(
        root,
        base_provider,
        case,
        output_dir,
        provider_timeout_seconds,
        provider_read_timeout_seconds,
    )
    cli_overrides = {
        "translation_chunk_lines": case.chunk_lines,
        "translation_context_before_lines": 40,
        "translation_context_after_lines": 20,
        "translation_batching_mode": "fixed",
        "translation_chunking_mode": "fixed",
        "translation_experiment_logging_enabled": True,
        "translation_experiment_label": case.case_id,
        "memory_enabled": case.memory_path is not None,
        "memory_bootstrap_enabled": False,
        "memory_inject_enabled": case.memory_path is not None,
    }
    task_id, artifacts_dir = create_pipeline_task(
        root_dir=root,
        input_file=sample,
        source_lang="ja",
        target_lang="zh-CN",
        providers_file=providers_file,
        cli_overrides=cli_overrides,
        input_type="segments_translate",
        status="QUEUED",
    )
    store = TaskStore(artifacts_dir)
    paths = _task_paths(store, task_id)
    if case.memory_path is not None:
        _preload_memory(paths["memory"], case.memory_path)
    config = load_app_config(root_dir=root, providers_file=providers_file, cli_overrides=cli_overrides)
    _configure_for_case(config, case, memory_intensity)
    case_run_dir = output_dir / "runs" / case.case_id
    if case_run_dir.exists():
        shutil.rmtree(case_run_dir)
    _copy_case_inputs(case_run_dir, providers_file, sample, case.memory_path)
    started = time.perf_counter()
    try:
        _execute_task(
            config,
            store,
            task_id,
            root_dir=root,
            providers_file=providers_file,
        )
    except Exception:
        _copy_experiment_output(root, task_id, output_dir, case)
        raise
    elapsed_ms_wall = int(round((time.perf_counter() - started) * 1000))
    artifact_dir = _copy_experiment_output(root, task_id, output_dir, case)
    return _case_summary(case, task_id, artifact_dir, elapsed_ms_wall)


def _parse_strings(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def _memory_path_for_case(root: Path, bootstrap_root: Path, memory_case: str) -> Path | None:
    if memory_case == "off":
        return None
    path = bootstrap_root / "runs" / f"{memory_case}_bootstrap" / "memory" / "translation_memory.json"
    resolved = path if path.is_absolute() else (root / path)
    if not resolved.exists():
        raise FileNotFoundError(f"Memory case not found: {memory_case} ({resolved})")
    return resolved.resolve()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run fixed bootstrap-memory injection translation experiments.")
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--sample", required=True, help="Segment JSONL sample")
    parser.add_argument("--output-dir", default="artifacts/experiments/memory_bootstrap_injection_translation")
    parser.add_argument("--bootstrap-root", default="artifacts/experiments/memory_bootstrap_only")
    parser.add_argument("--base-provider", default="zven_openai_responses")
    parser.add_argument("--reasoning", default="low")
    parser.add_argument("--memory-cases", default="off,medium", help="Comma-separated: off,none,medium,high")
    parser.add_argument("--chunk-lines", type=int, default=120)
    parser.add_argument("--memory-intensity", default="high", choices=["none", "low", "auto", "high", "max"])
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument("--provider-timeout-seconds", type=int, default=900)
    parser.add_argument("--provider-read-timeout-seconds", type=int, default=900)
    parser.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Resume from existing summary.json and skip completed cases.",
    )
    parser.add_argument("--limit", type=int, default=0, help="Run only the first N cases")
    args = parser.parse_args(argv)

    root = _repo_root_from_arg(args.root)
    sample_path = Path(args.sample)
    sample = sample_path.resolve() if sample_path.is_absolute() else (root / sample_path).resolve()
    output_dir = (root / args.output_dir).resolve() if not Path(args.output_dir).is_absolute() else Path(args.output_dir)
    bootstrap_root_arg = Path(args.bootstrap_root)
    bootstrap_root = bootstrap_root_arg if bootstrap_root_arg.is_absolute() else root / bootstrap_root_arg
    output_dir.mkdir(parents=True, exist_ok=True)
    cases = [
        InjectionTranslationCase(
            case_id=f"{memory_case}_memory_{args.reasoning}_chunk{args.chunk_lines}",
            memory_case=memory_case,
            memory_path=_memory_path_for_case(root, bootstrap_root, memory_case),
            reasoning=args.reasoning,
            chunk_lines=int(args.chunk_lines),
        )
        for memory_case in _parse_strings(args.memory_cases)
    ]
    if args.limit > 0:
        cases = cases[: args.limit]
    existing_runs = _load_existing_runs(output_dir) if args.resume else []
    completed_case_ids = {str(item.get("case_id")) for item in existing_runs if item.get("case_id")}
    write_json(
        output_dir / "manifest.json",
        {
            "created_at": utc_now_iso(),
            "sample": str(sample),
            "bootstrap_root": str(bootstrap_root),
            "base_provider": args.base_provider,
            "reasoning": args.reasoning,
            "chunk_lines": int(args.chunk_lines),
            "memory_intensity": str(args.memory_intensity),
            "resume": bool(args.resume),
            "provider_timeout_seconds": int(args.provider_timeout_seconds),
            "provider_read_timeout_seconds": int(args.provider_read_timeout_seconds),
            "cases": [
                {
                    "case_id": case.case_id,
                    "memory_case": case.memory_case,
                    "memory_path": str(case.memory_path or ""),
                    "reasoning": case.reasoning,
                    "chunk_lines": case.chunk_lines,
                }
                for case in cases
            ],
        },
    )
    summaries: list[dict[str, Any]] = list(existing_runs)
    for case in cases:
        if args.resume and case.case_id in completed_case_ids:
            continue
        summaries.append(
            _run_case(
                root=root,
                sample=sample,
                output_dir=output_dir,
                base_provider=args.base_provider,
                case=case,
                timeout_seconds=args.timeout_seconds,
                provider_timeout_seconds=args.provider_timeout_seconds,
                provider_read_timeout_seconds=args.provider_read_timeout_seconds,
                memory_intensity=args.memory_intensity,
            )
        )
        completed_case_ids.add(case.case_id)
        _write_summary(output_dir, summaries)
    if args.resume and existing_runs and len(summaries) == len(existing_runs):
        _write_summary(output_dir, summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
