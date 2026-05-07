# TransVortex

TransVortex is a CLI-first pipeline for generating subtitles from local videos with:
- streaming/chunked processing (no whole-video memory load),
- local faster-whisper or cloud OpenAI Whisper ASR,
- configurable translation providers/models/base URLs,
- resumable tasks and artifacts,
- an optional Tauri desktop workbench for local configuration and progress viewing.

## Quick Start
1. Install dependencies:
   - `pip install -e .`
   - optional ASR: `pip install -e .[asr]`
2. Ensure `ffmpeg` and `ffprobe` are available in `PATH`.
3. Put real provider config in `providers.local.yaml` (gitignored), and set API keys using the configured `env_key`.
   - The default translation provider uses `TVX_MODEL_API_KEY`.
   - You can also put keys in `.env` (auto-loaded, does not override existing environment variables).
4. Probe provider compatibility first (zero-token local checks):
   - `transvortex probe-provider --strict`
5. Run:
   - `transvortex run --input demo.mp4 --src en --tgt zh-CN`
6. One-command demo run:
   - `.\scripts\run_demo.ps1 -ApiKey "<your-key>"`

## Cloud ASR (OpenAI Whisper)
Set `pipeline.yaml`:

```yaml
asr:
  mode: openai
  provider: openai_asr
  model: whisper-1
  cloud:
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: OPENAI_API_KEY
    timeout_seconds: 120
```

Add a provider entry in `providers.local.yaml`:

```yaml
providers:
  - name: openai_asr
    api_type: openai-compatible
    compat_mode: openai_chat
    base_url: https://api.openai.com
    env_key: OPENAI_API_KEY
    models: [whisper-1]
    auth:
      type: bearer
      header_name: Authorization
      prefix: "Bearer "
    endpoint:
      path_template: /v1/audio/transcriptions
      method: POST
```

Then set key (or put it in `.env`):

```powershell
$env:OPENAI_API_KEY = "sk-..."
```

## Commands
- `transvortex run --input <video> --src <lang> --tgt <lang> [--bilingual] [--output <path>] [--json] [--stream-events]`
- `transvortex resume --task-id <id> [--json] [--stream-events]`
- `transvortex status --task-id <id> [--json]`
- `transvortex events --task-id <id>`
- `transvortex cancel --task-id <id> [--json]`
- `transvortex tasks [--json]`
- `transvortex config show [--json]`
- `transvortex probe-provider [--provider <name>] [--model <name>] [--strict]`

Common runtime overrides are available on `run` and `resume`: `--provider`, `--model`, `--asr-mode`, `--asr-device`, `--asr-model-size`, `--asr-compute-type`, `--asr-provider`, `--asr-model`, chunk settings, batch size, and concurrency.

## Translation Design
The translator uses numbered subtitle chunks and validates model output before applying translations back to the original timeline. Translation strategy lives in `pipeline.yaml`, while `providers.yaml` only describes provider protocol, routing, and capability limits.

```yaml
translation:
  chunk_lines: 40
  context_before_lines: 20
  context_after_lines: 10
  style_preset: subtitle_natural
  style_prompt: |
    Translate as natural subtitles.
    Preserve tone, jokes, profanity, and adult references faithfully.
    Do not censor, explain, or add content.
  refusal_detection:
    enabled: true
  repair:
    enabled: true
    max_attempts: 2
```

Each task writes validated translation artifacts under `translate/`, including `segments.translated.jsonl`, `validation.jsonl`, and `repairs.jsonl`.

## Worker Protocol
Each task writes a stable artifact directory under `artifacts/<task_id>/`:

- `task.json` and `checkpoint.json`
- `events.jsonl`
- `media/`, `asr/`, `chunks/`, `translate/`, `final/`, `output/`

`events.jsonl` contains structured JSONL events for scripts, agents, and future desktop UI consumers.

## Desktop Workbench
The desktop app lives in `desktop/` and uses Tauri v2 + React + TypeScript + Vite. It is a development workbench, not a packaged installer yet.

Prerequisites:
- Node.js/npm
- Rust toolchain with `cargo`
- Python dependencies installed from the repo root
- `ffmpeg` and `ffprobe` in `PATH`

Run checks and build the frontend:

```powershell
cd desktop
npm install
npm run typecheck
npm run build
```

Run the desktop app after installing Rust:

```powershell
cd desktop
npm run tauri dev
```

The UI calls the same Python worker protocol as CLI/agents. It can save provider keys into the repo-local `.env`, but it never reads or displays secret values.
