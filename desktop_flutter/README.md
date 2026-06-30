# TransVortex Desktop Flutter

This directory contains the Flutter desktop frontend candidate for TransVortex.

It is currently in validation mode. It should not replace the existing Tauri frontend until the route-setting criteria are measured, but the directory and package names are intentionally stable so the code can become the main frontend without a path rename.

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
Android and Chrome targets are not required for this desktop validation.

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

The first implementation pass should stay small and answer only the route-setting questions:

- Three-window model: main window, translation settings window, ASR settings window.
- Cross-window state sync: settings changes should update the main window immediately.
- Chinese IME behavior in Windows release builds.
- Python JSON-RPC sidecar startup and line-based stdin/stdout calls.
- Subtitle review performance with 1000 editable rows.
- Release build sanity: app starts, windows open, sidecar path assumptions are visible.

Packaging and notification are important but should not block the first environment setup.

## Non-goals

- Do not rebuild the full TransVortex frontend here.
- Do not port all existing Tauri UI code.
- Do not create a second long-term frontend before the validation result is reviewed.
- Do not introduce a broad shared protocol layer unless repeated payload problems appear.
