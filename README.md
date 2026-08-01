# TransVortex

TransVortex 是本地优先的字幕制作工具，支持视频、音频和 SRT 输入，通过语音识别、翻译、质量处理和重新导出生成可审看的字幕结果。

当前主要形态：

- Windows Flutter 桌面应用，面向日常使用。
- CLI / Agent 接口，面向脚本、自动化和高级用户。
- 可恢复的 Python Worker，统一承载 ASR、翻译、质量和导出。

## 当前能力

- 受管本机 faster-whisper、FunASR 本地服务或 OpenAI Transcriptions 云端 ASR。
- 视频内嵌字幕自动检查；SRT 直译跳过 ASR。
- 可配置翻译 provider、模型、routing fallback 和容量感知分片。
- 术语记忆初始化、注入和运行中更新。
- 任务事件、checkpoint、取消、继续、结果编辑和重新导出。
- SRT、ASS、WebVTT 和 LRC 输出。
- 固定 Python / FFmpeg runtime 和 NSIS Windows 安装器。

产品与架构总览见 [`项目设计说明书.md`](项目设计说明书.md)，当前待办见 [`docs/CURRENT_BACKLOG.md`](docs/CURRENT_BACKLOG.md)。

## 开发环境

```powershell
python -m pip install -e .[test]
transvortex doctor
python -m pytest -q
```

开发态本机 ASR 需要额外安装：

```powershell
python -m pip install -e .[asr]
```

显式仓库 CLI 使用系统 `ffmpeg` / `ffprobe`。正式 Windows 安装包内置固定 Python 和 FFmpeg，不要求终端用户安装这些开发依赖。

## 配置与凭据

Provider 配置文件职责：

- `providers.example.yaml`：可提交的示例。
- `providers.desktop.yaml`：正式桌面的空连接种子。
- `providers.local.yaml`：本机真实配置，已忽略。
- `providers.yaml`：兼容默认配置。
- `pipeline.yaml`：ASR、翻译、术语记忆、质量和导出策略。

真实 key 默认保存在用户级 `~/.transvortex/auth.json`：

```powershell
transvortex auth set <credential-id>
transvortex auth status --json
```

Provider YAML 只保存 `credential_id`、endpoint 和 model 等非敏感引用。环境变量和 `.env` 仅作为开发兼容方式。

详细说明见 [`docs/CONFIG_GUIDE.md`](docs/CONFIG_GUIDE.md)。

## CLI 快速使用

先检查环境和翻译连接：

```powershell
transvortex doctor --json
transvortex probe-provider --strict
```

前台运行一次任务：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN
```

Agent 或脚本需要立即取得 `task_id` 时：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN --detach --json
transvortex events --task-id <task_id> --follow
transvortex status --task-id <task_id> --json
transvortex result open --task-id <task_id> --json
```

`--detach --json` 返回排队回执，不是最终任务结果。机器调用不要解析人类日志，完整约定见 [`agent/AGENT_USAGE.md`](agent/AGENT_USAGE.md)。

## Agent / CLI 入口

正式安装会登记两个用户级稳定入口：

```text
%LOCALAPPDATA%\TransVortex\Agent\README.md
%LOCALAPPDATA%\TransVortex\Agent\current.json
```

Agent 先读取 `current.json`，再直接执行其中的 `capabilities_argv` 参数数组，
不需要猜安装目录，也不依赖全局 `PATH`。版本化资料随应用安装在
`<InstallRoot>\agent`；升级会更新定位，卸载只删除上述两个自有入口文件。
便携包保留包内资料，但不登记全局入口，也不修改 Codex、Claude Code、
OpenClaw 等 Agent 自己的 skill、plugin 或 rules 目录。

源码仓库从 [`agent/README.md`](agent/README.md) 开始。Agent 可以直接使用 CLI；
需要长期复用时，再按 [`agent/ADAPTATION_GUIDE.md`](agent/ADAPTATION_GUIDE.md)
自行建立原生适配。一次性的 ASR 环境准备按
[`agent/workflows/ASR_ENVIRONMENT_SETUP.md`](agent/workflows/ASR_ENVIRONMENT_SETUP.md)
执行，不要求先创建 skill。

