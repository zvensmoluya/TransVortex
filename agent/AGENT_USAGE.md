# TransVortex Agent Usage

This document is for agents, scripts, and automation systems. Do not parse
human-formatted CLI output. Use JSON, JSONL events, and artifacts only.

## Discovery

For an installed Windows app, start from the stable locator instead of searching
`PATH` or guessing the program directory:

```text
%LOCALAPPDATA%\TransVortex\Agent\README.md
%LOCALAPPDATA%\TransVortex\Agent\current.json
```

Read `current.json` and execute its `capabilities_argv` as an argument array.
That response contains the current CLI prefix, commands, protocol, and versioned
document paths. In a source checkout, start at [`README.md`](README.md)
and use the active Python environment.

The examples below use `transvortex` only as readable shorthand. Do not assume
that command is globally installed. Start with:

```powershell
transvortex agent-info --json
transvortex asr setup-plan --json
transvortex doctor --json
transvortex probe-provider --strict
```

`agent-info --json`, `doctor --json`, `asr setup-plan --json`, and
`asr setup-verify --json --strict` must be treated as secret-free structured
metadata; still apply a field allowlist before forwarding third-party output.
CLI JSON and JSONL stdout is ASCII-safe JSON: non-ASCII text is represented with
JSON escapes and is restored by any conforming JSON parser, independent of the
active Windows console code page.
`doctor` reports local runtime/config health. `probe-provider` validates the
translation-provider URL, payload, and response mapping locally; it does not
send a network request. It is not an ASR route probe.

## ASR Environment Setup Contract

`asr setup-plan --json` emits the versioned, read-only
`transvortex.agent_setup` contract. It reports the active ASR route, pinned
runtime/model requirements, installed component state, safe credential metadata,
blocking items, and the exact verification command. It does not install assets,
write configuration, invoke `pip`, change a driver, or access the network. If a
route has not been confirmed, an Agent must keep `route` as `null` and return
ranked alternatives rather than guessing.
For a setup plan, `ok: true` means the contract was generated; it does not mean
the environment is usable. Use `ready: true`, `plan_status: "ready"`, and an
empty blocking list together before presenting the plan as ready.

The CLI `--root` value is the configuration/project root. For an installed
Windows desktop app, use `%LOCALAPPDATA%\TransVortex\Config` (or the explicit
`TRANSVORTEX_HOME` data root together with its `Config` directory); do not use
the program installation directory as the data root.
Execute the returned `agent_argv` or `plan.actions[].argv` arrays directly so
follow-up commands use the same resolved root and providers file; do not rebuild
them by concatenating an unquoted shell command.

After an explicitly approved plan has been applied through an advertised
TransVortex capability or the native desktop wizard, run:

```powershell
transvortex asr setup-verify --json --strict
```

Treat `ok: true` as the only successful environment result. The verify command
does not mutate TransVortex configuration or components and does not use the
network. For local workers it launches the selected runtime locally, loads the
model, and transcribes generated probe audio in addition to checking readiness,
managed markers, and managed model file SHA-256 values. When the catalog publishes
an archive SHA-256, the component marker records the install-time verified digest;
otherwise the missing archive check is reported in `hashes_not_checked`. The
installed marker and model hashes must still pass. A route-specific provider
probe is required in addition to this check for local-service or remote routes.
The contract marks this local worker execution as `executes_local_code: true`;
an Agent must never substitute an unadvertised executable.

For the one-time local workflow, read
[`workflows/ASR_ENVIRONMENT_SETUP.md`](workflows/ASR_ENVIRONMENT_SETUP.md).
If repeated use justifies a persistent integration, let the active Agent create
a thin adapter in its own skill, plugin, rules, or project-instructions format by
following [`ADAPTATION_GUIDE.md`](ADAPTATION_GUIDE.md). TransVortex
does not install a universal Agent skill. Web-only Agents should generate a
handoff and must not claim to have inspected or changed the local machine.

For a route-specific ASR probe, use the explicitly authorized command below
only after confirming network, privacy, and possible media/cost implications:

```powershell
transvortex asr provider-test --confirm-network --json
```

For a remote provider, also pass `--confirm-media --confirm-cost`. The command
may contact a local or remote ASR endpoint and writes only a non-secret probe
status record; it is separate from the offline setup-plan and setup-verify
commands.

## Recommended Full Pipeline

For long tasks, prefer detached execution:

```powershell
transvortex run --input video.mp4 --src en --tgt zh-CN --detach --json
```

The response contains `task_id`, `task_dir`, worker `pid`, worker log paths, and
recommended follow-up commands. It is a queued receipt, not a terminal task
result; `terminal: false` means the agent must stream events or poll status.
Then stream task events:

```powershell
transvortex events --task-id <task_id> --follow
transvortex status --task-id <task_id> --json
transvortex result open --task-id <task_id> --json
```

For foreground execution, use:

```powershell
transvortex run --input video.mp4 --src en --tgt zh-CN --stream-events
```

`--stream-events` writes only JSONL events to stdout.

## Capability Commands

Use these when an agent needs part of the pipeline:

```powershell
transvortex asr --input video.mp4 --src en --detach --json
transvortex translate --segments source/segments.normalized.jsonl --src en --tgt zh-CN --detach --json
transvortex export --segments segments.final.json --format both --output subtitles --json
```

`asr` emits normalized source segments under `source/segments.normalized.jsonl`. `translate` accepts a
segments JSONL file or SRT and emits translated/final artifacts. `export` writes
SRT/ASS/VTT from final segments and reports delivery checks in JSON output or
`quality/subtitle_delivery.json` when run through a task.

## Events

Events are JSONL objects. Stable fields:

- `type`
- `task_id`
- `created_at`
- `level`
- `message`
- optional `stage`
- optional `progress`
- optional `details`

Terminal event types are `done`, `error`, and `cancelled`.

## Artifacts

Each task directory has a stable layout:

```text
task.json
checkpoint.json
events.jsonl
media/
source/segments.normalized.jsonl
chunks/chunks.json
translate/segments.translated.jsonl
translate/validation.jsonl
translate/repairs.jsonl
final/segments.final.json
output/*.srt
output/*.ass
```

Use paths returned by `status --json`, detached task responses, or events. Do
not infer paths outside the task directory.

## Errors

Task records and error events may include `error_info`:

```json
{
  "code": "missing_env",
  "type": "config_error",
  "stage": "PRECHECK",
  "message": "Missing environment variable: TVX_MODEL_API_KEY",
  "hint_zh": "缺少必要环境变量，请在 .env、系统环境变量或桌面端配置 key。",
  "retryable": false,
  "details": {}
}
```

On `--json` commands, failures return one JSON object and a non-zero exit code.
On `--stream-events`, failures are emitted as JSONL `error` events.

## Rules For Agents

- Never parse human text output.
- Prefer `--detach --json` for long tasks.
- Use `events --follow` for progress and terminal state.
- Use `status --json` and `result open --json` for final state and editable
  segments.
- Use `cancel --task-id <task_id> --json` to request cancellation.
- Do not expect API keys or secret values in any JSON output.
