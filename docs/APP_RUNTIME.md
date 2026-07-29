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

发布构建使用仓库 `pipeline.desktop.yaml` 和 `providers.desktop.yaml` 作为产品种子，分别打包为 `pipeline.yaml` 和 `providers.yaml`；其中 Provider 种子不包含任何连接。安装态 Flutter 首次启动再把包内产品配置同步到用户级 `Config/`。仓库根 `pipeline.yaml` / `providers.yaml` 只属于 CLI 和开发工作区，`providers.example.yaml` 只展示中性配置结构，避免开发连接或示例服务进入新用户默认配置。用户保存连接后会生成本地覆盖文件，不再由产品种子覆盖。

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

`-AllowUnsigned` 只允许生成内部验收产物。当前自动验收已覆盖全新安装、固定 Local Service、清空媒体 `PATH` 后运行 bundled FFmpeg / FFprobe、升级清旧文件、运行中拒绝安装和卸载、AUMID 快捷方式、卸载注册、静默卸载默认保留数据，以及安装包内 runtime 的分项清理能力。终端用户运行安装器和已安装应用均不依赖 PowerShell。公开发布仍需 Authenticode 签名、FFmpeg 完整对应源码托管，以及干净 Windows 环境的首启和真实媒体任务验收。

全新安装把用户选择的位置整理为一个专用产品根，并建立 `App`、`Data`、`Resources` 三个相互隔离的子目录。默认布局是 `%LOCALAPPDATA%\Programs\TransVortex\App`、`Data` 和 `Resources`；选择其他磁盘时三者一起跟随到所选位置。升级的 staging、旧版本回滚和卸载程序删除边界都只落在 `App`，不会覆盖 `Data` 或 `Resources`。确认页面直接展示程序、工作数据和识别资源的最终路径，其中工作数据仍可单独更改；配置和凭据固定在 Windows 用户目录。

版本化 Agent 资料位于 `<InstallRoot>\agent`。正式 NSIS 安装在程序替换、配置和快捷方式全部成功后，原子写入 `%LOCALAPPDATA%\TransVortex\Agent\README.md` 与 `current.json`；后者只包含当前安装根、配置根、文档路径和可直接执行的 CLI `argv` 数组，不含凭据。升级重写这两个定位文件，Local Service 启动时也会在有效安装标记存在时自修复。卸载只删除这两个自有文件并尝试移除空目录，不递归删除 Agent 目录中的其他内容。便携包不登记该用户级入口。

桌面端把本机 Codex CLI 作为首个默认 Agent 客户端，但它仍是用户独立安装和登录的外部程序。直接交接时，Local Service 在 `<WorkspaceRoot>\Cache\AgentHandoffs\<handoff-id>` 创建 `handoff.md` 与 `handoff.json`，再以该目录作为 `codex -C` 的工作区启动可见交互会话；启动参数不包含 Full Access、`--yolo` 或审批覆盖。状态文件只记录范围、客户端路径、版本、进程和生命周期，不复制配置、模型、凭据或其他产品目录。已结束的自有交接保留七天后按需清理；普通缓存清理可以立即删除已结束交接，但保留仍在运行的目录，活动交接结束前也不允许迁移工作数据。

目标 `App` 非空且没有有效安装归属标记时，安装器拒绝覆盖。检测到注册表中的已有安装时，升级继续使用原程序、工作区和识别资源位置，不借升级之机把旧版 `TransVortex` / `TransVortexData` / `TransVortexResources` 布局搬进新层级；如需更换程序路径，应先卸载旧版本。检测到已有任务或缓存时也沿用原工作区，安装后可在“应用设置 → 工作数据”中查看占用、清理缓存或安全迁移。卸载程序但保留任务后，重新安装只在保留的 `WorkspaceLocation`、`TransVortex\Data` 路径形状和工作区所有权标记内容同时匹配时恢复原产品根；同名目录本身不构成复用依据。

