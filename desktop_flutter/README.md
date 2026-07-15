# TransVortex Desktop Flutter

`desktop_flutter/` 是 TransVortex 的主体验桌面前端。冻结的 Tauri 树只作参考，不是兼容目标。

## 当前窗口

- 主窗口：当前一次字幕制作。
- 翻译模型设置：连接、模型和常用 routing。
- 语音识别设置：本机 Whisper、OpenAI Whisper 和 FunASR。
- 任务处理：历史任务、事件、继续/取消、结果编辑和重新导出。
- 诊断：内部开发、测试和支持工具，不进入普通用户菜单。

关闭主窗口会收起产品窗口并驻留系统托盘，当前任务与 Local Service 继续运行。单击托盘图标或再次启动应用会恢复已有主窗口；需要真正结束进程时使用托盘菜单的“退出 TransVortex”。

产品与设计边界见 [`../docs/FRONTEND/README.md`](../docs/FRONTEND/README.md)。

## 开发

确保 Flutter Windows desktop 工具链已在 `PATH`：

```powershell
flutter doctor -v
Set-Location desktop_flutter
flutter pub get
flutter run -d windows
```

开发态使用仓库 Python 环境；安装态使用包内固定 Python 和 FFmpeg runtime。

## 验证

```powershell
flutter analyze
flutter test
flutter build windows
```

从仓库根运行 release 验证：

```powershell
.\scripts\build_brand_assets.ps1
.\scripts\smoke_flutter_release.ps1 -ScreenshotPath "$env:TEMP\transvortex-main.png"
.\scripts\smoke_flutter_release.ps1 -CheckNotifications -CheckAppIdentity
.\scripts\smoke_flutter_release.ps1 -MainPhase empty -CheckTray
.\scripts\smoke_flutter_release_matrix.ps1 -CheckDesktopComposite
.\scripts\accept_flutter_release_manual.ps1 -LaunchCheck
```

自动 smoke 验证真实 Local Service、任务提交、结果动作、窗口状态、托盘关闭/恢复、通知调用和布局回归，但不替代人工完整任务流程。

## 打包与安装

```powershell
.\scripts\build_app_runtime.ps1 -Force
.\scripts\build_ffmpeg_runtime.ps1 -Force
.\scripts\package_flutter_release.ps1 -Force -LaunchCheck
.\scripts\build_windows_installer.ps1 -AllowUnsigned -Force
.\scripts\accept_windows_installer.ps1
```

NSIS 是当前原生安装路径。基础包不携带本机 Whisper runtime、模型或 CUDA；这些由用户在应用里按需安装。

## 边界

- 不移植冻结 Tauri UI。
- 不让窗口直接启动 Worker 或持有业务权威状态。
- 不以 debug 画面、HTML mock 或静态预览替代 Windows release 验收。
- 不把内部诊断、协议字段和完整本地路径变成普通用户界面。
