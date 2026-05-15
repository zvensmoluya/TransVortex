from __future__ import annotations

from pathlib import Path

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


def test_split_audio_for_asr_writes_trusted_regions(monkeypatch, tmp_path: Path) -> None:
    calls = []

    def fake_run(cmd: list[str]):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"wav")

    monkeypatch.setattr(media, "_run", fake_run)

    manifest = media.split_audio_for_asr(
        tmp_path / "audio.m4a",
        tmp_path / "segments",
        mode="auto",
        window_seconds=300,
        overlap_seconds=30,
        short_audio_seconds=300,
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
