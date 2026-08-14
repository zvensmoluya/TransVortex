from __future__ import annotations

import re
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from ..memory.collections import memory_collections_dir
from ..utils import FileLock, read_json, utc_now_iso, write_json


TRANSLATION_STYLE_SCHEMA_VERSION = 1
TRANSLATION_STYLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
DEFAULT_TRANSLATION_STYLE_ID = "subtitle_natural"


class TranslationStyleError(ValueError):
    def __init__(self, code: str, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = details or {}


@dataclass(frozen=True)
class TranslationStyleProfile:
    id: str
    name: str
    prompt: str
    description: str = ""
    revision: int = 1
    builtin: bool = False
    created_at: str = ""
    updated_at: str = ""


def translation_styles_dir(*, root_dir: Path, artifacts_dir: Path) -> Path:
    return memory_collections_dir(root_dir=root_dir, artifacts_dir=artifacts_dir) / "styles"


def style_profile_store_for_config(*, root_dir: Path, config: Any) -> "TranslationStyleStore":
    return TranslationStyleStore(
        translation_styles_dir(
            root_dir=root_dir,
            artifacts_dir=Path(config.pipeline.artifacts_dir),
        ),
        default_prompt=config.pipeline.translation.style_prompt,
    )


def style_payload(profile: TranslationStyleProfile) -> dict[str, Any]:
    return {
        "schema_version": TRANSLATION_STYLE_SCHEMA_VERSION,
        "id": profile.id,
        "name": profile.name,
        "description": profile.description,
        "prompt": profile.prompt,
        "revision": profile.revision,
        "builtin": profile.builtin,
        "created_at": profile.created_at,
        "updated_at": profile.updated_at,
    }


def style_summary(profile: TranslationStyleProfile) -> dict[str, Any]:
    return {
        "id": profile.id,
        "name": profile.name,
        "description": profile.description,
        "revision": profile.revision,
        "builtin": profile.builtin,
        "updated_at": profile.updated_at,
    }


def style_from_payload(payload: dict[str, Any]) -> TranslationStyleProfile:
    if int(payload.get("schema_version") or 0) != TRANSLATION_STYLE_SCHEMA_VERSION:
        raise TranslationStyleError(
            "translation_style_schema_unsupported",
            "unsupported translation style schema",
        )
    profile_id = _style_id(payload.get("id"), generate=False)
    name = str(payload.get("name") or "").strip()
    prompt = str(payload.get("prompt") or "").strip()
    if not name:
        raise TranslationStyleError("translation_style_name_required", "style name is required")
    if not prompt:
        raise TranslationStyleError("translation_style_prompt_required", "style prompt is required")
    return TranslationStyleProfile(
        id=profile_id,
        name=name,
        description=str(payload.get("description") or "").strip(),
        prompt=prompt,
        revision=max(1, int(payload.get("revision") or 1)),
        builtin=False,
        created_at=str(payload.get("created_at") or ""),
        updated_at=str(payload.get("updated_at") or ""),
    )


class TranslationStyleStore:
    def __init__(self, root: Path, *, default_prompt: str) -> None:
        self.root = root.expanduser().resolve()
        self.default_prompt = str(default_prompt or "").strip()

    @property
    def lock_file(self) -> Path:
        return self.root / ".styles.lock"

    @property
    def builtin(self) -> TranslationStyleProfile:
        return TranslationStyleProfile(
            id=DEFAULT_TRANSLATION_STYLE_ID,
            name="自然字幕",
            description="自然、简洁、适合计时字幕的默认翻译风格。",
            prompt=self.default_prompt,
            builtin=True,
        )

    def profile_file(self, profile_id: str) -> Path:
        return self.root / f"{_style_id(profile_id, generate=False)}.json"

    def list(self) -> list[TranslationStyleProfile]:
        profiles = [self.builtin]
        if self.root.exists():
            for path in sorted(self.root.glob("*.json")):
                try:
                    profile = style_from_payload(read_json(path))
                except (OSError, TypeError, ValueError, TranslationStyleError):
                    continue
                if profile.id == path.stem and profile.id != DEFAULT_TRANSLATION_STYLE_ID:
                    profiles.append(profile)
        profiles[1:] = sorted(profiles[1:], key=lambda item: (item.name.casefold(), item.id.casefold()))
        return profiles

    def get(self, profile_id: str) -> TranslationStyleProfile:
        normalized = _style_id(profile_id, generate=False)
        if normalized == DEFAULT_TRANSLATION_STYLE_ID:
            return self.builtin
        path = self.profile_file(normalized)
        if not path.exists():
            raise TranslationStyleError(
                "translation_style_not_found",
                f"translation style not found: {normalized}",
                details={"style_id": normalized},
            )
        try:
            profile = style_from_payload(read_json(path))
        except TranslationStyleError:
            raise
        except (OSError, TypeError, ValueError) as exc:
            raise TranslationStyleError("translation_style_invalid", str(exc)) from exc
        if profile.id != path.stem:
            raise TranslationStyleError(
                "translation_style_id_mismatch",
                "translation style id does not match filename",
            )
        return profile

    def create(
        self,
        *,
        name: str,
        prompt: str,
        profile_id: str = "",
        description: str = "",
    ) -> TranslationStyleProfile:
        normalized_id = _style_id(profile_id, generate=True)
        normalized_name = str(name or "").strip()
        normalized_prompt = str(prompt or "").strip()
        if not normalized_name:
            raise TranslationStyleError("translation_style_name_required", "style name is required")
        if not normalized_prompt:
            raise TranslationStyleError("translation_style_prompt_required", "style prompt is required")
        if normalized_id == DEFAULT_TRANSLATION_STYLE_ID:
            raise TranslationStyleError("translation_style_builtin_readonly", "built-in style is read-only")
        with FileLock(self.lock_file):
            path = self.profile_file(normalized_id)
            if path.exists():
                raise TranslationStyleError(
                    "translation_style_exists",
                    f"translation style already exists: {normalized_id}",
                )
            now = utc_now_iso()
            profile = TranslationStyleProfile(
                id=normalized_id,
                name=normalized_name,
                description=str(description or "").strip(),
                prompt=normalized_prompt,
                created_at=now,
                updated_at=now,
            )
            write_json(path, style_payload(profile))
            return profile

    def update(
        self,
        profile_id: str,
        changes: dict[str, Any],
        *,
        expected_revision: int | None = None,
    ) -> TranslationStyleProfile:
        normalized_id = _style_id(profile_id, generate=False)
        if normalized_id == DEFAULT_TRANSLATION_STYLE_ID:
            raise TranslationStyleError("translation_style_builtin_readonly", "built-in style is read-only")
        with FileLock(self.lock_file):
            current = self.get(normalized_id)
            self._check_revision(current, expected_revision)
            name = str(changes.get("name", current.name) or "").strip()
            prompt = str(changes.get("prompt", current.prompt) or "").strip()
            if not name:
                raise TranslationStyleError("translation_style_name_required", "style name is required")
            if not prompt:
                raise TranslationStyleError("translation_style_prompt_required", "style prompt is required")
            updated = replace(
                current,
                name=name,
                description=str(changes.get("description", current.description) or "").strip(),
                prompt=prompt,
                revision=current.revision + 1,
                updated_at=utc_now_iso(),
            )
            write_json(self.profile_file(normalized_id), style_payload(updated))
            return updated

    def delete(self, profile_id: str, *, expected_revision: int | None = None) -> None:
        normalized_id = _style_id(profile_id, generate=False)
        if normalized_id == DEFAULT_TRANSLATION_STYLE_ID:
            raise TranslationStyleError("translation_style_builtin_readonly", "built-in style is read-only")
        with FileLock(self.lock_file):
            current = self.get(normalized_id)
            self._check_revision(current, expected_revision)
            self.profile_file(normalized_id).unlink()

    @staticmethod
    def _check_revision(profile: TranslationStyleProfile, expected_revision: int | None) -> None:
        if expected_revision is not None and expected_revision != profile.revision:
            raise TranslationStyleError(
                "translation_style_revision_conflict",
                "translation style changed since it was loaded",
                details={"expected_revision": expected_revision, "actual_revision": profile.revision},
            )


def _style_id(value: Any, *, generate: bool) -> str:
    text = str(value or "").strip()
    if not text and generate:
        text = f"style-{uuid.uuid4().hex[:12]}"
    if not text or not TRANSLATION_STYLE_ID_PATTERN.fullmatch(text):
        raise TranslationStyleError("translation_style_id_invalid", "invalid translation style id")
    return text
