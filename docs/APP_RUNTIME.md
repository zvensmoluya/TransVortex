# 主 Local Service runtime 构建与分发

## 产品边界

Windows Release 使用应用自带的固定 Python runtime 启动 TransVortex Local Service，不要求用户安装 Python，也不读取用户 Python 的 `site-packages`。这套主 runtime 只包含 TransVortex 后端、`httpx`、PyYAML 及其固定依赖，不包含 FFmpeg、faster-whisper、CTranslate2、模型或 CUDA。

主 runtime 与本机 Whisper runtime 是两套独立组件：

- 主 runtime 随基础发布包提供，负责配置、翻译、任务管理、导出和 Worker。
- Whisper runtime、模型和 NVIDIA 加速组件由用户在语音识别设置中按需下载。

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

## Flutter 启动规则

安装态应用根目录同时存在 `runtime/app_runtime.json` 和 `runtime/python/python.exe` 时，Flutter 只启动该解释器，并以空 `PYTHONPATH` 和禁用用户 site-packages 的方式运行：

```text
runtime\python\python.exe -m transvortex.app_service ...
```

仓库开发态没有这套 runtime 时，Flutter 继续使用仓库 `src/` 和显式或系统 Python，保持 `flutter run` 与测试工作流可用。Portable 包不再复制 `src/` 或依赖 `PYTHONPATH`。

## 发布包验证

使用 `-Build` 会同时重建 Flutter Release 和主 runtime，再生成 Portable 包：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_flutter_release.ps1 `
  -Build -OutputRoot "$env:TEMP\transvortex-release" `
  -PackageName TransVortex-portable-test -Force -LaunchCheck
```

只需要重建 runtime 而复用现有 Flutter Release 时，可以给打包脚本传入 `-BuildAppRuntime`。不带两个构建开关时，脚本复用 `dist/app-runtime/windows-x64` 中的现有产物。打包和用户级安装检查都会直接调用包内 `python.exe`，校验 `service.info` 返回的应用版本及协议版本与 runtime 清单一致。

该路径已消除系统 Python 依赖，但仍是 Portable 分发验证，不是正式 MSIX/MSI/NSIS/Inno 安装器。目前基础包仍不包含 FFmpeg，也尚未覆盖正式升级、卸载、签名和干净 Windows 环境验收。
