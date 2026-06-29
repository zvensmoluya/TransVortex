from __future__ import annotations

from dataclasses import dataclass

from ..app.models import MemoryConfig


@dataclass(frozen=True)
class MemoryPlan:
    enabled: bool
    uses_presets: bool
    runs_bootstrap: bool
    translates_with_memory: bool
    dynamic_updates_enabled: bool
    effective_sources: tuple[str, ...]


def resolve_memory_plan(memory: MemoryConfig) -> MemoryPlan:
    enabled = bool(memory.enabled)
    uses_presets = enabled and bool(memory.presets)
    translates = enabled and bool(memory.inject.enabled)
    sources: list[str] = []
    if translates and uses_presets:
        sources.append("presets")
    if translates:
        sources.append("runtime")
    return MemoryPlan(
        enabled=enabled,
        uses_presets=uses_presets,
        runs_bootstrap=enabled and bool(memory.bootstrap.enabled),
        translates_with_memory=translates,
        dynamic_updates_enabled=enabled and bool(memory.patch.enabled),
        effective_sources=tuple(sources),
    )


def memory_enabled(memory: MemoryConfig) -> bool:
    return resolve_memory_plan(memory).enabled


def uses_presets(memory: MemoryConfig) -> bool:
    return resolve_memory_plan(memory).uses_presets


def runs_bootstrap(memory: MemoryConfig) -> bool:
    return resolve_memory_plan(memory).runs_bootstrap


def translates_with_memory(memory: MemoryConfig) -> bool:
    return resolve_memory_plan(memory).translates_with_memory


def dynamic_updates_enabled(memory: MemoryConfig) -> bool:
    return resolve_memory_plan(memory).dynamic_updates_enabled


def effective_memory_sources(memory: MemoryConfig) -> tuple[str, ...]:
    return resolve_memory_plan(memory).effective_sources
