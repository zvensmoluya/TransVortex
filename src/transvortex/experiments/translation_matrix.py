from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from ..utils import read_jsonl, utc_now_iso, write_json


@dataclass(frozen=True)
class ExperimentCase:
    case_id: str
    reasoning: str
    chunk_lines: int
    chunk_spec: str
    model: str
    repeat: int = 1
    omit_temperature: bool = False
    omit_output_token_limit: bool = False
    memory_presets: tuple[str, ...] = ()
    memory_intensity: str = ""


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


def _apply_case_limits(
    provider: dict[str, Any],
    timeout_seconds: int,
    read_timeout_seconds: int,
) -> dict[str, Any]:
    out = dict(provider)
    limits = dict(out.get("limits") or {})
    limits["timeout_seconds"] = int(timeout_seconds)
    limits["read_timeout_seconds"] = int(read_timeout_seconds)
    out["limits"] = limits
    return out


def _build_case_providers(
    root: Path,
    base_provider: str,
    case: ExperimentCase,
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
    if case.omit_temperature:
        capabilities = dict(provider.get("capabilities") or {})
        capabilities["supports_temperature"] = False
        provider["capabilities"] = capabilities
    if case.omit_output_token_limit:
        capabilities = dict(provider.get("capabilities") or {})
        capabilities["output_token_param"] = "none"
        provider["capabilities"] = capabilities
    provider["models"] = [case.model]
    model_configs = dict(provider.get("model_configs") or {})
    model_config = dict(model_configs.get(case.model) or {})
    model_config["max_batch_lines"] = case.chunk_lines
    model_configs[case.model] = model_config
    provider["model_configs"] = model_configs
    provider["name"] = f"{base_provider}_{case.case_id}"
    case_payload = {
        "providers": [provider],
        "routing": {
            "primary": {
                "provider": provider["name"],
                "model": case.model,
            },
            "fallback": [],
        },
    }
    path = output_dir / "configs" / f"{case.case_id}.providers.yaml"
    _write_yaml(path, case_payload)
    return path


def _copy_experiment_output(root: Path, task_id: str, output_dir: Path, case: ExperimentCase) -> Path:
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
            elif isinstance(value, dict):
                for detail_key, detail_value in value.items():
                    if isinstance(detail_value, int):
                        flat_key = f"{key}.{detail_key}"
                        totals[flat_key] = totals.get(flat_key, 0) + detail_value
    return totals


def _first_byte_ms(provider_meta: dict[str, Any]) -> int | None:
    started = provider_meta.get("request_started_at")
    first = provider_meta.get("first_byte_at")
    if isinstance(started, (int, float)) and isinstance(first, (int, float)):
        return max(0, int(round((first - started) * 1000)))
    return None


def _median_ms(values: list[int]) -> int:
    ordered = sorted(values)
    if not ordered:
        return 0
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return int(round((ordered[middle - 1] + ordered[middle]) / 2))


def _case_summary(
    case: ExperimentCase,
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
        value
        for row in metrics
        if isinstance(row, dict) and isinstance(row.get("provider_meta"), dict)
        if (value := _first_byte_ms(row["provider_meta"])) is not None
    ]
    raw_chars = sum(int(row.get("raw_text_chars") or 0) for row in metrics if isinstance(row, dict))
    line_count = sum(int(row.get("line_count") or 0) for row in metrics if isinstance(row, dict))
    issue_count = sum(
        int((row.get("validation") or {}).get("issue_count") or 0)
        for row in metrics
        if isinstance(row, dict)
    )
    repair_requests = sum(int(row.get("repairs") or 0) for row in metrics if isinstance(row, dict))
    recovered_chunks = sum(bool(row.get("protocol_recovered")) for row in metrics if isinstance(row, dict))
    batch_recovery_requests = sum(
        int(row.get("batch_recovery_requests") or 0) for row in metrics if isinstance(row, dict)
    )
    memory_entries_total = sum(int(row.get("memory_entries") or 0) for row in metrics if isinstance(row, dict))
    memory_prompt_chars_total = sum(
        int(row.get("memory_prompt_chars") or 0) for row in metrics if isinstance(row, dict)
    )
    consistency_path = artifact_dir / "memory" / "consistency_issues.jsonl"
    consistency_issues = len(read_jsonl(consistency_path)) if consistency_path.exists() else 0
    summary = {
        "case_id": case.case_id,
        "task_id": task_id,
        "model": case.model,
        "reasoning": case.reasoning,
        "chunk_lines": case.chunk_lines,
        "chunk_spec": case.chunk_spec,
        "repeat": case.repeat,
        "omit_temperature": case.omit_temperature,
        "omit_output_token_limit": case.omit_output_token_limit,
        "memory_presets": list(case.memory_presets),
        "memory_intensity": case.memory_intensity,
        "chunks": len(metrics),
        "lines": line_count,
        "elapsed_ms_wall": elapsed_ms_wall,
        "provider_elapsed_ms_sum": provider_elapsed_ms,
        "first_byte_ms_avg": (
            int(round(sum(first_byte_values) / len(first_byte_values))) if first_byte_values else 0
        ),
        "first_byte_ms_p50": _median_ms(first_byte_values),
        "first_byte_ms_max": max(first_byte_values, default=0),
        "raw_text_chars": raw_chars,
        "validation_issues": issue_count,
        "repair_requests": repair_requests,
        "recovered_chunks": recovered_chunks,
        "batch_recovery_requests": batch_recovery_requests,
        "memory_entries_total": memory_entries_total,
        "memory_entries_avg": round(memory_entries_total / len(metrics), 2) if metrics else 0,
        "memory_prompt_chars_total": memory_prompt_chars_total,
        "consistency_issues": consistency_issues,
        "usage": _sum_usage(metrics),
        "artifact_dir": str(artifact_dir),
    }
    return summary


def _write_summary(output_dir: Path, summaries: list[dict[str, Any]]) -> None:
    write_json(output_dir / "summary.json", {"created_at": utc_now_iso(), "runs": summaries})
    fieldnames = [
        "case_id",
        "model",
        "reasoning",
        "chunk_spec",
        "chunk_lines",
        "repeat",
        "omit_temperature",
        "omit_output_token_limit",
        "memory_presets",
        "memory_intensity",
        "chunks",
        "lines",
        "elapsed_ms_wall",
        "provider_elapsed_ms_sum",
        "first_byte_ms_avg",
        "first_byte_ms_p50",
        "first_byte_ms_max",
        "raw_text_chars",
        "validation_issues",
        "repair_requests",
        "recovered_chunks",
        "batch_recovery_requests",
        "memory_entries_total",
        "memory_entries_avg",
        "memory_prompt_chars_total",
        "consistency_issues",
        "input_tokens",
        "output_tokens",
        "reasoning_tokens",
        "total_tokens",
        "task_id",
        "artifact_dir",
    ]
    rows = []
    for item in summaries:
        usage = item.get("usage") if isinstance(item.get("usage"), dict) else {}
        rows.append(
            {
                "case_id": item.get("case_id", ""),
                "model": item.get("model", ""),
                "reasoning": item.get("reasoning", ""),
                "chunk_spec": item.get("chunk_spec", ""),
                "chunk_lines": item.get("chunk_lines", ""),
                "repeat": item.get("repeat", ""),
                "omit_temperature": item.get("omit_temperature", ""),
                "omit_output_token_limit": item.get("omit_output_token_limit", ""),
                "memory_presets": ",".join(item.get("memory_presets") or []),
                "memory_intensity": item.get("memory_intensity", ""),
                "chunks": item.get("chunks", ""),
                "lines": item.get("lines", ""),
                "elapsed_ms_wall": item.get("elapsed_ms_wall", ""),
                "provider_elapsed_ms_sum": item.get("provider_elapsed_ms_sum", ""),
                "first_byte_ms_avg": item.get("first_byte_ms_avg", ""),
                "first_byte_ms_p50": item.get("first_byte_ms_p50", ""),
                "first_byte_ms_max": item.get("first_byte_ms_max", ""),
                "raw_text_chars": item.get("raw_text_chars", ""),
                "validation_issues": item.get("validation_issues", ""),
                "repair_requests": item.get("repair_requests", ""),
                "recovered_chunks": item.get("recovered_chunks", ""),
                "batch_recovery_requests": item.get("batch_recovery_requests", ""),
                "memory_entries_total": item.get("memory_entries_total", ""),
                "memory_entries_avg": item.get("memory_entries_avg", ""),
                "memory_prompt_chars_total": item.get("memory_prompt_chars_total", ""),
                "consistency_issues": item.get("consistency_issues", ""),
                "input_tokens": usage.get("input_tokens", usage.get("prompt_tokens", "")),
                "output_tokens": usage.get("output_tokens", usage.get("completion_tokens", "")),
                "reasoning_tokens": usage.get(
                    "output_tokens_details.reasoning_tokens",
                    usage.get("completion_tokens_details.reasoning_tokens", ""),
                ),
                "total_tokens": usage.get("total_tokens", ""),
                "task_id": item.get("task_id", ""),
                "artifact_dir": item.get("artifact_dir", ""),
            }
        )
    csv_path = output_dir / "summary.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _memory_cli_args(case: ExperimentCase) -> list[str]:
    if not case.memory_presets:
        return ["--memory-enabled", "false"]
    return [
        "--memory-enabled",
        "true",
        "--memory-bootstrap-enabled",
        "false",
        "--memory-inject-enabled",
        "true",
        "--memory-patch-enabled",
        "false",
        "--memory-intensity",
        case.memory_intensity or "auto",
        "--memory-preset",
        ",".join(case.memory_presets),
    ]


def _run_case(
    root: Path,
    sample: Path,
    output_dir: Path,
    base_provider: str,
    case: ExperimentCase,
    timeout: int,
    provider_timeout_seconds: int,
    provider_read_timeout_seconds: int,
    source_lang: str,
    target_lang: str,
) -> dict[str, Any]:
    providers_file = _build_case_providers(
        root,
        base_provider,
        case,
        output_dir,
        provider_timeout_seconds,
        provider_read_timeout_seconds,
    )
    cmd = [
        sys.executable,
        "-m",
        "transvortex.cli",
        "--root",
        str(root),
        "translate",
        "--segments",
        str(sample),
        "--src",
        source_lang,
        "--tgt",
        target_lang,
        "--providers-file",
        str(providers_file),
        "--translation-chunk-lines",
        str(case.chunk_lines),
        "--translation-context-before-lines",
        "40",
        "--translation-context-after-lines",
        "20",
        "--translation-batching-mode",
        "fixed",
        "--translation-chunking-mode",
        "fixed",
        "--translation-experiment-logging-enabled",
        "true",
        "--translation-experiment-label",
        case.case_id,
        "--json",
    ]
    cmd.extend(_memory_cli_args(case))
    started = time.perf_counter()
    completed = subprocess.run(cmd, cwd=root, text=True, encoding="utf-8", capture_output=True, timeout=timeout)
    elapsed_ms_wall = int(round((time.perf_counter() - started) * 1000))
    (output_dir / "logs").mkdir(parents=True, exist_ok=True)
    (output_dir / "logs" / f"{case.case_id}.stdout.txt").write_text(completed.stdout, encoding="utf-8")
    (output_dir / "logs" / f"{case.case_id}.stderr.txt").write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise RuntimeError(f"Experiment case failed: {case.case_id}\n{completed.stderr}\n{completed.stdout}")
    payload = json.loads(completed.stdout)
    task_id = str(payload["task"]["task_id"] if "task" in payload else payload["task_id"])
    artifact_dir = _copy_experiment_output(root, task_id, output_dir, case)
    return _case_summary(case, task_id, artifact_dir, elapsed_ms_wall)


def _parse_strings(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def _parse_chunk_specs(raw: str, sample_lines: int) -> list[tuple[str, int]]:
    specs: list[tuple[str, int]] = []
    for item in _parse_strings(raw):
        normalized = item.lower()
        if normalized in {"all", "whole"}:
            label = "all"
            chunk_lines = sample_lines
        else:
            chunk_lines = int(item)
            if chunk_lines <= 0:
                raise ValueError("chunk lines must be greater than zero")
            label = str(chunk_lines)
        candidate = (label, chunk_lines)
        if candidate not in specs:
            specs.append(candidate)
    if not specs:
        raise ValueError("at least one chunk size is required")
    return specs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run translation reasoning x chunk-size experiments.")
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--sample", required=True, help="Segment JSONL sample")
    parser.add_argument("--output-dir", default="artifacts/experiments/translation_reasoning_chunking")
    parser.add_argument("--base-provider", default="zven_openai_responses")
    parser.add_argument("--model", default="", help="Model override; defaults to the provider's first model")
    parser.add_argument("--src", default="ja", help="Source language")
    parser.add_argument("--tgt", default="zh-CN", help="Target language")
    parser.add_argument("--reasoning", default="none,low,medium,high")
    parser.add_argument(
        "--chunk-lines",
        default="20,60,120",
        help="Comma-separated positive line counts; use 'all' for one whole-sample request",
    )
    parser.add_argument("--repeats", type=int, default=1, help="Repeat every matrix cell N times")
    parser.add_argument(
        "--omit-temperature",
        action="store_true",
        help="Mark the generated single-model provider as not supporting temperature",
    )
    parser.add_argument(
        "--omit-output-token-limit",
        action="store_true",
        help="Keep model budgets for planning but omit the provider output-token request field",
    )
    parser.add_argument(
        "--memory-preset",
        default="",
        help="Comma-separated preset ids; enables injection while disabling bootstrap and patching",
    )
    parser.add_argument(
        "--memory-intensity",
        default="auto",
        choices=["low", "auto", "high", "max"],
    )
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument("--provider-timeout-seconds", type=int, default=900)
    parser.add_argument("--provider-read-timeout-seconds", type=int, default=900)
    parser.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Resume from existing summary.json and skip completed cases.",
    )
    parser.add_argument("--limit", type=int, default=0, help="Run only the first N cases for pilot checks")
    args = parser.parse_args(argv)

    root = _repo_root_from_arg(args.root)
    sample_path = Path(args.sample)
    sample = sample_path.resolve() if sample_path.is_absolute() else (root / sample_path).resolve()
    if not sample.exists():
        raise FileNotFoundError(f"Sample not found: {sample}")
    sample_lines = len(read_jsonl(sample))
    if sample_lines <= 0:
        raise ValueError(f"Sample is empty: {sample}")
    if args.repeats <= 0:
        raise ValueError("repeats must be greater than zero")
    output_dir = (root / args.output_dir).resolve() if not Path(args.output_dir).is_absolute() else Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    provider_payload = _load_yaml(root / "providers.yaml")
    base_provider = next(
        (
            item
            for item in provider_payload.get("providers") or []
            if isinstance(item, dict) and item.get("name") == args.base_provider
        ),
        None,
    )
    if base_provider is None:
        raise RuntimeError(f"Provider not found in providers.yaml: {args.base_provider}")
    model = str(args.model or "").strip()
    if not model:
        model = str((base_provider.get("models") or [""])[0]).strip()
    if not model:
        raise ValueError(f"Provider has no default model: {args.base_provider}")
    chunk_specs = _parse_chunk_specs(args.chunk_lines, sample_lines)
    memory_presets = tuple(_parse_strings(args.memory_preset))
    cases = [
        ExperimentCase(
            case_id=(
                f"{reasoning}_chunk{chunk_spec}"
                if args.repeats == 1
                else f"{reasoning}_chunk{chunk_spec}_r{repeat:02d}"
            ),
            reasoning=reasoning,
            chunk_lines=chunk_lines,
            chunk_spec=chunk_spec,
            model=model,
            repeat=repeat,
            omit_temperature=bool(args.omit_temperature),
            omit_output_token_limit=bool(args.omit_output_token_limit),
            memory_presets=memory_presets,
            memory_intensity=args.memory_intensity if memory_presets else "",
        )
        for reasoning in _parse_strings(args.reasoning)
        for chunk_spec, chunk_lines in chunk_specs
        for repeat in range(1, args.repeats + 1)
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
            "sample_lines": sample_lines,
            "base_provider": args.base_provider,
            "model": model,
            "source_lang": args.src,
            "target_lang": args.tgt,
            "repeats": args.repeats,
            "omit_temperature": bool(args.omit_temperature),
            "omit_output_token_limit": bool(args.omit_output_token_limit),
            "memory_presets": list(memory_presets),
            "memory_intensity": args.memory_intensity if memory_presets else "",
            "resume": bool(args.resume),
            "provider_timeout_seconds": int(args.provider_timeout_seconds),
            "provider_read_timeout_seconds": int(args.provider_read_timeout_seconds),
            "cases": [case.__dict__ for case in cases],
        },
    )
    summaries = list(existing_runs)
    for case in cases:
        if args.resume and case.case_id in completed_case_ids:
            continue
        summaries.append(
            _run_case(
                root,
                sample,
                output_dir,
                args.base_provider,
                case,
                args.timeout_seconds,
                args.provider_timeout_seconds,
                args.provider_read_timeout_seconds,
                args.src,
                args.tgt,
            )
        )
        completed_case_ids.add(case.case_id)
        _write_summary(output_dir, summaries)
    if args.resume and existing_runs and len(summaries) == len(existing_runs):
        _write_summary(output_dir, summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
