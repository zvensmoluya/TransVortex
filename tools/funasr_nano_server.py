from __future__ import annotations

import argparse
import re
import tempfile
import time
from pathlib import Path
from typing import Any

import soundfile as sf
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from funasr import AutoModel

SENSEVOICE_TAG_RE = re.compile(r"<\|([^|]+)\|>")
SENSEVOICE_BLOCK_RE = re.compile(r"((?:<\|[^|]+\|>)+)([^<]*)")
SENTENCE_BOUNDARY_CHARS = set("。.!！？?")
SENSEVOICE_MAX_SEGMENT_SECONDS = 10.0
SENSEVOICE_MAX_SEGMENT_CHARS = 60
SENSEVOICE_LANGUAGE_TAGS = {"zh", "en", "ja", "ko", "yue", "nospeech"}
SENSEVOICE_EVENT_TAGS = {"Speech", "Breath", "Laughter", "Cry", "Event_UNK"}
SENSEVOICE_EMOTION_TAGS = {
    "EMO_UNKNOWN",
    "HAPPY",
    "SAD",
    "ANGRY",
    "NEUTRAL",
    "FEARFUL",
    "DISGUSTED",
    "SURPRISED",
}


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _default_model_dir() -> Path:
    return Path.home() / ".cache" / "modelscope" / "hub" / "models" / "FunAudioLLM" / "Fun-ASR-Nano-2512"


def _sensevoice_model_dir() -> Path:
    return Path.home() / ".cache" / "modelscope" / "hub" / "models" / "iic" / "SenseVoiceSmall"


def _audio_duration(path: Path) -> float:
    try:
        info = sf.info(str(path))
        if info.samplerate:
            return float(info.frames) / float(info.samplerate)
    except Exception:
        pass
    return 0.0


def _text_from_item(item: dict[str, Any]) -> str:
    for key in ("text", "sentence"):
        value = item.get(key)
        if isinstance(value, (str, int, float)):
            text = str(value).strip()
            if text:
                return text
    return ""


def _seconds_pair(item: dict[str, Any]) -> tuple[float | None, float | None]:
    for start_key, end_key in (("start", "end"), ("start_time", "end_time")):
        try:
            start = float(item[start_key])
            end = float(item[end_key])
        except (KeyError, TypeError, ValueError):
            continue
        return start, end

    timestamp = item.get("timestamp")
    if isinstance(timestamp, list) and len(timestamp) >= 2:
        try:
            return float(timestamp[0]) / 1000.0, float(timestamp[1]) / 1000.0
        except (TypeError, ValueError):
            return None, None
    return None, None


def _clean_sensevoice_text(text: str) -> str:
    return re.sub(r"\s+", " ", SENSEVOICE_TAG_RE.sub("", text)).strip()


def _sensevoice_tag_meta(tags: list[str]) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    other_tags: list[str] = []
    for tag in tags:
        if tag in SENSEVOICE_LANGUAGE_TAGS and "language_tag" not in meta:
            meta["language_tag"] = tag
        elif tag in SENSEVOICE_EMOTION_TAGS and "emotion_tag" not in meta:
            meta["emotion_tag"] = tag
        elif tag in SENSEVOICE_EVENT_TAGS and "event_tag" not in meta:
            meta["event_tag"] = tag
        else:
            other_tags.append(tag)
    if other_tags:
        meta["other_tags"] = other_tags
    return meta


def _timestamp_pair_seconds(value: Any) -> tuple[float, float] | None:
    if not isinstance(value, list) or len(value) < 2:
        return None
    try:
        start = float(value[0]) / 1000.0
        end = float(value[1]) / 1000.0
    except (TypeError, ValueError):
        return None
    if end <= start:
        end = start + 0.01
    return start, end


