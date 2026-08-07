from __future__ import annotations

from pathlib import Path

from ..app.models import AppConfig, TaskRecord

def _normalize_output_format(value: str) -> str:
    normalized = str(value or "srt").strip().lower()
    if normalized == "webvtt":
        normalized = "vtt"
    return normalized if normalized in {"srt", "ass", "vtt", "lrc", "both"} else "srt"


def _output_paths_for_task(
    *,
    config: AppConfig,
    task: TaskRecord,
    output_file: Path | None,
    output_dir: Path,
) -> tuple[str, dict[str, Path]]:
    output_format = _normalize_output_format(config.pipeline.output_format)
    stem = Path(task.input_file).stem
    if output_file is not None:
        base = output_file.with_suffix("")
        if output_format == "srt":
            return output_format, {"srt": output_file.with_suffix(".srt")}
        if output_format == "ass":
            return output_format, {"ass": output_file.with_suffix(".ass")}
        if output_format == "vtt":
            return output_format, {"vtt": output_file.with_suffix(".vtt")}
        if output_format == "lrc":
            return output_format, {"lrc": output_file.with_suffix(".lrc")}
        return output_format, {
            "srt": base.parent / f"{base.name}.srt",
            "ass": base.parent / f"{base.name}.ass",
        }
    base = output_dir / f"{stem}.{task.target_lang}"
    if output_format == "srt":
        return output_format, {"srt": base.parent / f"{base.name}.srt"}
    if output_format == "ass":
        return output_format, {"ass": base.parent / f"{base.name}.ass"}
    if output_format == "vtt":
        return output_format, {"vtt": base.parent / f"{base.name}.vtt"}
    if output_format == "lrc":
        return output_format, {"lrc": base.parent / f"{base.name}.lrc"}
    return output_format, {"srt": base.parent / f"{base.name}.srt", "ass": base.parent / f"{base.name}.ass"}
