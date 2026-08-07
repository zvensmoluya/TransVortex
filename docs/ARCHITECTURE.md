# TransVortex Backend Architecture

This document defines the backend layout and ownership boundaries. Root-level
module files are not used as compatibility shims; code should import from the
owning package directly.

## Runtime Shape

TransVortex is an agent-callable headless worker with CLI/agent and desktop entry points:

- CLI and agent commands call the Python worker directly.
- Registered Windows installs expose a stable, secret-free Agent locator under
  `%LOCALAPPDATA%\TransVortex\Agent`; it points to versioned docs and exact CLI
  argv arrays without modifying any Agent-native extension directory.
- The Flutter desktop app starts the packaged Python Local Service and uses its
  typed JSON-RPC contract to manage workers, tasks, and results.
- The Flutter app is the only product desktop frontend.
- Artifacts and task records are the stable contract between core, CLI, agents,
  and desktop UI.

Business logic must stay in Python core modules. Desktop host code should only
own application lifecycle, windows, system integration, process supervision,
and typed service transport.

The desktop App direction is now documented separately in
`docs/DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`. That document defines the
target Local Service / App Host / Worker process model for the Flutter desktop
client, including tray-oriented lifecycle, multi-window boundaries, and the
service integration milestone.

## Package Layers

```text
transvortex/
  app/          config, shared domain models, Local Service, runtime administration
  protocol/     agent protocol, structured errors, redaction, safe output contracts
  artifacts/    task store, checkpoints, events, result workspace
  core/         pipeline entry points, ASR planning/execution, stage controllers
  memory/       persistent collections, task snapshots, runtime memory, consistency
  prompts/      owned prompt assets and prompt assembly
  formats/      subtitle parsing, renderers, and delivery presentation
  providers/    model/provider protocol adapters and provider management
  cli/          parser, commands, detach/output helpers
  experiments/  explicit development experiments; never a product runtime dependency
```

## Current Ownership

`app/` owns:

- `config.py`
- `models.py`
- `doctor.py`

`protocol/` owns:

- `agent_protocol.py`
- `errors.py`
- `redaction.py`

`artifacts/` owns:

- `task_store.py`
- `result_workspace.py`

`core/` owns:

- `orchestrator.py`: stable task/run/resume entry points, stage order, unified
  cancellation/failure handling, and successful-task cache cleanup.
- `pipeline_stages.py`: PRECHECK, INGEST/ASR, MEMORY, SEGMENT/TRANSLATE,
  ALIGN/QUALITY, and EXPORT controllers. It receives runtime-replaceable
  operations explicitly and does not import `orchestrator.py`.
- `pipeline_runtime.py`: cancellation and shared artifact-validity helpers.
- `asr_planning.py`: resolved plan identity, portable manifests, persisted
  plan validation, capability limits, and artifact references.
- `asr_execution.py`: ASR preprocessing, usage accounting, retry plans,
  serial/concurrent execution, adaptive concurrency, and split retry.
- `source_pipeline.py`: authoritative source-segment artifacts, cleanup, and
  ASR boundary-quality annotations.
- `translation_pipeline.py`: chunk sizing, validation ledger/backfill,
  progress accounting, and translation experiment artifacts.
- `delivery_planning.py`: output-format normalization and task output paths.
- `asr.py`, `media.py`, `chunking.py`, `translate.py`, `aligner.py`,
  `subtitle_quality.py`, `subtitle_optimizer.py`, `subtitle_compression.py`,
  `subtitle_reflow.py`, and `translation_validation.py`: focused domain
  implementations called by the stage controllers.

`orchestrator.py` remains the supported import surface for pipeline lifecycle
entry points. Internal code should import planning, execution, source,
translation, or delivery helpers from their owning module. Thin private
wrappers remain only where tests and experiments replace runtime operations;
new modules must not depend back on the orchestrator facade.

`memory/` owns independent persistent collections, immutable task selection
snapshots, runtime memory documents, preset compatibility, bootstrap,
effective-source planning, and consistency checks. A persistent collection is
not owned by a task or a work entity; tasks reference collections and freeze
their revisions before translation. `prompts/` owns prompt assets and assembly;
neither belongs to provider transport or Flutter state.

`formats/` owns:

- `srt.py`
- `exporter.py`
- `presentation.py`

`formats/presentation.py` is the subtitle delivery and presentation boundary.
It reads structured `Segment` objects and decides renderer-facing layout,
style presets, font candidate notes, safe-area metadata, and delivery quality
checks. ASS itself only names one active font; actual glyph fallback is left to
the player and operating system. It must not run ASR, translate text, repair prompts, update memory, or
use SRT as an intermediate representation for ASS/VTT.

`providers/` owns:

- `base.py`
- `factory.py`
- `admin.py`
- `probe.py`

`cli/` owns:

- `entry.py`
- `__main__.py`

Do not add root-level compatibility shims for migrated modules before release.
Use the owning packages directly.

## Import Rules

New code should import from the owning layer:

```python
from transvortex.protocol.errors import PipelineTaskError
from transvortex.protocol.redaction import redact
from transvortex.artifacts.task_store import TaskStore
from transvortex.core.orchestrator import run_pipeline
from transvortex.formats.srt import read_srt
from transvortex.providers.probe import probe_provider
```

Do not add deprecation warnings or human diagnostics to CLI and agent stdout.
Machine-readable stdout must remain stable.

## Migration Rules

- Prefer small, behavior-preserving moves.
- Do not mix directory migration with business-logic rewrites.
- Do not change CLI commands, JSON/JSONL schemas, task artifact paths, or desktop
  process contracts during layout-only refactors.
- Update internal imports to the new owning layer when a module is migrated.
- Keep tests passing after each migration step.

## Future Work

Recommended next refactors, each as a separate change:

- Split `cli/entry.py` into parser, command handlers, detach, and output
  helpers.
- Continue reducing cross-package dependency cycles when a concrete M1 change
  touches them; do not duplicate config, credential, DTO, or error logic to
  make the graph look cleaner.
- Introduce explicit protocol DTOs when JSON/JSONL schemas grow beyond the
  current helper functions.
- Add richer subtitle preview/burn-in helpers under `formats/` without
  changing ASR, translation, prompt, memory, or timing ownership.