def _split_text_ranges(text: str, *, max_chars: int = SENSEVOICE_MAX_SEGMENT_CHARS) -> list[tuple[int, int]]:
    if len(text) <= max_chars:
        return [(0, len(text))]
    ranges: list[tuple[int, int]] = []
    start = 0
    for index, char in enumerate(text, start=1):
        if char in SENTENCE_BOUNDARY_CHARS and index > start:
            ranges.append((start, index))
            start = index
    if start < len(text):
        ranges.append((start, len(text)))

    out: list[tuple[int, int]] = []
    for range_start, range_end in ranges:
        cursor = range_start
        while range_end - cursor > max_chars:
            split_at = cursor + max_chars
            space_at = text.rfind(" ", cursor + max_chars // 2, split_at + 1)
            if space_at > cursor:
                split_at = space_at + 1
            out.append((cursor, split_at))
            cursor = split_at
        if cursor < range_end:
            out.append((cursor, range_end))
    return [(start, end) for start, end in out if end > start]


def _sensevoice_blocks_from_text(text: str) -> list[dict[str, Any]]:
    blocks: list[dict[str, Any]] = []
    for match in SENSEVOICE_BLOCK_RE.finditer(text):
        tag_text, body = match.groups()
        clean = _clean_sensevoice_text(body)
        if not clean:
            continue
        tags = SENSEVOICE_TAG_RE.findall(tag_text)
        blocks.append(
            {
                "text": clean,
                "meta": {
                    "source": "sensevoice_tag_block",
                    "has_real_timestamp": False,
                    **_sensevoice_tag_meta(tags),
                },
            }
        )
    if not blocks:
        clean = _clean_sensevoice_text(text)
        if clean:
            blocks.append({"text": clean, "meta": {"source": "sensevoice_clean_text", "has_real_timestamp": False}})
    return blocks


def _timed_sensevoice_blocks_from_text(text: str, duration: float, timestamps: list[Any] | None = None) -> list[dict[str, Any]]:
    blocks = _sensevoice_blocks_from_text(text)
    total_chars = sum(len(str(item.get("text", ""))) for item in blocks) or 1
    cursor = 0
    segments: list[dict[str, Any]] = []
    usable_timestamps = timestamps if isinstance(timestamps, list) else []
    for index, item in enumerate(blocks):
        segment_text = str(item["text"])
        char_count = len(segment_text)
        start = duration * cursor / total_chars
        end = duration * (cursor + char_count) / total_chars
        timestamp_slice = usable_timestamps[cursor : cursor + char_count]
        meta = dict(item.get("meta") or {})
        valid_pairs = [pair for pair in (_timestamp_pair_seconds(value) for value in timestamp_slice) if pair]
        if valid_pairs:
            start = valid_pairs[0][0]
            end = valid_pairs[-1][1]
            meta["has_real_timestamp"] = True
            meta["timestamp_source"] = "funasr_output_timestamp"
        else:
            meta["has_real_timestamp"] = False
            meta["timestamp_source"] = "char_ratio_fallback"
        cursor += char_count
        duration_seconds = max(end - start, 0.01)
        split_ranges = (
            _split_text_ranges(segment_text)
            if duration_seconds > SENSEVOICE_MAX_SEGMENT_SECONDS or len(segment_text) > SENSEVOICE_MAX_SEGMENT_CHARS
            else [(0, len(segment_text))]
        )
        for split_start, split_end in split_ranges:
            split_text = segment_text[split_start:split_end].strip()
            if not split_text:
                continue
            split_meta = dict(meta)
            split_pairs = valid_pairs[split_start:split_end]
            if split_pairs:
                split_start_time = split_pairs[0][0]
                split_end_time = split_pairs[-1][1]
            else:
                split_start_time = start + duration_seconds * (split_start / max(len(segment_text), 1))
                split_end_time = start + duration_seconds * (split_end / max(len(segment_text), 1))
            if len(split_ranges) > 1:
                split_meta["split_from_sensevoice_block"] = True
            if split_end_time <= split_start_time:
                split_end_time = split_start_time + 0.01
            segments.append(
                {
                    "id": len(segments),
                    "start": round(split_start_time, 3),
                    "end": round(split_end_time, 3),
                    "text": split_text,
                    "meta": split_meta,
                }
            )
    return segments


def _segments_from_result(result: Any, duration: float) -> list[dict[str, Any]]:
    if isinstance(result, list):
        items = [item for item in result if isinstance(item, dict)]
    elif isinstance(result, dict):
        items = [result]
    else:
        items = []

    segments: list[dict[str, Any]] = []
    combined_text: list[str] = []
    for index, item in enumerate(items):
        text = _text_from_item(item)
        if not text:
            continue
        combined_text.append(text)
        start, end = _seconds_pair(item)
        if start is None or end is None or end <= start:
            start = 0.0 if not segments else float(segments[-1]["end"])
            end = duration if duration > start else start + 0.01
        segments.append(
            {
                "id": index,
                "start": start,
                "end": end,
                "text": text,
            }
        )
    if not segments and combined_text:
        segments.append({"id": 0, "start": 0.0, "end": max(duration, 0.01), "text": "".join(combined_text)})
    return segments


def _segments_from_sensevoice_result(result: Any, duration: float) -> list[dict[str, Any]]:
    if isinstance(result, list):
        items = [item for item in result if isinstance(item, dict)]
    elif isinstance(result, dict):
        items = [result]
    else:
        items = []

    segments: list[dict[str, Any]] = []
    fallback_texts: list[str] = []
    cursor = 0.0
    for item in items:
        text = _text_from_item(item)
        if not text:
            continue
        fallback_texts.append(text)
        start, end = _seconds_pair(item)
        item_duration = max((end or duration) - (start or 0.0), 0.01)
        item_start = cursor if start is None else start
        timestamps = item.get("timestamp")
        block_segments = _timed_sensevoice_blocks_from_text(
            text,
            item_duration,
            timestamps=timestamps if isinstance(timestamps, list) else None,
        )
        for block in block_segments:
            local_start = float(block["start"])
            local_end = float(block["end"])
            block["id"] = len(segments)
            block["start"] = round(item_start + local_start, 3)
            block["end"] = round(item_start + local_end, 3)
            block["meta"] = {"provider_model": "sensevoice", **dict(block.get("meta") or {})}
            segments.append(block)
        cursor = max(cursor, item_start + item_duration)
    if segments:
        return segments
    if fallback_texts:
        return _timed_sensevoice_blocks_from_text(" ".join(fallback_texts), duration)
    return []


def create_app(model_dir: Path, device: str, model_name: str) -> FastAPI:
    app = FastAPI(title="TransVortex FunASR Local Server")
    app.state.model = None

    @app.on_event("startup")
    def load_model() -> None:
        t0 = time.time()
        app.state.model = AutoModel(
            model=str(model_dir),
            trust_remote_code=model_name == "fun-asr-nano",
            vad_model="fsmn-vad",
            vad_kwargs={"max_single_segment_time": 30000},
            device=device,
            disable_update=True,
        )
        app.state.loaded_seconds = round(time.time() - t0, 2)

    @app.get("/")
    def root() -> dict[str, Any]:
        return {"status": "ok", "model": model_name, "loaded_seconds": app.state.loaded_seconds}

    @app.get("/v1/models")
    def models() -> dict[str, Any]:
        aliases = [model_name]
        if model_name == "sensevoice":
            aliases.append("fun-asr-nano")
        return {"data": [{"id": item, "object": "model"} for item in aliases]}

    @app.post("/v1/audio/transcriptions")
    async def transcriptions(
        file: UploadFile = File(...),
        model: str = Form(default="fun-asr-nano"),
        language: str = Form(default="auto"),
        response_format: str = Form(default="verbose_json"),
    ) -> dict[str, Any]:
        accepted = {model_name}
        if model_name == "sensevoice":
            accepted.add("fun-asr-nano")
        if model not in accepted:
            raise HTTPException(status_code=400, detail=f"unsupported model: {model}")
        suffix = Path(file.filename or "audio.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(await file.read())
        try:
            duration = _audio_duration(tmp_path)
            if duration < 0.5:
                payload = {"text": "", "segments": []}
                if response_format == "json":
                    return {"text": ""}
                return payload
            kwargs: dict[str, Any] = {}
            if language:
                kwargs["language"] = language
            if model_name == "sensevoice":
                kwargs.update(
                    {
                        "batch_size_s": 60,
                        "merge_vad": True,
                        "merge_length_s": 15,
                        "use_itn": True,
                        "output_timestamp": True,
                    }
                )
            else:
                kwargs.update({"batch_size": 1, "batch_size_s": 0})
            result = app.state.model.generate(input=str(tmp_path), **kwargs)
            if model_name == "sensevoice":
                segments = _segments_from_sensevoice_result(result, duration)
            else:
                segments = _segments_from_result(result, duration)
            text = "".join(segment["text"] for segment in segments)
            payload = {"text": text, "segments": segments}
            if response_format == "json":
                return {"text": text}
            return payload
        finally:
            tmp_path.unlink(missing_ok=True)

    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="TransVortex local FunASR Nano OpenAI-compatible server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--model", choices=["fun-asr-nano", "sensevoice"], default="fun-asr-nano")
    parser.add_argument("--model-dir", type=Path, default=None)
    args = parser.parse_args()

    model_dir = args.model_dir
    if model_dir is None:
        model_dir = _sensevoice_model_dir() if args.model == "sensevoice" else _default_model_dir()
    if not model_dir.exists():
        raise SystemExit(f"model dir not found: {model_dir}")
    app = create_app(model_dir, args.device, args.model)
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
