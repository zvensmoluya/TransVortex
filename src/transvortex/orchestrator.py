from __future__ import annotations

from pathlib import Path

from .aligner import apply_translations, validate_segments
from .asr import AsrEngine, write_segment_asr_output
from .chunking import number_and_chunk_segments
from .config import load_app_config
from .exporter import export_srt
from .media import extract_audio, split_audio_with_overlap
from .models import AppConfig, Segment, TaskRecord
from .task_store import TaskStore
from .translate import translate_all_chunks
from .utils import append_jsonl, gen_task_id, read_json, read_jsonl, to_plain, utc_now_iso, write_json


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
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    store = TaskStore(config.pipeline.artifacts_dir)
    task = _create_task(
        store,
        input_file=input_file,
        source_lang=source_lang,
        target_lang=target_lang,
        bilingual=bilingual,
        settings=to_plain(config.pipeline),
    )
    _execute_task(config, store, task.task_id, output_file=output_file)
    return task.task_id


def resume_pipeline(
    *,
    root_dir: Path,
    task_id: str,
    output_file: Path | None = None,
    providers_file: Path | None = None,
    cli_overrides: dict | None = None,
) -> str:
    config = load_app_config(root_dir=root_dir, providers_file=providers_file, cli_overrides=cli_overrides)
    store = TaskStore(config.pipeline.artifacts_dir)
    store.load_task(task_id)
    _execute_task(config, store, task_id, output_file=output_file)
    return task_id


def _execute_task(config: AppConfig, store: TaskStore, task_id: str, output_file: Path | None = None) -> None:
    task = store.load_task(task_id)
    paths = _task_paths(store, task_id)
    for p in paths.values():
        p.mkdir(parents=True, exist_ok=True)

    checkpoint = store.load_checkpoint(task_id)
    try:
        store.update_task_status(task_id, "INGEST")
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
            checkpoint["ingest_done"] = True
            checkpoint["status"] = "INGEST"
            store.save_checkpoint(task_id, checkpoint)
        else:
            segments_manifest = read_json(paths["media"] / "segments_manifest.json")

        store.update_task_status(task_id, "ASR")
        asr_provider = None
        asr_provider_model = config.pipeline.asr_provider_model
        if config.pipeline.asr_provider:
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

        all_segments: list[Segment] = []
        next_id = 1
        for _idx, seg_file in sorted(segment_files, key=lambda x: x[0]):
            rows = read_json(seg_file)
            parsed = _parse_asr_rows(rows, start_id=next_id)
            all_segments.extend(parsed)
            next_id = all_segments[-1].id + 1 if all_segments else 1

        raw_jsonl = paths["asr"] / "segments.raw.jsonl"
        _persist_segments_jsonl(raw_jsonl, all_segments)

        store.update_task_status(task_id, "SEGMENT")
        chunks = number_and_chunk_segments(all_segments, config.pipeline.translation_batch_size)
        write_json(paths["chunks"] / "chunks.json", chunks)

        store.update_task_status(task_id, "TRANSLATE")
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

        store.update_task_status(task_id, "ALIGN")
        translated_rows = read_jsonl(translated_file)
        final_segments = apply_translations(all_segments, translated_rows)
        errors = validate_segments(final_segments)
        if errors:
            raise RuntimeError("; ".join(errors[:10]))
        write_json(paths["final"] / "segments.final.json", final_segments)

        store.update_task_status(task_id, "EXPORT")
        if output_file is None:
            default_name = f"{Path(task.input_file).stem}.{task.target_lang}.srt"
            output_file = paths["output"] / default_name
        export_srt(final_segments, output_file, task.bilingual)
        checkpoint["status"] = "DONE"
        store.save_checkpoint(task_id, checkpoint)
        store.update_task_status(task_id, "DONE", output_path=str(output_file))
    except Exception as exc:
        store.update_task_status(task_id, "FAILED", error=str(exc))
        checkpoint["status"] = "FAILED"
        checkpoint["error"] = str(exc)
        store.save_checkpoint(task_id, checkpoint)
        raise
