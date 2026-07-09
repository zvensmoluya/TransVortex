from transvortex.protocol.errors import classify_exception


def test_classify_ffmpeg_failure_as_media_processing_error() -> None:
    info = classify_exception(
        RuntimeError(
            "Command '['ffmpeg', '-i', 'demo.mp3']' returned non-zero exit status 4294967274."
        ),
        stage="PRECHECK",
    )

    assert info["code"] == "media_processing_failed"
    assert "音频处理失败" in info["hint_zh"]
    assert "stderr" not in info["hint_zh"]


def test_runtime_error_hint_is_user_facing() -> None:
    info = classify_exception(RuntimeError("unknown failure"), stage="TRANSLATE")

    assert info["code"] == "runtime_error"
    assert "events.json" not in info["hint_zh"]
    assert "stderr" not in info["hint_zh"]
