# TransVortex Desktop

Local Tauri workbench for the TransVortex headless worker.

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
