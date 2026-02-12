# TransVortex

TransVortex is a CLI-first pipeline for generating subtitles from local videos with:
- streaming/chunked processing (no whole-video memory load),
- faster-whisper ASR,
- configurable translation providers/models/base URLs,
- resumable tasks and artifacts.

## Quick Start
1. Install dependencies:
   - `pip install -e .`
   - optional ASR: `pip install -e .[asr]`
2. Ensure `ffmpeg` and `ffprobe` are available in `PATH`.
3. Set API keys in environment variables referenced by `providers.yaml`.
4. Run:
   - `transvortex run --input demo.mp4 --src en --tgt zh-CN`

## Commands
- `transvortex run --input <video> --src <lang> --tgt <lang> [--bilingual] [--output <path>]`
- `transvortex resume --task-id <id>`
- `transvortex status --task-id <id>`