安装器与卸载器使用和 Flutter 一致的瓷白、柔墨、草莓粉及浅青品牌资产。公开界面隐藏逐文件 DLL 与 staging 路径，只显示准备目录、安装运行环境、校验内容和创建入口等产品阶段；失败信息仍保留具体恢复原因。欢迎图与顶部图由 `scripts/build_brand_assets.ps1` 从仓库内 SVG 确定性生成，不引入另一套图标或插画语言。

## 卸载与本地内容

交互卸载在移除程序前提供四类独立选择：

- TransVortex 下载的语音识别 runtime、模型和断点缓存：检测到内容时默认勾选，并显示估算大小与当前资源位置。
- 应用设置与识别登记状态：默认保留。
- 任务工作区与恢复缓存：默认保留，选择删除时再次确认不可恢复。
- 用户级 `~/.transvortex/auth.json` 凭据：默认保留；选择删除后，重新安装应用时需要重新配置服务凭据。

Agent / CLI 定位文件属于已安装程序入口，不属于用户设置；卸载时始终移除，但不会触碰任何 Agent 自己的 skill、plugin、rules 或项目说明。

卸载器先读取 `Config/asr_storage.json` 和 `Config/workspace_storage.json`，再处理配置删除，因此可以找到独立的 ASR 资源位置和工作数据位置。保留识别资源时，即使用户选择删除其他应用设置，也会保留识别资源位置登记及重新安装恢复提示，避免保留下来的大文件失去索引；只有同时删除识别资源和应用设置时才一并清理该提示。自选工作区还必须带有安装器写入的 `.transvortex-workspace.json` 归属标记，卸载器才会清理其中的 `Tasks` 和 `Cache`。它不会删除用户选择的根目录中的其他文件、原地使用的外部模型、原始媒体或已导出的字幕。配置损坏或归属标记缺失时只检查安全的默认位置并给出残留提示，不扩大删除范围。保留任务时同时保留工作区位置登记，重新安装后仍能找到原任务。

静默卸载 `/S` 继续默认保留全部用户数据，自动化只有显式传入 `/REMOVEASR`、`/REMOVESETTINGS`、`/REMOVETASKS` 或 `/REMOVECREDENTIALS` 才执行相应清理。清理失败不阻止程序文件卸载，但返回退出码 `20` 并在交互模式中显示残留原因。该策略把“移除可重新下载资源”“重置应用”“删除工作成果”和“删除共享凭据”保持为不同产品概念，不使用一个含义含混的“删除所有用户数据”。

## 内部安装路径验收现状

2026-07-18 的本机内部验收使用当前 NSIS 产物完成全新安装、升级、运行中保护、AUMID 快捷方式、卸载和用户数据保留检查。在另一个保留的隔离安装目录中，包内 `runtime/python/python.exe` 也已完成受管 Whisper runtime、NVIDIA 组件和 `large-v3` 模型的校验安装，并通过 `managed + stdio_jsonl + cuda + int8_float16` 最小转录。该过程没有使用工作区 Python。

同一隔离安装目录随后启动了可见 Flutter APP，并完成一条确实需要 ASR 的真实媒体任务。机器报告固定了 `DONE` 任务与 checkpoint、正常退出的 Python Worker、23 条 `managed + stdio_jsonl + cuda + int8_float16` 识别行，以及非空 SRT / ASS；人工操作覆盖运行态、独立任务处理窗审看和重新导出。无活动 Worker 后静默卸载返回 0，程序目录删除，隔离任务与报告保留。因此“本机内部安装路径真实任务”已经闭环。

该结论不覆盖干净 Windows、通知聚焦、公开组件下载、Authenticode 和 FFmpeg 对应源码托管；这些仍是独立发布边界。当次证据见 [`archive/e2e-reports/2026-07-18-managed-asr-installed-app-e2e.md`](archive/e2e-reports/2026-07-18-managed-asr-installed-app-e2e.md)。
