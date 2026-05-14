from __future__ import annotations

import hashlib
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from ..app.models import MemoryPresetRef
from ..utils import read_json, to_plain, utc_now_iso
from .schema import (
    MEMORY_STATUS_ORDER,
    MemoryEntry,
    normalize_source_key,
    normalize_status,
)


@dataclass
class MemoryPresetScope:
    language_pairs: list[str] = field(default_factory=list)
    works: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)


@dataclass
class MemoryPresetBundle:
    id: str
    version: str = "1.0.0"
    name: str = ""
    description: str = ""
    scope: MemoryPresetScope = field(default_factory=MemoryPresetScope)
    default_status: str = "confirmed"
    entries: list[MemoryEntry] = field(default_factory=list)
    path: Path | None = None


@dataclass
class MemoryPresetLoadResult:
    bundle: MemoryPresetBundle | None
    error: str = ""


class MemoryPresetError(RuntimeError):
    pass


def presets_dir(root_dir: Path) -> Path:
    return root_dir / "memory" / "presets"


def _bundle_id_from_path(path: Path) -> str:
    return path.stem


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        text = str(item or "").strip()
        if text and text not in out:
            out.append(text)
    return out


def _scope_from_payload(raw: Any) -> MemoryPresetScope:
    if not isinstance(raw, dict):
        return MemoryPresetScope()
    return MemoryPresetScope(
        language_pairs=[item.lower() for item in _string_list(raw.get("language_pairs"))],
        works=_string_list(raw.get("works")),
        tags=_string_list(raw.get("tags")),
    )


def _preset_entry_from_row(row: dict[str, Any]) -> MemoryEntry:
    raw_status = str(row.get("status") or "").strip().lower()
    status = raw_status if raw_status in MEMORY_STATUS_ORDER else ""
    return MemoryEntry(
        id=str(row.get("id") or ""),
        source=str(row.get("source") or ""),
        target=str(row.get("target") or ""),
        category=str(row.get("category") or "term"),
        status=status,
        origin=str(row.get("origin") or ""),
        priority=int(row.get("priority") or 50),
        aliases=[str(item) for item in row.get("aliases", []) or []],
        notes=str(row.get("notes") or ""),
        confidence=float(row.get("confidence") or 0.0),
        evidence_ids=[int(item) for item in row.get("evidence_ids", []) or [] if str(item).isdigit()],
        created_by=str(row.get("created_by") or ""),
        updated_at=str(row.get("updated_at") or ""),
    )


def _bundle_from_payload(payload: dict[str, Any], *, fallback_id: str, path: Path | None) -> MemoryPresetBundle:
    raw_entries = payload.get("entries") if isinstance(payload, dict) else None
    entries = [_preset_entry_from_row(row) for row in (raw_entries or []) if isinstance(row, dict)]
    return MemoryPresetBundle(
        id=str(payload.get("id") or fallback_id).strip() or fallback_id,
        version=str(payload.get("version") or "1.0.0"),
        name=str(payload.get("name") or ""),
        description=str(payload.get("description") or ""),
        scope=_scope_from_payload(payload.get("scope")),
        default_status=normalize_status(str(payload.get("default_status") or "confirmed")),
        entries=entries,
        path=path,
    )


def load_preset_bundle(path: Path) -> MemoryPresetLoadResult:
    if not path.exists():
        return MemoryPresetLoadResult(bundle=None, error=f"preset file not found: {path}")
    try:
        payload = read_json(path)
    except Exception as exc:  # noqa: BLE001 - surfaced to caller as load error
        return MemoryPresetLoadResult(bundle=None, error=f"invalid preset JSON {path.name}: {exc}")
    if not isinstance(payload, dict):
        return MemoryPresetLoadResult(bundle=None, error=f"preset {path.name} must be a JSON object")
    bundle = _bundle_from_payload(payload, fallback_id=_bundle_id_from_path(path), path=path)
    return MemoryPresetLoadResult(bundle=bundle, error="")


def discover_preset_bundles(root_dir: Path) -> list[MemoryPresetBundle]:
    base = presets_dir(root_dir)
    if not base.exists():
        return []
    bundles: list[MemoryPresetBundle] = []
    for path in sorted(base.glob("*.json")):
        result = load_preset_bundle(path)
        if result.bundle is not None:
            bundles.append(result.bundle)
    return bundles


def _normalize_pair(source_lang: str, target_lang: str) -> str:
    return f"{(source_lang or '').strip().lower()}->{(target_lang or '').strip().lower()}"


