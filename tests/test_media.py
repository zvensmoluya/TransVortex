from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from transvortex.core import media


def test_subtitle_stream_selection_prefers_matching_default(monkeypatch, tmp_path: Path) -> None:
    def fake_probe(_path: Path) -> dict:
        return {
            "streams": [
                {"index": 1, "codec_type": "subtitle", "codec_name": "hdmv_pgs_subtitle", "tags": {"language": "jpn"}},
                {
                    "index": 2,
                    "codec_type": "subtitle",
                    "codec_name": "subrip",
                    "tags": {"language": "eng", "title": "English"},
                    "disposition": {"default": 0, "forced": 0},
                },
                {
                    "index": 3,
                    "codec_type": "subtitle",
                    "codec_name": "ass",
                    "tags": {"language": "jpn", "title": "Japanese"},
                    "disposition": {"default": 1, "forced": 0},
                },
            ],
            "format": {"duration": "10"},
        }

    monkeypatch.setattr(media, "probe_audio", fake_probe)

    streams = media.list_subtitle_streams(tmp_path / "demo.mkv")
    selected = media.select_subtitle_stream(streams, source_lang="ja")

    assert selected is not None
    assert selected["index"] == 3
    assert selected["supported"] is True
    assert streams[0]["supported"] is False


def test_extract_subtitle_stream_invokes_ffmpeg(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)

    monkeypatch.setattr(media, "_run", fake_run)

    media.extract_subtitle_stream(tmp_path / "demo.mkv", tmp_path / "out" / "sub.srt", stream_index=4)

    assert calls[0][0] == "ffmpeg"
    assert calls[0][calls[0].index("-map") + 1] == "0:4"
    assert calls[0][-1].endswith("sub.srt")


def test_extract_audio_for_asr_selects_matching_language_track(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_probe(_path: Path) -> dict:
        return {
            "streams": [
                {"index": 1, "codec_type": "audio", "codec_name": "aac", "tags": {"language": "eng"}},
                {"index": 2, "codec_type": "audio", "codec_name": "aac", "tags": {"language": "jpn"}, "duration": "12.5"},
            ],
            "format": {"duration": "13.0"},
        }

    def fake_run(cmd: list[str]):
        calls.append(cmd)

    monkeypatch.setattr(media, "probe_audio", fake_probe)
    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(media, "probe_media_duration", lambda _path: 300.0 if _path.name != "part_00002.wav" else 80.0)

    meta = media.extract_audio_for_asr(tmp_path / "demo.mkv", tmp_path / "audio.m4a", source_lang="ja")

    assert calls[0][calls[0].index("-map") + 1] == "0:2"
    assert meta["audio_stream_index"] == 2
    assert meta["audio_stream_language"] == "jpn"
    assert meta["duration_seconds"] == 12.5


def test_split_audio_for_asr_writes_trusted_regions(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"wav")

    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(media, "probe_media_duration", lambda _path: 300.0 if _path.name != "part_00002.wav" else 80.0)

    manifest = media.split_audio_for_asr(
        tmp_path / "audio.m4a",
        tmp_path / "segments",
        mode="auto",
        window_seconds=300,
        overlap_seconds=30,
        short_audio_seconds=300,
        max_upload_mb=24,
        duration_seconds=620,
    )

    assert [round(item["start"]) for item in manifest] == [0, 270, 540]
    assert manifest[0]["trusted_start"] == 0
    assert manifest[0]["trusted_end"] == 285
    assert manifest[1]["trusted_start"] == 285
    assert manifest[1]["trusted_end"] == 555
    assert manifest[2]["trusted_start"] == 555
    assert manifest[2]["trusted_end"] == 620
    assert len(calls) == 3


def test_split_audio_for_asr_auto_uses_upload_limit_as_hard_cap(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"wav")

    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(media, "probe_media_duration", lambda _path: 262.016 if _path.name != "part_00002.wav" else 155.968)

    manifest = media.split_audio_for_asr(
        tmp_path / "audio.m4a",
        tmp_path / "segments",
        mode="auto",
        window_seconds=300,
        overlap_seconds=30,
        short_audio_seconds=300,
        max_upload_mb=8,
        duration_seconds=620,
    )

    assert [round(item["start"]) for item in manifest] == [0, 232, 464]
    assert calls[0][calls[0].index("-t") + 1].startswith("262.0")


def test_split_audio_for_asr_fixed_ignores_single_upload_size_limit(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"wav")

    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(media, "probe_media_duration", lambda _path: 300.0 if _path.name != "part_00002.wav" else 80.0)

    manifest = media.split_audio_for_asr(
        tmp_path / "audio.m4a",
        tmp_path / "segments",
        mode="fixed",
        window_seconds=300,
        overlap_seconds=30,
        short_audio_seconds=300,
        max_upload_mb=24,
        duration_seconds=620,
    )

    assert [round(item["start"]) for item in manifest] == [0, 270, 540]
    assert len(calls) == 3


def test_split_audio_for_asr_silence_uses_detected_boundaries(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"wav")

    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(media, "probe_media_duration", lambda _path: 0.0)
    monkeypatch.setattr(
        media,
        "detect_audio_silence",
        lambda *_args, **_kwargs: [
            {"start": 54.6, "end": 55.0, "duration": 0.4},
            {"start": 114.0, "end": 114.6, "duration": 0.6},
        ],
    )

    manifest = media.split_audio_for_asr(
        tmp_path / "audio.m4a",
        tmp_path / "segments",
        mode="silence",
        window_seconds=300,
        max_window_seconds=60,
        min_window_seconds=12,
        overlap_seconds=2,
        short_audio_seconds=300,
        max_upload_mb=24,
        duration_seconds=130,
        validate_duration=False,
    )

    assert [round(item["start"], 1) for item in manifest] == [0.0, 52.9, 110.9]
    assert [round(item["duration"], 1) for item in manifest] == [54.9, 60.0, 19.1]
    assert {item["source_audio_path"] for item in manifest} == {str(tmp_path / "audio.m4a")}
    assert len(calls) == 3


def test_prepare_cloud_asr_audio_upload_trims_leading_and_trailing_silence(monkeypatch, tmp_path: Path) -> None:
    source = tmp_path / "part.wav"
    upload = tmp_path / "upload" / "part.wav"
    source.write_bytes(b"wav")
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).parent.mkdir(parents=True, exist_ok=True)
        Path(cmd[-1]).write_bytes(b"trimmed")

    monkeypatch.setattr(media, "_run", fake_run)
    monkeypatch.setattr(
        media,
        "detect_audio_silence",
        lambda *_args, **_kwargs: [
            {"start": 0.0, "end": 3.0, "duration": 3.0},
            {"start": 9.6, "end": 10.0, "duration": 0.4},
        ],
    )

    meta = media.prepare_cloud_asr_audio_upload(
        source,
        upload,
        duration_seconds=10.0,
        enabled=True,
        backend="ffmpeg_silencedetect",
        noise_db=-35,
        min_silence_seconds=0.2,
        keep_preroll_seconds=0.25,
        trim_trailing=True,
        keep_postroll_seconds=0.1,
        min_upload_seconds=0.5,
    )

    assert meta["reason"] == "trimmed"
    assert meta["upload_path"] == str(upload)
    assert meta["leading_silence_seconds"] == 3.0
    assert meta["trailing_silence_seconds"] == 0.40000000000000036
    assert meta["trim_start_seconds"] == 2.75
    assert meta["trim_end_seconds"] == 9.7
    assert upload.exists()
    assert calls[0][calls[0].index("-ss") + 1] == "2.750"


