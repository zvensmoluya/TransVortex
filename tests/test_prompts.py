from pathlib import Path

from transvortex.prompts import (
    FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT,
    FALLBACK_TRANSLATION_STYLE_PROMPT,
    FALLBACK_TRANSLATION_SYSTEM_PROMPT,
    load_prompt,
)


def test_packaged_prompt_defaults_load() -> None:
    assert load_prompt("translation_system") == FALLBACK_TRANSLATION_SYSTEM_PROMPT
    assert load_prompt("translation_style_zh-CN") == FALLBACK_TRANSLATION_STYLE_PROMPT
    assert load_prompt("memory_patch_system") == FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT


def test_root_default_prompt_files_load() -> None:
    root = Path(__file__).resolve().parents[1]
    assert load_prompt("translation_system", root_dir=root).startswith("You are a professional subtitle translator")
    assert load_prompt("translation_style_zh-CN", root_dir=root).startswith("Translate into natural Simplified")
    assert load_prompt("memory_patch_system", root_dir=root).startswith("You are a translation memory curator")


def test_memory_patch_prompt_emphasizes_conservative_deduplication() -> None:
    prompt = FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT
    assert "Prefer precision over recall" in prompt
    assert "ASR error" in prompt
    assert "aliases" in prompt
    assert "Do not create duplicate canonical entries" in prompt
    assert "empty actions array" in prompt


def test_memory_patch_file_matches_fallback() -> None:
    root = Path(__file__).resolve().parents[1]
    file_prompt = (root / "prompts" / "memory" / "patch_system.v1.md").read_text(encoding="utf-8").strip()
    assert file_prompt == FALLBACK_MEMORY_PATCH_SYSTEM_PROMPT


def test_prompt_override_path_wins(tmp_path: Path) -> None:
    override = tmp_path / "prompt.md"
    override.write_text("Custom prompt.", encoding="utf-8")

    assert load_prompt("translation_system", override_path=override) == "Custom prompt."