def _scope_pair_match(scope: MemoryPresetScope, *, source_lang: str, target_lang: str) -> bool:
    if not scope.language_pairs:
        return True
    pair = _normalize_pair(source_lang, target_lang)
    src_only = (source_lang or "").strip().lower()
    for declared in scope.language_pairs:
        normalized = declared.strip().lower()
        if normalized in {pair, "*", "*->*", f"{src_only}->*"}:
            return True
    return False


def scope_matches(
    bundle: MemoryPresetBundle,
    *,
    source_lang: str,
    target_lang: str,
) -> bool:
    return _scope_pair_match(bundle.scope, source_lang=source_lang, target_lang=target_lang)


def _preset_entry_id(preset_id: str, source: str, category: str) -> str:
    digest = hashlib.sha1(f"{preset_id}:{category}:{source}".encode("utf-8")).hexdigest()[:10]
    return f"mem_p_{digest}"


def _resolve_status(entry_status: str, bundle_default: str, override: str) -> str:
    chain = [override, entry_status, bundle_default, "proposed"]
    for candidate in chain:
        normalized = (candidate or "").strip().lower()
        if normalized in MEMORY_STATUS_ORDER:
            return normalized
    return "proposed"


def materialize_entries(
    bundle: MemoryPresetBundle,
    *,
    override_status: str = "",
) -> list[MemoryEntry]:
    out: list[MemoryEntry] = []
    for entry in bundle.entries:
        if not entry.source.strip() or not entry.target.strip():
            continue
        status = _resolve_status(entry.status, bundle.default_status, override_status)
        materialized = replace(
            entry,
            id=entry.id or _preset_entry_id(bundle.id, entry.source, entry.category),
            status=status,
            origin=entry.origin or "preset",
            source_preset=bundle.id,
            created_by=entry.created_by or "preset",
        )
        out.append(materialized)
    return out


@dataclass
class MemoryBootstrapReport:
    applied: list[dict[str, Any]] = field(default_factory=list)
    skipped: list[dict[str, Any]] = field(default_factory=list)
    errors: list[dict[str, Any]] = field(default_factory=list)
    entries: int = 0


def _preset_file_hash(path: Path) -> str:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return f"sha256:{digest}"


def _snapshot_payload(
    *,
    source_lang: str,
    target_lang: str,
    report: MemoryBootstrapReport,
    entries: list[MemoryEntry],
) -> dict[str, Any]:
    return {
        "version": 1,
        "created_at": utc_now_iso(),
        "source_lang": source_lang,
        "target_lang": target_lang,
        "report": to_plain(report),
        "entries": [to_plain(entry) for entry in entries],
    }


def build_selected_presets_snapshot(
    *,
    presets: list[MemoryPresetRef],
    root_dir: Path,
    source_lang: str,
    target_lang: str,
) -> dict[str, Any]:
    report = MemoryBootstrapReport()
    base = presets_dir(root_dir)
    seen: dict[str, str] = {}
    entries: list[MemoryEntry] = []
    for ref in presets:
        ref_id = ref.id.strip()
        if not ref_id:
            continue
        path = base / f"{ref_id}.json"
        result = load_preset_bundle(path)
        if result.bundle is None:
            report.errors.append({"preset": ref_id, "reason": result.error or "load_failed"})
            raise MemoryPresetError(f"memory preset '{ref_id}' failed to load: {result.error or 'load_failed'}")
        bundle = result.bundle
        if not scope_matches(bundle, source_lang=source_lang, target_lang=target_lang):
            report.skipped.append(
                {
                    "preset": bundle.id,
                    "reason": "scope_mismatch",
                    "language_pairs": bundle.scope.language_pairs,
                    "task_pair": _normalize_pair(source_lang, target_lang),
                }
            )
            continue
        materialized = materialize_entries(bundle, override_status=ref.override_status)
        added = 0
        for entry in materialized:
            key = normalize_source_key(entry.source)
            owner = seen.get(key)
            if owner is not None:
                report.errors.append(
                    {
                        "preset": bundle.id,
                        "reason": "duplicate_source",
                        "source": entry.source,
                        "owned_by": owner,
                    }
                )
                continue
            seen[key] = bundle.id
            entries.append(entry)
            added += 1
        report.applied.append(
            {
                "preset": bundle.id,
                "id": bundle.id,
                "version": bundle.version,
                "hash": _preset_file_hash(path),
                "entries": added,
                "default_status": bundle.default_status,
                "override_status": ref.override_status,
            }
        )
    report.entries = len(entries)
    return _snapshot_payload(
        source_lang=source_lang,
        target_lang=target_lang,
        report=report,
        entries=entries,
    )

