# 主 Local Service runtime 构建与分发

## 产品边界

Windows Release 使用应用自带的固定 Python runtime 启动 TransVortex Local Service，不要求用户安装 Python，也不读取用户 Python 的 `site-packages`。这套主 runtime 只包含 TransVortex 后端、`httpx`、PyYAML 及其固定依赖；基础发布物另外携带独立的固定 FFmpeg 命令行工具，但不包含 faster-whisper、CTranslate2、模型或 CUDA。

主 runtime 与本机 Whisper runtime 是两套独立组件：

- 主 runtime 随基础发布包提供，负责配置、翻译、任务管理、导出和 Worker。
- Whisper runtime、模型和 NVIDIA 加速组件由用户在语音识别设置中按需下载。

FFmpeg 不是 Python 包，也不是本机 Whisper / NVIDIA 组件。它作为基础媒体能力随安装器放在 `tools/ffmpeg`，Local Service 以独立进程调用，不依赖系统 `PATH` 中的 FFmpeg。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_app_runtime.ps1 -Force -Json
```

脚本下载固定的 Windows x64 Embedded Python 并校验 SHA-256，按 `requirements/app-runtime.txt` 安装固定依赖，构建并安装当前 TransVortex wheel，再用产物自身验证版本和协议。默认输出到：

```text
dist\app-runtime\windows-x64\
  app_runtime.json
  python\
    python.exe
    Lib\site-packages\transvortex\
```

`app_runtime.json` 记录 Python 来源与哈希、TransVortex wheel 哈希、完整依赖版本、应用版本和 Local Service 协议版本。

固定 FFmpeg runtime 单独构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_ffmpeg_runtime.ps1 -Force -Json
```

脚本固定到 FFmpeg `8.1.2-21-gce3c09c101` 的 Windows x64 LGPL shared 构建，校验官方发布资产 SHA-256，拒绝启用 GPL / nonfree 的构建，并记录 `ffmpeg.exe`、`ffprobe.exe` 和所有 shared DLL 的哈希。默认输出到 `dist\ffmpeg-runtime\windows-x64`。`SOURCE_NOTICE.txt` 记录精确源码和构建脚本版本；公开分发前仍必须把完整对应源码放到与安装包配套的公开位置，并完成许可审查。

## Flutter 启动规则

安装态应用根目录同时存在 `runtime/app_runtime.json` 和 `runtime/python/python.exe` 时，Flutter 只启动该解释器，并以空 `PYTHONPATH` 和禁用用户 site-packages 的方式运行；存在 `tools/ffmpeg/ffmpeg_runtime.json` 时，还会把固定媒体工具目录显式传给 Local Service：

```text
runtime\python\python.exe -m transvortex.app_service ...
TRANSVORTEX_MEDIA_TOOLS_DIR=tools\ffmpeg\bin
```

仓库开发态没有这套 runtime 时，Flutter 继续使用仓库 `src/` 和显式或系统 Python，保持 `flutter run` 与测试工作流可用。Portable 包不再复制 `src/` 或依赖 `PYTHONPATH`。

桌面端首次启动使用仓库 `pipeline.desktop.yaml` 作为产品种子，并复制到用户级 `Config/pipeline.yaml`；仓库根 `pipeline.yaml` 只属于 CLI 和开发工作区。发布脚本同样只把 `pipeline.desktop.yaml` 打包为产品 `pipeline.yaml`，避免开发连接进入新用户默认配置。用户配置创建后不由种子文件覆盖。

## 发布包验证

使用 `-Build` 会同时重建 Flutter Release、主 runtime 和 FFmpeg runtime，再生成 Portable 包：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_flutter_release.ps1 `
  -Build -OutputRoot "$env:TEMP\transvortex-release" `
  -PackageName TransVortex-portable-test -Force -LaunchCheck
```

只需要重建某项 runtime 而复用现有 Flutter Release 时，可以传入 `-BuildAppRuntime` 或 `-BuildFfmpegRuntime`。不带构建开关时，脚本复用 `dist/app-runtime/windows-x64` 和 `dist/ffmpeg-runtime/windows-x64` 中的现有产物。打包和用户级安装检查会直接调用包内 `python.exe`、`ffmpeg.exe` 和 `ffprobe.exe`，并核对 runtime 清单与文件哈希。

NSIS 原生安装器使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1 -AllowUnsigned -Force
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\accept_windows_installer.ps1
```

`-AllowUnsigned` 只允许生成内部验收产物。当前自动验收已覆盖全新安装、固定 Local Service、清空媒体 `PATH` 后运行 bundled FFmpeg / FFprobe、升级清旧文件、运行中拒绝安装和卸载、AUMID 快捷方式、卸载注册及用户数据保留。终端用户运行安装器和已安装应用均不依赖 PowerShell。公开发布仍需 Authenticode 签名、FFmpeg 完整对应源码托管，以及干净 Windows 环境的首启和真实媒体任务验收。

安装器始终使用专用的 `TransVortex` 安装目录：如果用户选择的是其他父目录，会在其中创建 `TransVortex` 子目录；如果目标目录非空且没有有效的安装归属标记，安装器会拒绝覆盖。检测到已有安装时，升级必须沿用原安装路径；如需更换路径，应先卸载旧版本，避免遗留两套程序或误删无关文件。
