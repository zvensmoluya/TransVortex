from __future__ import annotations

from pathlib import Path

import pytest

from transvortex.app.desktop_api import DesktopApi, DesktopApiError
from transvortex.prompts.styles import TranslationStyleError, TranslationStyleStore


def _write_config(root: Path) -> None:
    (root / "pipeline.yaml").write_text(
        "\n".join(
            [
                "config_schema_version: 2",
                "artifacts_dir: artifacts",
                "asr: {engine: faster_whisper_large_v3}",
                "asr_engines:",
                "  - id: faster_whisper_large_v3",
                "    type: faster_whisper_worker",
                "    runtime: {source: managed, id: managed:faster-whisper}",
                "    model: {source: managed, id: large-v3}",
            ]
        ),
        encoding="utf-8",
    )
    (root / "providers.yaml").write_text(
        "\n".join(
            [
                "providers:",
                "  - name: p1",
                "    api_type: openai",
                "    base_url: https://example.com/v1",
                "    env_key: PROVIDER_KEY",
                "    models: [m1]",
                "routing:",
                "  primary: {provider: p1, model: m1}",
            ]
        ),
        encoding="utf-8",
    )


def test_translation_style_store_crud_and_revision(tmp_path: Path) -> None:
    store = TranslationStyleStore(tmp_path / "styles", default_prompt="Natural subtitles.")

    assert store.get("subtitle_natural").builtin is True
    created = store.create(
        profile_id="faithful",
        name="忠实直译",
        description="尽量贴近原文",
        prompt="Translate faithfully.",
    )
    updated = store.update(
        created.id,
        {"prompt": "Translate faithfully and concisely."},
        expected_revision=created.revision,
    )

    assert [item.id for item in store.list()] == ["subtitle_natural", "faithful"]
    assert updated.revision == 2
    with pytest.raises(TranslationStyleError) as caught:
        store.update(created.id, {"name": "过期写入"}, expected_revision=1)
    assert caught.value.code == "translation_style_revision_conflict"
    store.delete(created.id, expected_revision=updated.revision)
    assert [item.id for item in store.list()] == ["subtitle_natural"]


def test_desktop_translation_style_contract(tmp_path: Path) -> None:
    _write_config(tmp_path)
    api = DesktopApi(root_dir=tmp_path)

    created = api.dispatch(
        "translation.style.create",
        {
            "style_id": "localized",
            "name": "本地化",
            "description": "优先自然表达",
            "prompt": "Localize jokes naturally.",
        },
    )["style"]
    loaded = api.dispatch("translation.style.get", {"style_id": "localized"})["style"]
    listed = api.dispatch("translation.styles.list")["styles"]

    assert created["revision"] == 1
    assert loaded["prompt"] == "Localize jokes naturally."
    assert [item["id"] for item in listed] == ["subtitle_natural", "localized"]
    with pytest.raises(DesktopApiError) as caught:
        api.dispatch(
            "translation.style.delete",
            {"style_id": "subtitle_natural", "expected_revision": 1},
        )
    assert caught.value.code == "translation_style_builtin_readonly"
