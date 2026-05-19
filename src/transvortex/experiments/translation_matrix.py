from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
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
    provider["name"] = f"{base_provider}_{case.case_id}"
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
    return totals


def _case_summary(case: ExperimentCase, task_id: str, artifact_dir: Path) -> dict[str, Any]:
    metrics = read_jsonl(artifact_dir / "translate" / "metrics.jsonl")
    elapsed_ms = sum(
        int((row.get("provider_meta") or {}).get("elapsed_ms") or 0)
        for row in metrics
        if isinstance(row, dict)
    )
    raw_chars = sum(int(row.get("raw_text_chars") or 0) for row in metrics if isinstance(row, dict))
    line_count = sum(int(row.get("line_count") or 0) for row in metrics if isinstance(row, dict))
    issue_count = sum(
        int((row.get("validation") or {}).get("issue_count") or 0)
        for row in metrics
        if isinstance(row, dict)
    )
    summary = {
        "case_id": case.case_id,
        "task_id": task_id,
        "reasoning": case.reasoning,
        "chunk_lines": case.chunk_lines,
        "chunks": len(metrics),
        "lines": line_count,
        "elapsed_ms_sum": elapsed_ms,
        "raw_text_chars": raw_chars,
        "validation_issues": issue_count,
        "usage": _sum_usage(metrics),
        "artifact_dir": str(artifact_dir),
    }
    return summary


def _write_summary(output_dir: Path, summaries: list[dict[str, Any]]) -> None:
    write_json(output_dir / "summary.json", {"created_at": utc_now_iso(), "runs": summaries})
    rows = []
    for item in summaries:
        usage = item.get("usage") if isinstance(item.get("usage"), dict) else {}
        rows.append(
            {
                "case_id": item.get("case_id", ""),
                "reasoning": item.get("reasoning", ""),
                "chunk_lines": item.get("chunk_lines", ""),
                "chunks": item.get("chunks", ""),
                "lines": item.get("lines", ""),
                "elapsed_ms_sum": item.get("elapsed_ms_sum", ""),
                "raw_text_chars": item.get("raw_text_chars", ""),
                "validation_issues": item.get("validation_issues", ""),
                "input_tokens": usage.get("input_tokens", usage.get("prompt_tokens", "")),
                "output_tokens": usage.get("output_tokens", usage.get("completion_tokens", "")),
                "total_tokens": usage.get("total_tokens", ""),
                "artifact_dir": item.get("artifact_dir", ""),
            }
        )
    csv_path = output_dir / "summary.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()) if rows else [])
        if rows:
            writer.writeheader()
            writer.writerows(rows)


def _run_case(
    root: Path,
    sample: Path,
    output_dir: Path,
    base_provider: str,
    case: ExperimentCase,
    timeout: int,
    provider_timeout_seconds: int,
    provider_read_timeout_seconds: int,
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
        "ja",
        "--tgt",
        "zh-CN",
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
        "--memory-enabled",
        "false",
        "--translation-experiment-logging-enabled",
        "true",
        "--translation-experiment-label",
        case.case_id,
        "--json",
    ]
    completed = subprocess.run(cmd, cwd=root, text=True, encoding="utf-8", capture_output=True, timeout=timeout)
    (output_dir / "logs").mkdir(parents=True, exist_ok=True)
    (output_dir / "logs" / f"{case.case_id}.stdout.txt").write_text(completed.stdout, encoding="utf-8")
    (output_dir / "logs" / f"{case.case_id}.stderr.txt").write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise RuntimeError(f"Experiment case failed: {case.case_id}\n{completed.stderr}\n{completed.stdout}")
    payload = json.loads(completed.stdout)
    task_id = str(payload["task"]["task_id"] if "task" in payload else payload["task_id"])
    artifact_dir = _copy_experiment_output(root, task_id, output_dir, case)
    return _case_summary(case, task_id, artifact_dir)


def _parse_ints(raw: str) -> list[int]:
    return [int(item.strip()) for item in raw.split(",") if item.strip()]


def _parse_strings(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run translation reasoning x chunk-size experiments.")
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--sample", required=True, help="Segment JSONL sample")
    parser.add_argument("--output-dir", default="artifacts/experiments/translation_reasoning_chunking")
    parser.add_argument("--base-provider", default="zven_openai_responses")
    parser.add_argument("--reasoning", default="none,low,medium,high")
    parser.add_argument("--chunk-lines", default="20,60,120")
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
    output_dir = (root / args.output_dir).resolve() if not Path(args.output_dir).is_absolute() else Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    cases = [
        ExperimentCase(case_id=f"{reasoning}_chunk{chunk_lines}", reasoning=reasoning, chunk_lines=chunk_lines)
        for reasoning in _parse_strings(args.reasoning)
        for chunk_lines in _parse_ints(args.chunk_lines)
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
            "base_provider": args.base_provider,
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
            )
        )
        completed_case_ids.add(case.case_id)
        _write_summary(output_dir, summaries)
    if args.resume and existing_runs and len(summaries) == len(existing_runs):
        _write_summary(output_dir, summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
