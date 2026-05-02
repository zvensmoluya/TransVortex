from __future__ import annotations

import importlib.util
import os
import shutil
from pathlib import Path
from typing import Any, Callable

from .aligner import apply_translations, dedupe_overlap_segments, normalize_timeline, validate_segments
from .asr import AsrEngine, write_segment_asr_output
from .chunking import number_and_chunk_segments
from .config import apply_route_overrides, load_app_config
from .exporter import export_srt
from .media import extract_audio, split_audio_with_overlap
from .models import AppConfig, Segment, TaskRecord
from .probe import probe_provider
from .task_store import TaskStore
from .translate import translate_all_chunks
from .utils import append_jsonl, gen_task_id, read_json, read_jsonl, to_plain, utc_now_iso, write_json


class TaskCancelled(RuntimeError):
    pass


def _parse_asr_rows(rows: list[dict], start_id: int) -> list[Segment]:
    out: list[Segment] = []
    next_id = start_id
    for row in rows:
        text = str(row.get("text", "")).strip()
        if not text:
            continue
        out.append(
            Segment(
                id=next_id,
                start=float(row["start"]),
                end=float(row["end"]),
                text_src=text,
                confidence=row.get("confidence"),
            )
        )
        next_id += 1
    return out


def _task_paths(store: TaskStore, task_id: str) -> dict[str, Path]:
    base = store.task_dir(task_id)
    return {
        "base": base,
        "media": base / "media",
        "asr": base / "asr",
        "translate": base / "translate",
        "final": base / "final",
        "output": base / "output",
        "chunks": base / "chunks",
    }


def _stage_progress(stage: str) -> float:
    return {
        "INIT": 0.0,
        "PRECHECK": 0.02,
        "INGEST": 0.08,
        "ASR": 0.25,
        "SEGMENT": 0.55,
        "TRANSLATE": 0.65,
        "ALIGN": 0.85,
        "EXPORT": 0.95,
        "DONE": 1.0,
    }.get(stage, 0.0)


def _emit_stage(store: TaskStore, task_id: str, stage: str, message: str) -> None:
    store.update_task_status(task_id, stage)
    store.append_event(task_id, "stage", stage=stage, message=message, progress=_stage_progress(stage))


def _check_cancel(store: TaskStore, task_id: str) -> None:
    if store.is_cancel_requested(task_id):
        raise TaskCancelled("Task cancelled")


def _ensure_artifact_dirs(paths: dict[str, Path]) -> None:
    for p in paths.values():
        p.mkdir(parents=True, exist_ok=True)


def _require_file(path: Path, label: str) -> None:
    if not path.exists() or path.stat().st_size == 0:
        raise RuntimeError(f"Missing or empty artifact: {label}")


def _preflight(
    config: AppConfig,
    store: TaskStore,
    task: TaskRecord,
    output_file: Path | None,
    *,
    root_dir: Path,
    providers_file: Path | None,
) -> None:
    input_path = Path(task.input_file)
    if not input_path.exists():
        raise RuntimeError(f"Input file not found: {input_path}")
    if not input_path.is_file():
        raise RuntimeError(f"Input path is not a file: {input_path}")
    for binary in ("ffmpeg", "ffprobe"):
        if shutil.which(binary) is None:
            raise RuntimeError(f"Required executable not found in PATH: {binary}")
    output_dir = output_file.parent if output_file else store.task_dir(task.task_id) / "output"
    output_dir.mkdir(parents=True, exist_ok=True)
    probe_file = output_dir / ".tvx_write_probe"
    try:
        probe_file.write_text("ok", encoding="utf-8")
    finally:
        probe_file.unlink(missing_ok=True)
    if config.pipeline.asr_mode == "local" and importlib.util.find_spec("faster_whisper") is None:
        raise RuntimeError("faster-whisper is required for ASR. Install with: pip install -e .[asr]")
    if config.pipeline.asr_mode == "openai":
        env_key = config.pipeline.asr_cloud_env_key
        if config.pipeline.asr_provider:
            provider = config.providers.get(config.pipeline.asr_provider)
            if provider is None:
                raise RuntimeError(f"ASR provider not found: {config.pipeline.asr_provider}")
            env_key = provider.env_key
        if not os.getenv(env_key):
            raise RuntimeError(f"Missing environment variable: {env_key}")
    route = config.routing.primary
    provider = config.providers.get(route.provider)
    if not provider:
        raise RuntimeError(f"Translation provider not found: {route.provider}")
    report = probe_provider(
        root_dir=root_dir,
        providers_file=providers_file,
        provider_name=route.provider,
        model=route.model,
        source_lang=task.source_lang,
        target_lang=task.target_lang,
    )
    failures = [
        f"{row.get('name')}: {row.get('message')}"
        for row in report.get("checks", [])
        if row.get("status") == "FAIL"
    ]
    if failures:
        raise RuntimeError(f"Provider preflight failed: {'; '.join(failures)}")