TransVortex 还提供只读 ASR 环境契约，用于规划和验证：

```powershell
transvortex agent-info --json
transvortex asr setup-plan --json
transvortex asr setup-verify --json --strict
```

契约不会自行安装 Whisper、CUDA、模型或凭据，也不表示用户已经批准 apply。
Flutter 的“应用设置 → Agent / CLI”会检测用户环境中的 Codex CLI，并把客户端
状态与 TransVortex 的稳定 Agent 接口分开显示。语音识别设置中的“交给 Agent”
先确认任务范围，再允许复制短交接或发送给 Codex；直接发送会在工作区缓存中
创建一次性交接目录，通过交互式 `codex -C` 打开新会话，不覆盖用户的 Codex
审批与沙箱设置。
其中 setup-plan 的 `ok` 只表示契约生成成功；是否可运行要看 `ready`、
`plan_status` 和 `blocking_items`，最终以 setup-verify 的 `ok` 为准。

## Flutter 桌面端

```powershell
Set-Location desktop_flutter
flutter pub get
flutter run -d windows
```

桌面端提供：

- 主窗口的一次制作流程。
- 翻译模型和语音识别设置。
- Agent / CLI 稳定入口与按需 ASR 环境交接。
- 任务处理、结果编辑和重新导出。
- 内部诊断与 Windows 系统通知。

全新安装在用户选择的 TransVortex 产品根下建立 `App`、`Data` 和 `Resources`；任务与缓存位于 `Data\Tasks`、`Data\Cache`，受管 ASR 组件、模型和下载位于 `Resources`。配置继续位于 `%LOCALAPPDATA%\TransVortex\Config`，已有安装沿用原登记路径。

开发与验证说明见 [`desktop_flutter/README.md`](desktop_flutter/README.md) 和 [`docs/运行与测试指南.md`](docs/运行与测试指南.md)。

## Windows 安装包

首版未签名 Release Candidate：

```powershell
.\scripts\build_windows_installer.ps1 -ReleaseCandidate -AllowUnsigned -Force
.\scripts\accept_windows_installer.ps1 `
  -InstallerPath .\dist\installer\windows\TransVortex-0.1.0-windows-x64-setup-candidate.exe
```

`0.1.0` Alpha 明确允许未签名发布；`-AllowUnsigned` 是对该策略的显式确认，`-ReleaseCandidate` 负责把产物从内部验收件区分为公开候选。Windows 仍可能显示“未知发布者”或 SmartScreen 提示，这属于首版已接受的用户可见限制，不再是发布阻塞项。当前内部安装路径已通过安装、升级、运行中保护、固定 runtime、快捷方式、卸载和用户数据保留验收；最终候选仍需按其确切哈希完成干净 Windows 复验，详见 [`docs/APP_RUNTIME.md`](docs/APP_RUNTIME.md)。

## 输出与工件

每个任务保留结构化 source、翻译结果、质量信息、事件、checkpoint 和输出。`Segment` 是唯一业务真实来源；SRT、ASS、WebVTT 和 LRC 是独立 renderer。

字幕表现层样例位于 `samples/subtitle_delivery/`。

## 文档

- [`docs/README.md`](docs/README.md)：文档导航和有效性。
- [`docs/CURRENT_BACKLOG.md`](docs/CURRENT_BACKLOG.md)：当前待办和发布边界。
- [`docs/运行与测试指南.md`](docs/运行与测试指南.md)：开发、构建和验收命令。
- [`docs/CONFIG_GUIDE.md`](docs/CONFIG_GUIDE.md)：配置、凭据、翻译和 ASR 参数。
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：后端代码所有权。
- [`docs/TRANSLATION_DESIGN.md`](docs/TRANSLATION_DESIGN.md)：当前翻译架构。
- [`docs/FRONTEND/README.md`](docs/FRONTEND/README.md)：当前 Flutter 产品与设计规格。

## License

TransVortex 使用 Apache License 2.0。样例和第三方材料的单独授权见 [`samples/ATTRIBUTION.md`](samples/ATTRIBUTION.md)。
