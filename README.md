# TransVortex

TransVortex is a CLI-first pipeline for generating subtitles from local videos with:
- streaming/chunked processing (no whole-video memory load),
- local faster-whisper or cloud OpenAI Whisper ASR,
- configurable translation providers/models/base URLs,
- resumable tasks and artifacts.

## Quick Start
1. Install dependencies:
   - `pip install -e .`
   - optional ASR: `pip install -e .[asr]`
2. Ensure `ffmpeg` and `ffprobe` are available in `PATH`.
3. Put real provider config in `providers.local.yaml` (gitignored), and set API keys using the configured `env_key`.
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
- `transvortex run --input <video> --src <lang> --tgt <lang> [--bilingual] [--output <path>]`
- `transvortex resume --task-id <id>`
- `transvortex status --task-id <id>`
- `transvortex probe-provider [--provider <name>] [--model <name>] [--strict]`
