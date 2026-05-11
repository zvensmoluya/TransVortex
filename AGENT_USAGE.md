# TransVortex Agent Usage

This document is for agents, scripts, and automation systems. Do not parse
human-formatted CLI output. Use JSON, JSONL events, and artifacts only.

## Discovery

Start with:

```powershell
transvortex agent-info --json
transvortex doctor --json
transvortex probe-provider --strict
```

`agent-info --json` is static protocol metadata and must not contain secret
values. `doctor --json` reports local runtime/config health. `probe-provider`
performs zero-token provider protocol checks.

## Recommended Full Pipeline

For long tasks, prefer detached execution:

```powershell
transvortex run --input video.mp4 --src en --tgt zh-CN --detach --json
```

The response contains `task_id`, `task_dir`, worker `pid`, worker log paths, and
recommended follow-up commands. Then stream task events:

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
transvortex translate --segments segments.raw.jsonl --src en --tgt zh-CN --detach --json
transvortex export --segments segments.final.json --format both --output subtitles --json
```

`asr` emits source segments under `asr/segments.raw.jsonl`. `translate` accepts a
segments JSONL file or SRT and emits translated/final artifacts. `export` writes
SRT/ASS from final segments.

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
asr/segments.raw.jsonl
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
