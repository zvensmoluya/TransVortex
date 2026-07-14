# TransVortex Desktop Flutter

This directory contains the main Flutter desktop frontend for TransVortex.

The old Tauri desktop tree is frozen as a reference implementation. Active
desktop delivery, release smoke checks, native notifications, and Local Service
wiring live here.

## Local SDK

The local Flutter SDK is installed outside the repository:

```powershell
$env:PATH = 'D:\openai\flutter-sdk\flutter\bin;' + $env:PATH
flutter --version
```

Current SDK:

- Flutter 3.44.4 stable
- Dart 3.12.2
- Windows desktop target enabled

`flutter doctor -v` confirms Visual Studio Build Tools 2022 is available at `D:\openai\vs-buildtools-2022`.
Android and Chrome targets are not required for the desktop workflow.

## Run

```powershell
$env:PATH = 'D:\openai\flutter-sdk\flutter\bin;' + $env:PATH
Set-Location desktop_flutter
flutter run -d windows
```

## Build

```powershell
$env:PATH = 'D:\openai\flutter-sdk\flutter\bin;' + $env:PATH
Set-Location desktop_flutter
flutter build windows --release
```

## Validation Scope

Current release validation focuses on proving the real desktop app path, not a
temporary validation path:

- Three-window model: main window, translation settings window, ASR settings window.
- Supporting tool windows: diagnostics, result review, task history, task detail.
- Cross-window state sync: settings changes update the main window immediately.
- Chinese IME behavior in Windows release builds.
- Python Local Service startup through JSON-RPC line-based stdin/stdout.
- Real task submission, cancellation, resume, result open, segment edit, and re-export.
- Windows Toast notification wiring, AUMID shortcut identity, and release bundle contents.
- Portable package layout: `TransVortex.exe` can find the fixed
  `runtime/python/python.exe`, and package-root Local Service RPC responds to
  `service.info`, `service.health`, `asr.status`, and `service.shutdown` without
  using a system Python or `PYTHONPATH`.
- Portable user-level install check: the packaged `Install-TransVortex.ps1` can
  copy the package to an install directory, create the AUMID shortcut, and rerun
  Local Service RPC from the installed layout. This is not a formal installer.

Useful checks from the repository root:

```powershell
flutter test
flutter build windows
.\scripts\smoke_flutter_release.ps1 -CheckNotifications -CheckAppIdentity
.\scripts\smoke_flutter_release_matrix.ps1 -SkipCompletedTask
.\scripts\build_app_runtime.ps1 -Force
.\scripts\package_flutter_release.ps1 -OutputRoot "$env:TEMP\transvortex-release" -PackageName TransVortex-portable-test -Force -LaunchCheck
.\scripts\install_flutter_portable_release.ps1 -SourceRoot "$env:TEMP\transvortex-release\TransVortex-portable-test" -InstallRoot "$env:TEMP\transvortex-installed" -ShortcutPath "$env:TEMP\TransVortex.lnk" -Force
.\scripts\accept_flutter_release_manual.ps1 -LaunchCheck
```

The smoke scripts intentionally report `frontend_design_mvp_complete=false`.
They prove wiring and release behavior; they do not replace full manual visible
end-to-end acceptance.

## Non-goals

- Do not port all existing Tauri UI code.
- Do not revive a second long-term desktop frontend.
- Do not use HTML mocks, static previews, or debug-only screenshots as release evidence.
- Do not introduce a broad shared protocol layer unless repeated payload problems appear.
