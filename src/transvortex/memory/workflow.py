from __future__ import annotations

from ..app.models import MemoryConfig


WORKFLOWS = {"off", "preset_only", "auto_bootstrap", "draft_only", "experimental_dynamic"}


def memory_workflow(memory: MemoryConfig) -> str:
    workflow = str(memory.workflow or "auto_bootstrap").strip()
    if workflow not in WORKFLOWS:
        raise ValueError(f"Unsupported memory workflow: {workflow}")
    return workflow


def memory_enabled(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) != "off"


def uses_presets(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) in {"preset_only", "auto_bootstrap", "draft_only", "experimental_dynamic"}


def uses_runtime_memory(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) in {"auto_bootstrap", "experimental_dynamic"}


def runs_bootstrap(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) in {"auto_bootstrap", "draft_only"} and bool(memory.bootstrap.enabled)


def translates_with_memory(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) in {"preset_only", "auto_bootstrap", "experimental_dynamic"}


def draft_only(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) == "draft_only"


def dynamic_updates_enabled(memory: MemoryConfig) -> bool:
    return memory_workflow(memory) == "experimental_dynamic"


def effective_memory_sources(memory: MemoryConfig) -> tuple[str, ...]:
    workflow = memory_workflow(memory)
    if workflow == "preset_only":
        return ("presets",)
    if workflow == "auto_bootstrap":
        return ("presets", "runtime")
    if workflow == "experimental_dynamic":
        return ("presets", "runtime")
    return ()
