from __future__ import annotations

import yaml
from pathlib import Path

from transvortex.prompts.asr_admin import (
    delete_asr_prompt_profile,
    list_asr_prompt_profiles,
    save_asr_prompt_profile,
)


def test_save_list_delete_asr_prompt_profile(tmp_path: Path) -> None:
    (tmp_path / "pipeline.yaml").write_text("asr:\n  prompt:\n    enabled: true\n", encoding="utf-8")

    saved = save_asr_prompt_profile(
        root_dir=tmp_path,
        profile={
            "id": "anime_names",
            "name": "Anime Names",
            "text": "Names: Subaru",
            "include_previous_text": True,
            "max_chars": 224,
        },
    )

    prompt_path = tmp_path / "prompts" / "asr" / "anime_names.v1.md"
    assert prompt_path.read_text(encoding="utf-8") == "Names: Subaru"
    assert saved["active_profile"] == "anime_names"
    data = yaml.safe_load((tmp_path / "pipeline.yaml").read_text(encoding="utf-8"))
    row = data["asr"]["prompt"]["profiles"][0]
    assert row["path"] == "prompts/asr/anime_names.v1.md"
    assert row["include_previous_text"] is True

    listed = list_asr_prompt_profiles(root_dir=tmp_path)
    assert listed["profiles"][0]["text"] == "Names: Subaru"

    deleted = delete_asr_prompt_profile(root_dir=tmp_path, profile_id="anime_names")

    assert deleted["deleted"] is True
    assert deleted["active_profile"] == ""
    assert not prompt_path.exists()


def test_asr_prompt_profile_rejects_invalid_id(tmp_path: Path) -> None:
    try:
        save_asr_prompt_profile(root_dir=tmp_path, profile={"id": "../bad", "text": "x"})
    except ValueError as exc:
        assert "invalid_asr_prompt_profile_id" in str(exc)
    else:
        raise AssertionError("expected invalid profile id")
