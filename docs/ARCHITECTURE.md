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
  app/          config, shared domain models, environment diagnostics
  protocol/     agent protocol, structured errors, redaction, safe output contracts
  artifacts/    task store, checkpoints, events, result workspace
  core/         pipeline orchestration and pipeline stages
  formats/      subtitle parsing, renderers, and delivery presentation
  providers/    model/provider protocol adapters and provider management
  cli/          parser, commands, detach/output helpers
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

- `orchestrator.py`
- `asr.py`
- `media.py`
- `chunking.py`
- `translate.py`
- `aligner.py`
- `subtitle_quality.py`
- `subtitle_optimizer.py`
- `subtitle_compression.py`
- `translation_validation.py`

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
- Split `core/orchestrator.py` into smaller pipeline stage controllers.
- Introduce explicit protocol DTOs when JSON/JSONL schemas grow beyond the
  current helper functions.
- Add richer subtitle preview/burn-in helpers under `formats/` without
  changing ASR, translation, prompt, memory, or timing ownership.
