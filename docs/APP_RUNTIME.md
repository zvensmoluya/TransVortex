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

脚本固定到 FFmpeg `8.1.2-31-g8c9502e9b0` 的 Windows x64 LGPL shared 构建，从 TransVortex 的版本化资产镜像下载并校验大小与 SHA-256，同时保留原始 BtbN 发布地址用于追溯。脚本拒绝启用 GPL / nonfree 的构建，并记录 `ffmpeg.exe`、`ffprobe.exe` 和所有 shared DLL 的哈希。默认输出到 `dist\ffmpeg-runtime\windows-x64`。

FFmpeg 源码追溯资产单独生成：

```powershell
pwsh -NoProfile -File scripts\build_ffmpeg_source_bundle.ps1 -Force -Json
```

该命令使用 `requirements/ffmpeg-runtime.json` 固定的 PowerShell 7.6.4、`SOURCE_NOTICE.txt` LF、JSON manifest CRLF、ZIP 压缩级别和 entry 时间戳，验证二进制、FFmpeg 源码和 BtbN 构建脚本输入，并要求生成 ZIP 的大小与 SHA-256 严格匹配统一 pin。源码资产的压缩字节会随 PowerShell/.NET 实现变化，因此这一项发布维护命令不使用 Windows PowerShell 5.1；普通 runtime、portable 和安装器构建仍可继续使用系统自带的 PowerShell 5.1。

当前源码 ZIP 只包含精确 FFmpeg 源码和 BtbN 构建控制脚本，清单保持 `public_distribution_ready=false`；它是源码追溯资产，不是完整对应源码。公开安装器分发前仍需补齐实际静态链接外部库的精确源码、许可证与通知，并完成许可审查。

### 无可选外部库的 FFmpeg core 候选

仓库同时提供一个不替换当前 release 的自建候选：

```powershell
pwsh -NoProfile -File scripts\build_ffmpeg_core_prototype.ps1 -Force -Json
```

该脚本使用 `requirements/ffmpeg-core-prototype.json` 固定 FFmpeg commit、BtbN Windows x64 基础镜像 digest、`SOURCE_DATE_EPOCH` 和 configure flags。它保留 FFmpeg 自带的 demuxer、decoder、encoder、muxer、parser、protocol 和 filter，只关闭可选依赖自动探测；不使用 `--disable-everything` 或逐组件极限裁剪。构建需要本机 Docker Desktop，但 Docker 镜像只属于维护者构建缓存，不进入安装包；不需要 `gh` 或 GitHub 登录。首次构建会下载数 GB 的交叉编译工具链，本机这次构建后 Docker 报告 8.236 GB 可回收 build cache；保留缓存可让后续重建直接复用，清理后下次需要重新下载。

2026-07-30 的本机 prototype 为 31,182,018 字节，当前固定完整 runtime 为 143,476,938 字节，减少 78.27%。自动兼容验证已覆盖带 H.264 视频、音频和文本字幕轨的 MP4 / MKV，以及 WAV、MP3、M4A、FLAC、AAC、Ogg Vorbis、Opus、AC3、EAC3 的探测、解码和 16 kHz 单声道 PCM 重采样；同时覆盖 AAC / MP3 直拷、AAC 音轨提取、`silencedetect` 和 SRT / ASS / SSA / WebVTT / mov_text 转 SRT。PE import 检查确认产物只依赖包内 FFmpeg DLL 与 Windows 系统 DLL。

该候选已经生成独立的正式资产 pin：

```powershell
pwsh -NoProfile -File scripts\build_ffmpeg_core_distribution.ps1 -Force -Json
```

`requirements/ffmpeg-core-runtime.json` 固定 binary/source 的 GitHub Release 目标、大小、SHA-256、PowerShell 7.6.4、ZIP 时间戳、原始 FFmpeg 源码、BtbN 构建脚本和 TransVortex 构建控制文件。适配新主线 provenance 和标准 runtime 后，二进制 ZIP 为 13,715,587 字节，SHA-256 为 `3bc9e9ecc1fb8273946ad41270e427c2fb34a9beed227a6cfedaaa5167cde5ca`；对应源码 ZIP 为 16,931,970 字节，SHA-256 为 `5b08f437fe0feb2cd66d5c88c0be89ea51ed52c62448fe42d5d11a5ae61bef25`。本机在两个独立输出目录重复生成后字节哈希一致，普通严格模式也已验证 pin。

标准 runtime builder 已能识别 `transvortex-core-v1`，验证候选归档内 manifest 和逐文件哈希，并保留构建、PE 导入、兼容性和许可证据。该 runtime 已通过 WAV、MP3、M4A、FLAC、AAC、Ogg/Vorbis、Opus、AC3、EAC3、H.264 MKV/MP4 和常见文本字幕的探测、提取、转换、重采样、切分、静音检测与字幕提取矩阵；本机 portable RC 的包内 Local Service、可见窗口启动和 FFmpeg 校验通过，unsigned internal NSIS installer 也已生成并校验 payload。

这个新 pin 仍是 `status=candidate`、`adopted=false` 和 `public_distribution_ready=false`。当前正式 `requirements/ffmpeg-runtime.json` 尚未切换，GitHub 目标资产也尚未上传；本机因已有 `D:\TransVortex\App` 安装记录，安全护栏没有执行会改写现有 HKCU 安装状态的全套 installer acceptance。下一步是发布两个不可变候选资产，在干净 Windows/用户环境完成最终 installer 与真实媒体 RC 验收，完成许可审查后再切换默认 pin。源码包的外部媒体库对应源码清单为空，并包含完整技术构建输入；这里的许可审查是发布记录确认，不代表还缺 43 个外部库的源码。

以后新增 FFmpeg 内建格式或 codec 通常不需要改构建开关；只有确实需要 `libopenh264`、`libvpx` 等外部实现时，才应逐项加入 allowlist，并同时固定源码、许可证、通知和回归样本。

发布维护者可在安装并登录 GitHub CLI 后验证或首次发布这两个固定资产：

```powershell
gh auth status
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\publish_ffmpeg_distribution.ps1 `
  -BuildManifest dist\ffmpeg-core-distribution\8.1.2-31-g8c9502e9b0\ffmpeg_core_distribution_build.json `
  -Json
```

发布脚本会再次把本地文件与统一 pin 比对。若 Release 已存在，只验证远端资产且不覆盖；若不存在，先创建 draft，上传并验证服务端 digest 后再公开。固定 URL 下的资产不允许通过 `-Force` 替换，内容变化必须使用新的 release tag 并更新 pin。`gh` 只属于发布机或 CI，不是本地构建、应用运行或终端用户依赖。

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
