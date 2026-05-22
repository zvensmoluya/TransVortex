#!/usr/bin/env python3
"""Small streamed image-generation helper for local design assets.

This is intentionally repo-local: it keeps image endpoint settings separate from
the application's provider credentials and avoids patching Codex system skills.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Iterable


DEFAULT_MODEL = "gpt-image-2"
DEFAULT_SIZE = "auto"
DEFAULT_QUALITY = "medium"
DEFAULT_OUTPUT_FORMAT = "png"
DEFAULT_OUTPUT_PATH = "output/imagegen/output.png"
ENV_FILES = (".agentonlyenv", ".imagegen.env", ".env.imagegen")


def die(message: str, code: int = 1) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(code)


def warn(message: str) -> None:
    print(f"Warning: {message}", file=sys.stderr)


def import_openai():
    try:
        from openai import OpenAI
    except ImportError as exc:
        die('Missing dependency: install with `pip install -e ".[imagegen]"`.')
        raise exc
    return OpenAI


def find_env_file(start: Path) -> Path | None:
    directory = start.resolve()
    if directory.is_file():
        directory = directory.parent

    while True:
        for name in ENV_FILES:
            candidate = directory / name
            if candidate.exists():
                return candidate
        if directory.parent == directory:
            return None
        directory = directory.parent


def parse_dotenv(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}

    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        values[key] = value
    return values


def normalize_base_url(value: str | None) -> str | None:
    if not value:
        return None
    trimmed = value.strip().rstrip("/")
    if trimmed.endswith("/v1"):
        return trimmed
    return f"{trimmed}/v1"


def resolve_imagegen_config() -> tuple[str, str | None, Path | None]:
    env_file = find_env_file(Path.cwd())
    file_values = parse_dotenv(env_file)

    api_key = os.getenv("IMAGEGEN_OPENAI_API_KEY") or file_values.get(
        "IMAGEGEN_OPENAI_API_KEY"
    )
    base_url = os.getenv("IMAGEGEN_OPENAI_BASE_URL") or file_values.get(
        "IMAGEGEN_OPENAI_BASE_URL"
    )

    if not api_key:
        die("No image API key found. Set IMAGEGEN_OPENAI_API_KEY or add .imagegen.env.")

    return api_key, normalize_base_url(base_url), env_file


def read_prompt(args: argparse.Namespace) -> str:
    if args.prompt and args.prompt_file:
        die("Use --prompt or --prompt-file, not both.")
    if args.prompt_file:
        path = Path(args.prompt_file)
        if not path.exists():
            die(f"Prompt file not found: {path}")
        prompt = path.read_text(encoding="utf-8").strip()
    elif args.prompt:
        prompt = args.prompt.strip()
    else:
        die("Missing prompt. Use --prompt or --prompt-file.")

    if not prompt:
        die("Prompt is empty.")
    return prompt


def normalize_output_format(fmt: str | None) -> str:
    if not fmt:
        return DEFAULT_OUTPUT_FORMAT
    value = fmt.lower()
    if value == "jpg":
        value = "jpeg"
    if value not in {"png", "jpeg", "webp"}:
        die("--output-format must be png, jpeg, jpg, or webp.")
    return value


def slugify(value: str, fallback: str = "image") -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", value.strip().lower()).strip("-")
    return (slug or fallback)[:80]


def with_format_suffix(path: Path, output_format: str) -> Path:
    suffix = ".jpg" if output_format == "jpeg" else f".{output_format}"
    if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
        return path.with_suffix(suffix)
    return path.with_suffix(suffix)


def build_output_paths(
    *,
    out: str,
    out_dir: str | None,
    output_format: str,
    n: int,
    prompt: str,
    index: int | None = None,
) -> list[Path]:
    if out_dir:
        base = Path(out_dir)
        prefix = f"{index:03d}-" if index is not None else ""
        stem = prefix + slugify(prompt)
        paths = [base / f"{stem}.{output_format}"]
    else:
        paths = [with_format_suffix(Path(out), output_format)]

    if n == 1:
        return paths

    base_path = paths[0]
    suffix = base_path.suffix
    return [
        base_path.with_name(f"{base_path.stem}-{i + 1:02d}{suffix}") for i in range(n)
    ]


def write_images(images: Iterable[str], paths: list[Path], *, force: bool) -> None:
    encoded_images = list(images)
    if len(encoded_images) != len(paths):
        die(f"Expected {len(paths)} image(s), got {len(encoded_images)}.")

    for b64_json, path in zip(encoded_images, paths):
        if path.exists() and not force:
            die(f"Refusing to overwrite existing file: {path}. Use --force.")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(b64_json))
        print(f"Wrote {path}", file=sys.stderr)


def common_payload(args: argparse.Namespace, prompt: str) -> dict[str, Any]:
    payload = {
        "model": args.model,
        "prompt": prompt,
        "n": args.n,
        "size": args.size,
        "quality": args.quality,
        "background": args.background,
        "output_format": args.output_format,
        "output_compression": args.output_compression,
        "moderation": args.moderation,
    }
    return {key: value for key, value in payload.items() if value is not None}


def event_type(event: Any) -> str:
    if hasattr(event, "type"):
        return str(event.type)
    if isinstance(event, dict):
        return str(event.get("type", ""))
    return ""


def event_value(event: Any, name: str, default: Any = None) -> Any:
    if isinstance(event, dict):
        return event.get(name, default)
    return getattr(event, name, default)


def consume_stream(stream: Iterable[Any], *, label: str) -> list[str]:
    images: list[str] = []
    for event in stream:
        kind = event_type(event)
        if kind.endswith(".partial_image"):
            partial_index = event_value(event, "partial_image_index", "?")
            print(f"{label} partial image {partial_index} received", file=sys.stderr, flush=True)
        elif kind.endswith(".completed"):
            image = event_value(event, "b64_json")
            if image:
                images.append(image)
            usage = event_value(event, "usage")
            usage_text = ""
            if usage is not None:
                total_tokens = event_value(usage, "total_tokens")
                if total_tokens is not None:
                    usage_text = f", total_tokens={total_tokens}"
            print(f"{label} completed{usage_text}", file=sys.stderr, flush=True)
        elif kind:
            print(f"{label} event {kind}", file=sys.stderr, flush=True)
    return images


def create_client(api_key: str, base_url: str | None):
    OpenAI = import_openai()
    kwargs: dict[str, Any] = {"api_key": api_key}
    if base_url:
        kwargs["base_url"] = base_url
    return OpenAI(**kwargs)


def print_dry_run(payload: dict[str, Any], outputs: list[Path], env_file: Path | None) -> None:
    preview = {
        "env_file": str(env_file) if env_file else None,
        "outputs": [str(path) for path in outputs],
        **payload,
    }
    print(json.dumps(preview, ensure_ascii=False, indent=2))


def run_generate(args: argparse.Namespace) -> None:
    prompt = read_prompt(args)
    output_format = normalize_output_format(args.output_format)
    args.output_format = output_format
    outputs = build_output_paths(
        out=args.out,
        out_dir=args.out_dir,
        output_format=output_format,
        n=args.n,
        prompt=prompt,
    )
    payload = common_payload(args, prompt)

    if args.dry_run:
        env_file = find_env_file(Path.cwd())
        print_dry_run(payload, outputs, env_file)
        return

    api_key, base_url, _env_file = resolve_imagegen_config()
    client = create_client(api_key, base_url)
    started = time.time()
    if args.stream:
        request = dict(payload, stream=True, partial_images=args.partial_images)
        print("Calling Image API (streaming generation).", file=sys.stderr)
        images = consume_stream(client.images.generate(**request), label="[image]")
    else:
        print("Calling Image API (generation).", file=sys.stderr)
        result = client.images.generate(**payload)
        images = [item.b64_json for item in result.data]
    print(f"Generation completed in {time.time() - started:.1f}s.", file=sys.stderr)
    write_images(images, outputs, force=args.force)


def open_files(paths: list[Path]) -> list[Any]:
    for path in paths:
        if not path.exists():
            die(f"Image file not found: {path}")
    return [path.open("rb") for path in paths]


def close_files(handles: Iterable[Any]) -> None:
    for handle in handles:
        try:
            handle.close()
        except Exception:
            pass


def run_edit(args: argparse.Namespace) -> None:
    prompt = read_prompt(args)
    output_format = normalize_output_format(args.output_format)
    args.output_format = output_format
    image_paths = [Path(raw) for raw in args.image]
    outputs = build_output_paths(
        out=args.out,
        out_dir=args.out_dir,
        output_format=output_format,
        n=args.n,
        prompt=prompt,
    )
    payload = common_payload(args, prompt)
    if args.input_fidelity:
        payload["input_fidelity"] = args.input_fidelity

    mask_path = Path(args.mask) if args.mask else None
    if mask_path and not mask_path.exists():
        die(f"Mask file not found: {mask_path}")

    if args.dry_run:
        env_file = find_env_file(Path.cwd())
        preview = dict(payload)
        preview["image"] = [str(path) for path in image_paths]
        if mask_path:
            preview["mask"] = str(mask_path)
        print_dry_run(preview, outputs, env_file)
        return

    api_key, base_url, _env_file = resolve_imagegen_config()
    client = create_client(api_key, base_url)
    handles = open_files(image_paths)
    mask_handle = None
    try:
        request = dict(payload)
        request["image"] = handles if len(handles) > 1 else handles[0]
        if mask_path:
            mask_handle = mask_path.open("rb")
            request["mask"] = mask_handle
        started = time.time()
        if args.stream:
            request["stream"] = True
            request["partial_images"] = args.partial_images
            print("Calling Image API (streaming edit).", file=sys.stderr)
            images = consume_stream(client.images.edit(**request), label="[edit]")
        else:
            print("Calling Image API (edit).", file=sys.stderr)
            result = client.images.edit(**request)
            images = [item.b64_json for item in result.data]
        print(f"Edit completed in {time.time() - started:.1f}s.", file=sys.stderr)
        write_images(images, outputs, force=args.force)
    finally:
        close_files(handles)
        if mask_handle:
            mask_handle.close()


def read_jobs_jsonl(path: str) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    input_path = Path(path)
    if not input_path.exists():
        die(f"Batch input not found: {input_path}")
    for line_no, raw in enumerate(input_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            job = json.loads(line)
        except json.JSONDecodeError as exc:
            die(f"Invalid JSONL at line {line_no}: {exc}")
        if "prompt" not in job:
            die(f"Batch job line {line_no} is missing prompt.")
        jobs.append(job)
    if not jobs:
        die("Batch input is empty.")
    return jobs


def run_generate_batch(args: argparse.Namespace) -> None:
    jobs = read_jobs_jsonl(args.input)
    failures = 0
    for index, job in enumerate(jobs, start=1):
        prompt = str(job["prompt"]).strip()
        merged = argparse.Namespace(**vars(args))
        merged.prompt = prompt
        merged.prompt_file = None
        for key in (
            "model",
            "n",
            "size",
            "quality",
            "background",
            "output_format",
            "output_compression",
            "moderation",
            "partial_images",
            "stream",
            "out",
            "out_dir",
        ):
            if key in job:
                setattr(merged, key, job[key])
        if not getattr(merged, "out", None):
            merged.out = DEFAULT_OUTPUT_PATH
        if job.get("out"):
            merged.out = str(job["out"])
            merged.out_dir = None
        elif args.out_dir:
            output_format = normalize_output_format(getattr(merged, "output_format", None))
            merged.out = str(Path(args.out_dir) / f"{index:03d}-{slugify(prompt)}.{output_format}")
            merged.out_dir = None
        else:
            output_format = normalize_output_format(getattr(merged, "output_format", None))
            merged.out = str(
                Path(DEFAULT_OUTPUT_PATH).parent
                / f"{index:03d}-{slugify(prompt)}.{output_format}"
            )
            merged.out_dir = None

        try:
            print(f"[job {index}/{len(jobs)}] starting", file=sys.stderr)
            run_generate(merged)
        except Exception as exc:
            failures += 1
            print(f"[job {index}/{len(jobs)}] failed: {exc}", file=sys.stderr)
            if args.fail_fast:
                raise
    if failures:
        raise SystemExit(1)


def validate_args(args: argparse.Namespace) -> None:
    if args.n < 1 or args.n > 10:
        die("--n must be between 1 and 10.")
    if args.partial_images < 0 or args.partial_images > 3:
        die("--partial-images must be between 0 and 3.")
    if args.output_compression is not None and not (0 <= args.output_compression <= 100):
        die("--output-compression must be between 0 and 100.")


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--prompt")
    parser.add_argument("--prompt-file")
    parser.add_argument("--n", type=int, default=1)
    parser.add_argument("--size", default=DEFAULT_SIZE)
    parser.add_argument("--quality", default=DEFAULT_QUALITY)
    parser.add_argument("--background")
    parser.add_argument("--output-format", default=DEFAULT_OUTPUT_FORMAT)
    parser.add_argument("--output-compression", type=int)
    parser.add_argument("--moderation")
    parser.add_argument("--stream", dest="stream", action="store_true")
    parser.add_argument("--no-stream", dest="stream", action="store_false")
    parser.add_argument("--partial-images", type=int, default=1)
    parser.add_argument("--out", default=DEFAULT_OUTPUT_PATH)
    parser.add_argument("--out-dir")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.set_defaults(stream=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Streamed image generation helper for local TransVortex design assets."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate = subparsers.add_parser("generate", help="Create a new image")
    add_common_args(generate)
    generate.set_defaults(func=run_generate)

    edit = subparsers.add_parser("edit", help="Edit image input(s)")
    add_common_args(edit)
    edit.add_argument("--image", action="append", required=True)
    edit.add_argument("--mask")
    edit.add_argument("--input-fidelity")
    edit.set_defaults(func=run_edit)

    batch = subparsers.add_parser("generate-batch", help="Generate prompts from JSONL")
    add_common_args(batch)
    batch.add_argument("--input", required=True)
    batch.add_argument("--fail-fast", action="store_true")
    batch.set_defaults(func=run_generate_batch)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    validate_args(args)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