def _status_json(task: TaskRecord) -> dict[str, Any]:
    return {
        "task_id": task.task_id,
        "status": task.status,
        "input_file": task.input_file,
        "source_lang": task.source_lang,
        "target_lang": task.target_lang,
        "bilingual": task.bilingual,
        "created_at": task.created_at,
        "updated_at": task.updated_at,
        "output_path": task.output_path,
        "error": None if task.status == "DONE" else task.error,
    }


def _create_task(
    store: TaskStore,
    input_file: Path,
    source_lang: str,
    target_lang: str,
    bilingual: bool,
    settings: dict,
) -> TaskRecord:
    task = TaskRecord(
        task_id=gen_task_id(),
        input_file=str(input_file),
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        status="INIT",
        created_at=utc_now_iso(),
        updated_at=utc_now_iso(),
        settings=settings,
    )
    store.save_task(task)
    return task


def _load_segments_from_raw_jsonl(raw_file: Path) -> list[Segment]:
    rows = read_jsonl(raw_file)
    segments: list[Segment] = []
    for row in rows:
        segments.append(Segment(**row))
    segments.sort(key=lambda x: x.id)
    return segments


def _persist_segments_jsonl(path: Path, segments: list[Segment]) -> None:
    path.unlink(missing_ok=True)
    for seg in segments:
        append_jsonl(path, seg)


