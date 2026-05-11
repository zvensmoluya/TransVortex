from __future__ import annotations

from transvortex.app.models import Chunk
from transvortex.core.translation_validation import validate_translation_response


def _chunk() -> Chunk:
    return Chunk(
        chunk_id="c00000",
        segment_ids=[2, 3],
        lines=["[2] hello", "[3] damn it"],
        context_before=["[1] before"],
        context_after=["[4] after"],
    )


def test_validation_accepts_exact_numbered_rows() -> None:
    result = validate_translation_response(
        chunk=_chunk(),
        numbered_lines=["[2] 你好", "[3] 该死"],
        raw_text="[2] 你好\n[3] 该死",
    )
    assert result.errors == []
    assert [row.id for row in result.rows] == [2, 3]


def test_validation_accepts_common_numbered_variants_without_explanation() -> None:
    result = validate_translation_response(
        chunk=_chunk(),
        numbered_lines=["2. 你好", "3) 该死"],
        raw_text="2. 你好\n3) 该死",
    )
    assert result.errors == []
    assert [row.id for row in result.rows] == [2, 3]


def test_validation_rejects_missing_extra_duplicate_context_and_explanation() -> None:
    result = validate_translation_response(
        chunk=_chunk(),
        numbered_lines=["[2] 你好", "[2] 重复", "[4] after translated", "[9] extra"],
        raw_text="Here is the translation:\n[2] 你好\n[2] 重复\n[4] after translated\n[9] extra",
    )
    codes = {issue.code for issue in result.errors}
    assert "missing_id" in codes
    assert "duplicate_id" in codes
    assert "context_id_output" in codes
    assert "extra_id" in codes
    assert "explanatory_output" in codes


def test_validation_marks_empty_rows_repairable_without_flagging_dialogue_apologies() -> None:
    result = validate_translation_response(
        chunk=_chunk(),
        numbered_lines=["[2] ", "[3] 抱歉，我来晚了"],
        raw_text="[2] \n[3] 抱歉，我来晚了",
    )
    by_code = {issue.code: issue for issue in result.errors}
    assert by_code["empty_translation"].repairable is True
    assert "refusal_row" not in by_code


def test_validation_flags_refusal_only_when_whole_output_has_no_numbered_rows() -> None:
    result = validate_translation_response(
        chunk=_chunk(),
        numbered_lines=[],
        raw_text="I cannot translate this because it violates policy.",
    )
    assert [issue.code for issue in result.errors] == ["refusal_output"]
