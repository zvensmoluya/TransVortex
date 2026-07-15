# TransVortex Desktop

> **Frozen reference implementation.** 主体验前端是 `desktop_flutter/`。本目录不作为产品、设计、验收或后端兼容目标，完整边界见 [`FROZEN.md`](FROZEN.md)。

Local Tauri workbench retained for historical backend integration reference.

## Prerequisites

- Node.js/npm
- Rust toolchain with `cargo`
- Python package installed from the repo root: `python -m pip install -e .`
- Optional local ASR: `python -m pip install -e .[asr]`
- `ffmpeg` and `ffprobe` in `PATH`

The Rust host starts the Python worker with:

```powershell
python -m transvortex.cli --root <repo> run ... --stream-events
```

## Development

```powershell
cd desktop
npm install
npm run typecheck
npm run build
npm run tauri dev
```

Set `TRANSVORTEX_PYTHON` if the desktop app should use a specific Python executable.