def test_prepare_cloud_asr_audio_upload_skips_all_silence(monkeypatch, tmp_path: Path) -> None:
    source = tmp_path / "part.wav"
    upload = tmp_path / "upload" / "part.wav"
    source.write_bytes(b"wav")
    monkeypatch.setattr(
        media,
        "detect_audio_silence",
        lambda *_args, **_kwargs: [{"start": 0.0, "end": 10.0, "duration": 10.0}],
    )

    meta = media.prepare_cloud_asr_audio_upload(
        source,
        upload,
        duration_seconds=10.0,
        enabled=True,
        backend="ffmpeg_silencedetect",
        noise_db=-35,
        min_silence_seconds=0.2,
        keep_preroll_seconds=0.25,
        trim_trailing=True,
        keep_postroll_seconds=0.1,
        min_upload_seconds=0.5,
    )

    assert meta["skipped"] is True
    assert meta["reason"] == "all_silence"
    assert not upload.exists()


def test_prepare_cloud_asr_audio_upload_keeps_original_when_trimmed_audio_is_too_short(monkeypatch, tmp_path: Path) -> None:
    source = tmp_path / "part.wav"
    upload = tmp_path / "upload" / "part.wav"
    source.write_bytes(b"wav")
    monkeypatch.setattr(
        media,
        "detect_audio_silence",
        lambda *_args, **_kwargs: [{"start": 0.0, "end": 9.8, "duration": 9.8}],
    )

    meta = media.prepare_cloud_asr_audio_upload(
        source,
        upload,
        duration_seconds=10.0,
        enabled=True,
        backend="ffmpeg_silencedetect",
        noise_db=-35,
        min_silence_seconds=0.2,
        keep_preroll_seconds=0.0,
        trim_trailing=False,
        keep_postroll_seconds=0.1,
        min_upload_seconds=0.5,
    )

    assert meta["skipped"] is False
    assert meta["reason"] == "no_trim"
    assert meta["upload_path"] == str(source)
    assert meta["trim_start_seconds"] == 0.0
    assert meta["trim_end_seconds"] == 10.0
    assert not upload.exists()


def test_detect_audio_silence_parses_ffmpeg_output(monkeypatch, tmp_path: Path) -> None:
    def fake_run(*_args, **_kwargs):
        return SimpleNamespace(
            returncode=0,
            stdout="",
            stderr=(
                "[silencedetect] silence_start: 0\n"
                "[silencedetect] silence_end: 0.575187 | silence_duration: 0.575187\n"
            ),
        )

    monkeypatch.setattr(media.subprocess, "run", fake_run)

    assert media.detect_audio_silence(tmp_path / "part.wav", noise_db=-35, min_silence_seconds=0.2) == [
        {"start": 0.0, "end": 0.575187, "duration": 0.575187}
    ]


def test_parse_silencedetect_output_handles_unclosed_full_silence() -> None:
    assert media._parse_silencedetect_output("[silencedetect] silence_start: 0\n") == [
        {"start": 0.0, "end": float("inf"), "duration": float("inf")}
    ]
