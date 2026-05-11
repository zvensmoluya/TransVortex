# TransVortex Backend Architecture

This document defines the backend layout and ownership boundaries. Root-level
module files remain only as compatibility shims for older imports.

## Runtime Shape

TransVortex is an agent-callable headless worker with multiple frontends:

- CLI and agent commands call the Python worker directly.
- The Tauri desktop app starts the same worker and consumes JSONL events.
- Artifacts and task records are the stable contract between core, CLI, agents,
  and desktop UI.

Business logic must stay in Python core modules. Desktop Rust commands should
only host processes, open files, and bridge events.

## Package Layers

```text
transvortex/
  app/          config, shared domain models, environment diagnostics
  protocol/     agent protocol, structured errors, redaction, safe output contracts
  artifacts/    task store, checkpoints, events, result workspace
  core/         pipeline orchestration and pipeline stages
  formats/      subtitle parsing and export formats
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
- `translation_validation.py`

`formats/` owns:

- `srt.py`
- `exporter.py`

`providers/` owns:

- `base.py`
- `factory.py`
- `admin.py`
- `probe.py`

`cli/` owns:

- `entry.py`
- `__main__.py`

Root-level modules with the same historical names are compatibility shims. They
must only alias the new owning modules and must not grow new behavior.

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

Old imports remain supported for compatibility:

```python
from transvortex.protocol.errors import PipelineTaskError
from transvortex.artifacts.task_store import TaskStore
from transvortex.core.orchestrator import run_pipeline
```

Do not add deprecation warnings to compatibility shims. CLI and agent stdout
must remain stable and machine-readable.

## Migration Rules

- Prefer small, behavior-preserving moves with compatibility shims.
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
- Add VTT or richer subtitle formats under `formats/` without touching core
  pipeline code.
