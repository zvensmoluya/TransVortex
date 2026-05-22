from __future__ import annotations

import argparse
import copy
import csv
import json
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from ..app.config import load_app_config
from ..app.models import Segment
from ..core.chunking import estimate_text_tokens
from ..memory.bootstrap_input import build_bootstrap_input_view, render_bootstrap_input_text
from ..memory.bootstrapper import bootstrap_memory
from ..memory.store import MemoryStore
from ..utils import read_json, read_jsonl, utc_now_iso, write_json


@dataclass(frozen=True)
class BootstrapCase:
    case_id: str
    reasoning: str


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


def _request_mapping(provider: dict[str, Any]) -> dict[str, Any]:
    mapping = provider.get("request_mapping")
    return mapping if isinstance(mapping, dict) else {}


def _body_overrides(provider: dict[str, Any]) -> dict[str, Any]:
    mapping = _request_mapping(provider)
    body_overrides = mapping.get("body_overrides")
    return body_overrides if isinstance(body_overrides, dict) else {}


def _with_body_overrides(provider: dict[str, Any], body_overrides: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(provider)
    mapping = dict(_request_mapping(out))
    mapping["body_overrides"] = body_overrides
    out["request_mapping"] = mapping
    return out


def _primary_model(provider: dict[str, Any]) -> str:
    models = provider.get("models")
    if isinstance(models, list) and models:
        return str(models[0])
    return ""


def _is_gemini_generate_content_provider(provider: dict[str, Any]) -> bool:
    mapping = _request_mapping(provider)
    return (
        provider.get("api_type") == "gemini-compatible"
        or provider.get("compat_mode") in {"gemini_generate_content", "vertex_express", "vertex_native"}
        or mapping.get("style") == "gemini_generate_content"
    )


def _is_gemini_3_or_later_model(model: str) -> bool:
    match = re.search(r"gemini[-_/](\d+)", model)
    return bool(match and int(match.group(1)) >= 3)


def _normalized_thinking(value: str) -> str:
    return value.strip().lower().replace("_", "-")


def _gemini_25_budget(value: str) -> int:
    normalized = _normalized_thinking(value)
    if normalized == "auto":
        return -1
    if normalized.startswith("budget:"):
        normalized = normalized.partition(":")[2].strip()
    if re.fullmatch(r"-?\d+", normalized):
        return int(normalized)
    budgets = {
        "minimal": 0,
        "off": 0,
        "low": 1024,
        "medium": 8192,
        "high": 24576,
    }
    if normalized not in budgets:
        raise RuntimeError(f"Unsupported Gemini thinking budget value: {value}")
    return budgets[normalized]


def _provider_without_reasoning(provider: dict[str, Any]) -> dict[str, Any]:
    body_overrides = copy.deepcopy(_body_overrides(provider))
    body_overrides.pop("reasoning", None)
    body_overrides.pop("reasoning_effort", None)

    generation_config = body_overrides.get("generationConfig")
    if isinstance(generation_config, dict):
        generation_config = dict(generation_config)
        generation_config.pop("thinkingConfig", None)
        if generation_config:
            body_overrides["generationConfig"] = generation_config
        else:
            body_overrides.pop("generationConfig", None)
    body_overrides.pop("thinkingConfig", None)

    return _with_body_overrides(provider, body_overrides)


def _provider_with_gemini_thinking(provider: dict[str, Any], thinking: str) -> dict[str, Any]:
    normalized = _normalized_thinking(thinking)
    if normalized in {"none", "default"}:
        return _provider_without_reasoning(provider)

    out = _provider_without_reasoning(provider)
    body_overrides = copy.deepcopy(_body_overrides(out))
    generation_config = dict(body_overrides.get("generationConfig") or {})
    thinking_config = dict(generation_config.get("thinkingConfig") or {})

    if _is_gemini_3_or_later_model(_primary_model(out)):
        level = normalized.upper()
        if level not in {"MINIMAL", "LOW", "MEDIUM", "HIGH"}:
            raise RuntimeError(f"Unsupported Gemini thinking level for Gemini 3+: {thinking}")
        thinking_config.pop("thinkingBudget", None)
        thinking_config["thinkingLevel"] = level
    else:
        thinking_config.pop("thinkingLevel", None)
        thinking_config["thinkingBudget"] = _gemini_25_budget(normalized)

    generation_config["thinkingConfig"] = thinking_config
    body_overrides["generationConfig"] = generation_config
    return _with_body_overrides(out, body_overrides)


def _provider_with_reasoning(provider: dict[str, Any], effort: str) -> dict[str, Any]:
    if effort == "none":
        return _provider_without_reasoning(provider)
    if _is_gemini_generate_content_provider(provider):
        return _provider_with_gemini_thinking(provider, effort)
    body_overrides = copy.deepcopy(_body_overrides(provider))
    body_overrides["reasoning"] = {"effort": effort}
    return _with_body_overrides(provider, body_overrides)


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
    case: BootstrapCase,
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
    provider["name"] = f"{base_provider}_bootstrap_{case.case_id}"
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


def _load_segments(path: Path) -> list[Segment]:
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


def _usage_value(usage: dict[str, Any], *keys: str) -> int | str:
    for key in keys:
        value = usage.get(key)
        if isinstance(value, int):
            return value
    return ""


def _case_summary(case: BootstrapCase, case_dir: Path, elapsed_ms_wall: int) -> dict[str, Any]:
    bootstrap_path = case_dir / "memory" / "bootstrap.json"
    payload = read_json(bootstrap_path) if bootstrap_path.exists() else {}
    memory_doc = MemoryStore(case_dir / "memory").load_runtime()
    provider_meta = payload.get("provider_meta") if isinstance(payload.get("provider_meta"), dict) else {}
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    actions = payload.get("actions") if isinstance(payload.get("actions"), list) else []
    errors = payload.get("errors") if isinstance(payload.get("errors"), list) else []
    return {
        "case_id": case.case_id,
        "reasoning": case.reasoning,
        "status": payload.get("status", ""),
        "actions": len(actions),
        "memory_entries": len(memory_doc.entries),
        "conflicts": int(payload.get("conflicts") or 0),
        "raw_text_chars": len(str(payload.get("raw_text") or "")),
        "elapsed_ms_wall": elapsed_ms_wall,
        "provider_elapsed_ms": int(provider_meta.get("elapsed_ms") or 0),
        "first_byte_ms": _first_byte_ms(provider_meta),
        "input_tokens": _usage_value(usage, "input_tokens", "prompt_tokens"),
        "output_tokens": _usage_value(usage, "output_tokens", "completion_tokens"),
        "total_tokens": _usage_value(usage, "total_tokens"),
        "errors": len(errors),
        "artifact_dir": str(case_dir),
    }


def _first_byte_ms(provider_meta: dict[str, Any]) -> int:
    started = provider_meta.get("request_started_at")
    first = provider_meta.get("first_byte_at")
    if isinstance(started, (int, float)) and isinstance(first, (int, float)):
        return max(0, int(round((first - started) * 1000)))
    return 0


def _write_summary(output_dir: Path, summaries: list[dict[str, Any]]) -> None:
    write_json(output_dir / "summary.json", {"created_at": utc_now_iso(), "runs": summaries})
    csv_path = output_dir / "summary.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "case_id",
        "reasoning",
        "status",
        "actions",
        "memory_entries",
        "conflicts",
        "raw_text_chars",
        "elapsed_ms_wall",
        "provider_elapsed_ms",
        "first_byte_ms",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "errors",
        "artifact_dir",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows({key: item.get(key, "") for key in fieldnames} for item in summaries)


def _copy_case_inputs(case_dir: Path, providers_file: Path, sample: Path) -> None:
    (case_dir / "inputs").mkdir(parents=True, exist_ok=True)
    shutil.copy2(providers_file, case_dir / "inputs" / providers_file.name)
    shutil.copy2(sample, case_dir / "inputs" / sample.name)


def _run_case(
    *,
    root: Path,
    sample: Path,
    segments: list[Segment],
    output_dir: Path,
    base_provider: str,
    case: BootstrapCase,
    timeout_seconds: int,
    read_timeout_seconds: int,
    max_candidates: int,
) -> dict[str, Any]:
    providers_file = _build_case_providers(root, base_provider, case, output_dir, timeout_seconds, read_timeout_seconds)
    config = load_app_config(root_dir=root, providers_file=providers_file)
    config.pipeline.memory.enabled = True
    config.pipeline.memory.bootstrap.enabled = True
    config.pipeline.memory.bootstrap.mode = "whole_document"
    config.pipeline.memory.bootstrap.max_candidates = max(1, int(max_candidates))
    case_dir = output_dir / "runs" / case.case_id
    if case_dir.exists():
        shutil.rmtree(case_dir)
    memory_dir = case_dir / "memory"
    _copy_case_inputs(case_dir, providers_file, sample)
    started = time.perf_counter()
    bootstrap_memory(
        config,
        segments,
        source_lang="ja",
        target_lang="zh-CN",
        memory_dir=memory_dir,
    )
    elapsed_ms_wall = int(round((time.perf_counter() - started) * 1000))
    return _case_summary(case, case_dir, elapsed_ms_wall)


def _parse_strings(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def _write_input_overview(output_dir: Path, segments: list[Segment]) -> None:
    view = build_bootstrap_input_view(segments)
    rendered = render_bootstrap_input_text(view)
    write_json(
        output_dir / "input_overview.json",
        {
            "segments": len(segments),
            "bootstrap_input_chars": len(rendered),
            "estimated_bootstrap_input_tokens": estimate_text_tokens(rendered),
            "flags": view.stats.get("flag_counts", {}),
        },
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run memory bootstrap-only reasoning experiments.")
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--sample", required=True, help="Segment JSONL sample")
    parser.add_argument("--output-dir", default="artifacts/experiments/memory_bootstrap_only")
    parser.add_argument("--base-provider", default="zven_openai_responses")
    parser.add_argument("--reasoning", default="none,medium,high")
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--provider-read-timeout-seconds", type=int, default=900)
    parser.add_argument("--max-candidates", type=int, default=120)
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
    output_dir.mkdir(parents=True, exist_ok=True)
    segments = _load_segments(sample)
    cases = [BootstrapCase(case_id=f"{reasoning}_bootstrap", reasoning=reasoning) for reasoning in _parse_strings(args.reasoning)]
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
            "max_candidates": int(args.max_candidates),
            "resume": bool(args.resume),
            "provider_timeout_seconds": int(args.timeout_seconds),
            "provider_read_timeout_seconds": int(args.provider_read_timeout_seconds),
            "cases": [case.__dict__ for case in cases],
        },
    )
    _write_input_overview(output_dir, segments)
    summaries: list[dict[str, Any]] = list(existing_runs)
    for case in cases:
        if args.resume and case.case_id in completed_case_ids:
            continue
        summaries.append(
            _run_case(
                root=root,
                sample=sample,
                segments=segments,
                output_dir=output_dir,
                base_provider=args.base_provider,
                case=case,
                timeout_seconds=args.timeout_seconds,
                read_timeout_seconds=args.provider_read_timeout_seconds,
                max_candidates=args.max_candidates,
            )
        )
        completed_case_ids.add(case.case_id)
        _write_summary(output_dir, summaries)
    if args.resume and existing_runs and len(summaries) == len(existing_runs):
        _write_summary(output_dir, summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