def run_pipeline(
    *,
    root_dir: Path,
    input_file: Path,
    source_lang: str,
    target_lang: str,
    bilingual: bool = False,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    task = _create_task(
        store,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        settings=to_plain(config.pipeline),
    )
    store.clear_cancel(task.task_id)
    store.append_event(task.task_id, "task_created", stage="INIT", message="Task created", progress=0.0)
    _execute_task(
        config,
        store,
        task.task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task.task_id


def resume_pipeline(
    *,
    root_dir: Path,
    task_id: str,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
    provider_name: str | None = None,
    model: str | None = None,
    event_sink: Callable[[dict[str, Any]], None] | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    config = apply_route_overrides(config, provider_name=provider_name, model=model)
    store = TaskStore(config.pipeline.artifacts_dir, event_sink=event_sink)
    store.load_task(task_id)
    store.clear_cancel(task_id)
    store.append_event(task_id, "resume_requested", message="Resume requested")
    _execute_task(
        config,
        store,
        task_id,
        output_file=output_file,
        root_dir=root_dir,
        providers_file=providers_file,
    )
    return task_id


def _execute_task(
    config: AppConfig,
    store: TaskStore,
    task_id: str,
    output_file: Path | None = None,
    *,
    root_dir: Path,
    providers_file: Path | None = None,
) -> None:
    task = store.load_task(task_id)
    paths = _task_paths(store, task_id)
    _ensure_artifact_dirs(paths)

    checkpoint = store.load_checkpoint(task_id)
    try:
        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "PRECHECK", "Running preflight checks")
        _preflight(config, store, task, output_file, root_dir=root_dir, providers_file=providers_file)
        checkpoint["status"] = "PRECHECK"
        store.save_checkpoint(task_id, checkpoint)

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "INGEST", "Extracting and splitting audio")
        audio_full = paths["media"] / "audio_full.m4a"
        if not checkpoint.get("ingest_done"):
            media_meta = extract_audio(Path(task.input_file), audio_full)
            segments_manifest = split_audio_with_overlap(
                audio_full,
                paths["media"] / "segments",
                chunk_seconds=config.pipeline.chunk_seconds,
                overlap_seconds=config.pipeline.chunk_overlap_seconds,
                duration_seconds=float(media_meta["duration_seconds"]),
            )
            write_json(paths["media"] / "media_meta.json", media_meta)
            write_json(paths["media"] / "segments_manifest.json", segments_manifest)
            _require_file(audio_full, "media/audio_full.m4a")
            checkpoint["ingest_done"] = True
            checkpoint["status"] = "INGEST"
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "artifact",
                stage="INGEST",
                message="Audio segments ready",
                progress=0.18,
                details={"path": str(paths["media"] / "segments_manifest.json"), "segments": len(segments_manifest)},
            )
        else:
            _require_file(audio_full, "media/audio_full.m4a")
            _require_file(paths["media"] / "segments_manifest.json", "media/segments_manifest.json")
            segments_manifest = read_json(paths["media"] / "segments_manifest.json")

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "ASR", "Transcribing audio segments")
        asr_provider = None
        asr_provider_model = config.pipeline.asr_provider_model
        if config.pipeline.asr_mode == "openai" and config.pipeline.asr_provider:
            asr_provider = config.providers.get(config.pipeline.asr_provider)
            if asr_provider is None:
                raise RuntimeError(f"ASR provider not found: {config.pipeline.asr_provider}")
            if not asr_provider_model:
                asr_provider_model = asr_provider.models[0] if asr_provider.models else config.pipeline.asr_cloud_model
        asr = AsrEngine(
            model_size=config.pipeline.asr_model_size,
            device=config.pipeline.asr_device,
            compute_type=config.pipeline.asr_compute_type,
            mode=config.pipeline.asr_mode,
            source_lang=task.source_lang,
            cloud_base_url=config.pipeline.asr_cloud_base_url,
            cloud_endpoint=config.pipeline.asr_cloud_endpoint,
            cloud_model=config.pipeline.asr_cloud_model,
            cloud_env_key=config.pipeline.asr_cloud_env_key,
            cloud_timeout_seconds=config.pipeline.asr_cloud_timeout_seconds,
            cloud_provider=asr_provider,
            cloud_provider_model=asr_provider_model,
        )
        asr_done = set(checkpoint.get("asr_done_segments", []))
        segment_files = []
        for item in segments_manifest:
            _check_cancel(store, task_id)
            idx = int(item["segment_index"])
            segment_output = paths["asr"] / f"segment_{idx:05d}.json"
            segment_files.append((idx, segment_output))
            if idx in asr_done and segment_output.exists():
                continue
            rows = asr.transcribe_segment(Path(item["path"]), float(item["start"]))
            write_segment_asr_output(segment_output, rows)
            asr_done.add(idx)
            checkpoint["asr_done_segments"] = sorted(asr_done)
            checkpoint["status"] = "ASR"
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "progress",
                stage="ASR",
                message=f"Transcribed segment {len(asr_done)}/{len(segments_manifest)}",
                progress=0.25 + 0.25 * (len(asr_done) / max(len(segments_manifest), 1)),
            )

        all_segments: list[Segment] = []
        next_id = 1
        for _idx, seg_file in sorted(segment_files, key=lambda x: x[0]):
            _require_file(seg_file, f"asr/{seg_file.name}")
            rows = read_json(seg_file)
            parsed = _parse_asr_rows(rows, start_id=next_id)
            all_segments.extend(parsed)
            next_id = all_segments[-1].id + 1 if all_segments else 1
        deduped_segments = dedupe_overlap_segments(all_segments)
        if len(deduped_segments) != len(all_segments):
            store.append_event(
                task_id,
                "warning",
                stage="ASR",
                level="warning",
                message="Removed duplicate overlap segments",
                details={"before": len(all_segments), "after": len(deduped_segments)},
            )
        all_segments = deduped_segments

        raw_jsonl = paths["asr"] / "segments.raw.jsonl"
        _persist_segments_jsonl(raw_jsonl, all_segments)
        store.append_event(
            task_id,
            "artifact",
            stage="ASR",
            message="Raw ASR segments ready",
            progress=0.52,
            details={"path": str(raw_jsonl), "segments": len(all_segments)},
        )

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "SEGMENT", "Preparing translation chunks")
        chunks = number_and_chunk_segments(all_segments, config.pipeline.translation_batch_size)
        write_json(paths["chunks"] / "chunks.json", chunks)
        checkpoint["status"] = "SEGMENT"
        store.save_checkpoint(task_id, checkpoint)

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "TRANSLATE", "Translating chunks")
        translated_done = set(checkpoint.get("translate_done_chunks", []))
        translated_file = paths["translate"] / "segments.translated.jsonl"
        translated_rows = read_jsonl(translated_file)
        if translated_rows:
            translated_done.update(r.get("chunk_id") for r in translated_rows if r.get("chunk_id"))
        new_rows = translate_all_chunks(
            config,
            chunks,
            source_lang=task.source_lang,
            target_lang=task.target_lang,
            already_done=translated_done,
        )
        for row in sorted(new_rows, key=lambda x: x["chunk_id"]):
            append_jsonl(translated_file, row)
            translated_done.add(row["chunk_id"])
            checkpoint["translate_done_chunks"] = sorted(translated_done)
            checkpoint["status"] = "TRANSLATE"
            store.save_checkpoint(task_id, checkpoint)
            store.append_event(
                task_id,
                "progress",
                stage="TRANSLATE",
                message=f"Translated chunk {len(translated_done)}/{len(chunks)}",
                progress=0.65 + 0.18 * (len(translated_done) / max(len(chunks), 1)),
            )

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "ALIGN", "Aligning and validating subtitles")
        translated_rows = read_jsonl(translated_file)
        final_segments = normalize_timeline(apply_translations(all_segments, translated_rows))
        errors, warnings = validate_segments(final_segments, max_cps=config.pipeline.max_cps)
        for warning in warnings:
            store.append_event(task_id, "warning", stage="ALIGN", level="warning", message=warning)
        if errors:
            raise RuntimeError("; ".join(errors[:10]))
        write_json(paths["final"] / "segments.final.json", final_segments)
        checkpoint["status"] = "ALIGN"
        store.save_checkpoint(task_id, checkpoint)

        _check_cancel(store, task_id)
        _emit_stage(store, task_id, "EXPORT", "Exporting SRT")
        if output_file is None:
            default_name = f"{Path(task.input_file).stem}.{task.target_lang}.srt"
            output_file = paths["output"] / default_name
        export_srt(final_segments, output_file, task.bilingual)
        checkpoint["status"] = "DONE"
        store.save_checkpoint(task_id, checkpoint)
        store.update_task_status(task_id, "DONE", output_path=str(output_file))
        store.append_event(
            task_id,
            "done",
            stage="DONE",
            message="Task completed",
            progress=1.0,
            details={"output_path": str(output_file)},
        )
    except TaskCancelled as exc:
        store.update_task_status(task_id, "CANCELLED", error=str(exc))
        checkpoint["status"] = "CANCELLED"
        checkpoint["error"] = str(exc)
        store.save_checkpoint(task_id, checkpoint)
        store.append_event(task_id, "cancelled", stage=checkpoint.get("status"), message=str(exc), level="warning")
        raise
    except Exception as exc:
        store.update_task_status(task_id, "FAILED", error=str(exc))
        checkpoint["status"] = "FAILED"
        checkpoint["error"] = str(exc)
        store.save_checkpoint(task_id, checkpoint)
        store.append_event(
            task_id,
            "error",
            stage=str(checkpoint.get("status", task.status)),
            message=str(exc),
            level="error",
        )
        raise


def task_status_json(task: TaskRecord) -> dict[str, Any]:
    return _status_json(task)
