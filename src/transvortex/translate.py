from __future__ import annotations

import concurrent.futures
import re
import time

from .models import AppConfig, Chunk
from .providers import build_provider_client


def _strip_numbered_text(line: str) -> tuple[int, str]:
    m = re.match(r"^\[(\d+)\]\s*(.*)$", line.strip())
    if not m:
        raise RuntimeError(f"Bad translated line format: {line}")
    return int(m.group(1)), m.group(2)


def translate_chunk(
    config: AppConfig,
    chunk: Chunk,
    source_lang: str,
    target_lang: str,
) -> dict:
    route_candidates = [config.routing.primary] + list(config.routing.fallback)
    error_messages: list[str] = []
    for route in route_candidates:
        provider = config.providers.get(route.provider)
        if not provider:
            error_messages.append(f"provider not found: {route.provider}")
            continue
        client = build_provider_client(provider)
        retries = max(1, provider.limits.retry)
        for attempt in range(retries):
            try:
                translated_lines = client.translate_batch(
                    chunk.lines,
                    source_lang=source_lang,
                    target_lang=target_lang,
                    model=route.model,
                )
                rows = []
                for line in translated_lines:
                    seg_id, text = _strip_numbered_text(line)
                    rows.append({"id": seg_id, "text_tgt": text})
                expected_ids = sorted(chunk.segment_ids)
                got_ids = sorted(r["id"] for r in rows)
                if expected_ids != got_ids:
                    raise RuntimeError("translated ids mismatch")
                return {
                    "chunk_id": chunk.chunk_id,
                    "provider": route.provider,
                    "model": route.model,
                    "rows": rows,
                }
            except Exception as exc:  # pragma: no cover - runtime network branches
                error_messages.append(
                    f"{route.provider}/{route.model} attempt={attempt + 1}: {exc}"
                )
                if attempt + 1 < retries:
                    time.sleep(min(2**attempt, 5))
    raise RuntimeError("All translation routes failed: " + " | ".join(error_messages))


def translate_all_chunks(
    config: AppConfig,
    chunks: list[Chunk],
    source_lang: str,
    target_lang: str,
    already_done: set[str] | None = None,
) -> list[dict]:
    already_done = already_done or set()
    todo = [chunk for chunk in chunks if chunk.chunk_id not in already_done]
    if not todo:
        return []
    max_workers = max(1, config.pipeline.default_concurrency)
    out: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            pool.submit(translate_chunk, config, chunk, source_lang, target_lang): chunk
            for chunk in todo
        }
        for future in concurrent.futures.as_completed(futures):
            out.append(future.result())
    return out
