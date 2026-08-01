# FFmpeg distribution compliance review

Review date: 2026-07-30

This is the technical open-source distribution review for the TransVortex
Windows x64 FFmpeg core. It records the evidence used by the release scripts;
it is not legal advice and does not assess codec patents in each jurisdiction.

## Reviewed build

- FFmpeg commit: `8c9502e9b048e21e1cae96477e338ac0635645ba`
- Variant: `transvortex-core-shared`
- License mode: `LGPL-3.0-or-later`
- Integration: TransVortex invokes `ffmpeg.exe` and `ffprobe.exe` as separate
  processes and does not link application code to the FFmpeg DLLs.
- Source changes: none. The build extracts the exact upstream commit archive
  and applies configure flags without patching FFmpeg source files.

## Evidence

The runtime and build controls satisfy the applicable parts of the FFmpeg
project's LGPL checklist:

- `ffmpeg -L` reports GNU Lesser General Public License version 3 or later.
- `ffmpeg -buildconf` records `--enable-version3`, `--enable-shared`,
  `--disable-static`, `--disable-autodetect`, `--disable-gpl`, and
  `--disable-nonfree`.
- The external media library allowlist is empty. PE import evidence contains
  only packaged FFmpeg DLLs and Windows system DLLs.
- The binary distribution includes FFmpeg's `LICENSE.md`, `COPYING.LGPLv3`,
  and `COPYING.GPLv3`. The latter is included because LGPLv3 incorporates and
  refers to the GPLv3 terms.
- The corresponding-source archive contains the exact FFmpeg source archive,
  the pinned build definitions, TransVortex build controls, license texts,
  rebuild instructions, and an explicit declaration that no source patch was
  applied.
- Binary and corresponding-source assets are published together under one
  release tag and are pinned by byte size and SHA-256.
- The build uses GCC's ordinary eligible compilation path. Toolchain runtime
  code covered by the GCC Runtime Library Exception may be conveyed with the
  generated target code; no proprietary GCC plugin or intermediate-code
  transformation is used.

Primary references:

- <https://ffmpeg.org/legal.html>
- <https://www.gnu.org/licenses/lgpl-3.0.html>
- <https://www.gnu.org/licenses/gcc-exception-3.1.en.html>

## Public release requirement

Every public TransVortex application download page must identify FFmpeg and
its `LGPL-3.0-or-later` license and provide a direct link to the corresponding
source asset pinned by `requirements/ffmpeg-runtime.json`. The packaged
`tools/ffmpeg/SOURCE_NOTICE.txt` and the FFmpeg Release page must retain the
same source coordinates.

Codec patent clearance, trademarks, privacy terms, optional Authenticode signing, and
installer acceptance are separate release decisions. Completing this review
does not set the application-level `public_release_ready` flag by itself.
