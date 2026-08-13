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
transvortex asr setup-plan --scope <scope> --json
transvortex probe-provider --strict
```

`agent-info --json`, `doctor --json`, `asr setup-plan --scope <scope> --json`, and
`asr setup-verify --scope <scope> --json` must be treated as secret-free structured
metadata; still apply a field allowlist before forwarding third-party output.
CLI JSON and JSONL stdout is ASCII-safe JSON: non-ASCII text is represented with
JSON escapes and is restored by any conforming JSON parser, independent of the
active Windows console code page.
`doctor` reports local runtime/config health. `probe-provider` validates the
translation-provider URL, payload, and response mapping locally; it does not
send a network request. It is not an ASR route probe.

## ASR Environment Setup Contract

`asr setup-plan --scope <scope> --json` emits version 2 of the read-only
`transvortex.agent_setup` contract. `provider_mode` describes where ASR runs;
`resources` separately describes runtime, model, accelerator, driver, and
configuration sources. `plan.actions[]` identifies the executor and ownership
for every preparation, apply, registration, activation, and verification step.
For a setup plan, `ok: true` means the contract was generated; it does not mean
the environment is usable. In a plan, `asr_ready` is the current readiness
snapshot. In `setup-verify`, it is the verified complete ASR result, while
`scope_result.complete` reports completion for the requested scope.
The plan's scope result is provisional and therefore never completes the task;
only the corresponding `setup-verify` result is a completion result.

Treat `current_configuration` only as an inspection baseline. The Agent owns the
model, CPU/CUDA, and managed/external selection after inspecting the host. Use
the pinned sizes and compatibility facts under `selection`; do not execute all
`role: "candidate"` actions in a `choice_group`. Read capacity from `storage`,
which represents the resolved ASR resource root, not the configuration volume.
For accelerator state, distinguish `configured`, `available`, and `active`.

The CLI `--root` value is the configuration/project root. For an installed
Windows desktop app, use `%LOCALAPPDATA%\TransVortex\Config` (or the explicit
`TRANSVORTEX_HOME` data root together with its `Config` directory); do not use
the program installation directory as the data root.
Execute the returned `agent_argv` or `plan.actions[].argv` arrays directly so
follow-up commands use the same resolved root and providers file; do not rebuild
them by concatenating an unquoted shell command.

For TransVortex-managed resources, use the advertised apply operation:

```powershell
transvortex asr setup-apply --resource runtime --json
transvortex asr setup-apply --resource model --item-id <model-id> --json
transvortex asr setup-apply --resource accelerator --item-id <accelerator-id> --json
```

An Agent may instead prepare external model or accelerator directories with its
own local tools. TransVortex probes and records those resources, then attaches
their registration IDs to the active local worker:

```powershell
transvortex asr model-probe --model-path <model-path> --json
transvortex asr model-register --model-path <model-path> [--label <display-name>] --json
transvortex asr accelerator-probe --accelerator-root <accelerator-root> --json
transvortex asr accelerator-register --accelerator-root <accelerator-root> --json
transvortex asr resources-activate --model-registration-id <id> --json
transvortex asr resources-activate --accelerator-registration-id <id> --json
```

The desktop local worker always uses the TransVortex-managed runtime. External
Python remains a CLI/development compatibility path; it is not something the
setup Agent should build for a normal desktop user. Model and accelerator
sources are independent, and external directories remain externally owned.

For complete local setup, run:

```powershell
transvortex asr setup-verify --scope full --json --strict
```

For `inspect`, `prepare_model`, `prepare_accelerator`, or `register`, run the
advertised `setup-verify --scope <scope> --json` command without `--strict` and
read `scope_result` separately from `asr_ready`. The Agent reports its host
inspection and recommendation directly in its conversation; TransVortex does
not consume a nested Agent result.

Treat `ok: true` as the complete ASR-ready result. The verify command
does not mutate TransVortex configuration or components and does not use the
network. The `inspect` scope uses a lightweight `scope_only` profile and does
not load a model or hash large model files. Other local-worker verification launches the selected runtime locally, loads the
model, and transcribes generated probe audio in addition to checking readiness,
managed markers, external registrations, and managed model file SHA-256 values. When the catalog publishes
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
transvortex asr engine-test --confirm-network --json
```

For a remote provider, also pass `--confirm-media --confirm-cost`. The command
may contact a local or remote ASR endpoint and writes only a non-secret probe
status record; it is separate from the offline setup-plan and setup-verify
commands.

For an already deployed FunASR service, `agent-info` advertises
`asr funasr-launcher-status`, `asr funasr-launcher-save`, and the confirmed
`asr funasr-launcher-remove`. Save a recipe only after verifying the exact
executable, argv array, working directory, and loopback health URL. This does
not authorize downloading, installing, upgrading, repairing, or replacing
FunASR, its models, Python, CUDA, or drivers. The desktop Local Service owns
starting and stopping a saved recipe.

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

## Persistent Memory Collections

Persistent collections are user-owned assets independent of works and tasks.
Task-generated runtime memory is not persistent by default. A task may select
one or more collections; TransVortex freezes their revisions into
`memory/selected_collections.json`, so later collection edits do not alter a
resume or an old result.

Read before writing:

```powershell
transvortex memory collections --json
transvortex memory collection-get --collection-id <collection-id> --json
transvortex memory resolve --collection-id <collection-id> --src ja --tgt zh-CN --json
```

Create or customize collections and entries:

```powershell
transvortex memory collection-create --name <name> --collection-id <id> --language-pair 'ja->zh-CN' --json
transvortex memory collection-update --collection-id <id> --expected-revision <revision> --json-payload '<changes-json>' --dry-run --json
transvortex memory entry-upsert --collection-id <id> --expected-revision <revision> --json-payload '<entry-json>' --dry-run --json
```

After inspecting the dry-run result, repeat without `--dry-run` using the same
expected revision. If the revision changed, read the collection again and
reconcile instead of overwriting it. Deletion additionally requires `--yes`.

Select collections for a new task with `--memory-collection <id[,id...]>`.
Promote only explicitly selected runtime candidates:

```powershell
transvortex result open --task-id <task-id> --json
transvortex memory promote --task-id <task-id> --collection-id <id> --entry-id <entry-id> --expected-revision <revision> --dry-run --json
```

Repeat `--entry-id` for multiple candidates. Inspect `applied`, `skipped`, and
`conflicts`, then repeat without `--dry-run` if authorized. Never infer that all
runtime candidates should be persisted. The `skip` conflict policy is the safe
default; use `replace` only when the user has authorized replacing an existing
target.

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
