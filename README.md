<div align="center">
  <img src="desktop_flutter/assets/branding/app_icon_1024.png" width="112" alt="TransVortex 应用图标">
  <h1>TransVortex</h1>
  <p><strong>本地优先的 AI 字幕制作工具</strong></p>
  <p>从视频、音频或 SRT 到可审看、可恢复、可重新导出的字幕结果。</p>
  <p>
    <a href="https://github.com/zvensmoluya/TransVortex/releases">下载</a>
    · <a href="#快速开始">快速开始</a>
    · <a href="docs/USER_GUIDE.md">用户指南</a>
    · <a href="docs/README.md">全部文档</a>
    · <a href="docs/CURRENT_BACKLOG.md">当前进度</a>
  </p>
</div>

![TransVortex Windows 主窗口：示例音频已经就绪，等待开始字幕制作](docs/assets/readme/transvortex-main-ready.png)

TransVortex 把语音识别、翻译、字幕质量处理、结果审看和导出放进同一个可恢复工作流。Windows Flutter 桌面应用是面向普通用户的唯一桌面前端；CLI 和 Agent 接口复用同一套 Python core、任务协议与工件，适合自动化和高级使用。

> 语言范围：`0.1.0` 的桌面界面和用户文档仅提供简体中文；这不限制字幕的源语言和目标语言，实际识别与翻译能力取决于所选模型和服务。英文文档将在后续逐步补充，界面国际化不属于首版范围。

## 下载与安装

公开桌面安装包只以 [GitHub Releases](https://github.com/zvensmoluya/TransVortex/releases) 页面发布的文件为准。

- 平台：Windows x64。
- 安装方式：用户级 NSIS 安装器，可选择独立的 TransVortex 产品目录。
- 自带组件：Flutter 应用、固定 Embedded Python 主 runtime 和固定 FFmpeg runtime。
- 终端用户不需要另行安装 Python、FFmpeg 或 PowerShell。

> `0.1.0` 接受未签名安装包。Windows 可能显示“未知发布者”或 SmartScreen 提示；运行前请确认下载来源，并核对 Release 页面公布的 SHA-256。未签名是首版已知限制，不代表安装包可以绕过来源与哈希检查。

安装包中的 FFmpeg core 使用 LGPL-3.0-or-later，并以独立进程运行。其[完整对应源码](https://github.com/zvensmoluya/transvortex-assets/releases/download/ffmpeg-core-runtime-v8.1.2-31-g8c9502e9b0-r2/transvortex-ffmpeg-n8.1.2-31-g8c9502e9b0-core-corresponding-source-r2.zip)与二进制固定发布；技术边界见 [FFmpeg 分发合规说明](docs/FFMPEG_DISTRIBUTION_COMPLIANCE.md)。

## 快速开始

1. 安装并启动 TransVortex，在“翻译模型设置”中配置 endpoint、模型和 API key。
2. 在“语音识别设置”中选择本机 Whisper、FunASR、OpenAI Whisper 或 OpenRouter。本机 Whisper 会按需下载隔离 runtime 和模型。
3. 拖入视频、音频或 SRT。视频会先检查可用的内嵌文本字幕；SRT 可以跳过语音识别直接翻译。
4. 选择源语言、目标语言、翻译模型和输出形式，然后开始任务。
5. 完成后打开任务处理窗审看字幕、修正文本或时间码，并重新导出需要的格式。

关闭主窗口会把应用收起到系统托盘，当前任务和 Local Service 继续运行；需要完全退出时使用托盘菜单中的退出动作。

安装校验、模型连接、四种语音识别方式、任务恢复和字幕审看的完整步骤见 [桌面用户指南](docs/USER_GUIDE.md)。

## 当前能力

| 环节 | 当前实现 |
| --- | --- |
| 输入 | 视频、音频和 SRT；视频可优先提取内嵌文本字幕 |
| 语音识别 | 受管本机 Whisper、用户提供的 FunASR 服务、OpenAI Transcriptions、OpenRouter 语音识别 |
| 翻译 | 可配置 provider、模型与 fallback；容量感知分片、上下文、校验和有界修复 |
| 术语与质量 | 术语建议与运行时记忆、字幕压缩与重排、结构化质量记录 |
| 任务 | 事件、checkpoint、取消、继续、失败恢复、托盘后台运行 |
| 结果 | 字幕审看与编辑、时间码微调、SRT / ASS / WebVTT / LRC 导出与重新导出 |
| 自动化 | CLI、机器可读 JSON / JSONL、稳定 Agent 入口和只读环境准备契约 |

### 语音识别方式

| 方式 | 数据边界 | `0.1.0` 状态 |
| --- | --- | --- |
| 本机 Whisper | 音频留在本机；runtime 和模型按需下载 | 公开受管路径保证 CPU，可使用应用下载或用户提供的兼容 CTranslate2 模型 |
| FunASR | 音频发送到用户配置的 FunASR 服务 | 支持用户自行维护的兼容服务，不与其他识别方式自动回退 |
| OpenAI Transcriptions | 音频上传到用户配置的 OpenAI Transcriptions endpoint | 支持独立凭据、分窗和时间轴处理 |
| OpenRouter | 音频上传到 OpenRouter | 开放经过验证的模型 profile；Whisper 可用，Grok STT 仍标为实验能力 |

## 数据与隐私

TransVortex 的“本地优先”指任务状态、工件、审看与本机识别默认由本地应用管理，不表示所有 AI 能力都离线运行。

| 数据 | 默认行为 |
| --- | --- |
| 原始媒体 | 本机 Whisper 不上传媒体；FunASR、OpenAI 或 OpenRouter 会接收完成识别所需的音频 |
| 字幕文本 | 配置的翻译 provider 会接收翻译所需的文本、上下文和术语信息 |
| API 凭据 | 默认保存在用户级 `~/.transvortex/auth.json`；Provider YAML 只保存 `credential_id`、endpoint、model 等非敏感引用 |
| 任务与缓存 | 正式安装使用产品根下的 `Data\Tasks`、`Data\Cache`；受管识别资源位于 `Resources` |
| 遥测 | 当前版本没有集成产品遥测或第三方 analytics 服务 |

卸载程序会把应用、任务、设置、识别资源和凭据作为不同删除边界。程序始终可以移除；任务、设置和凭据默认保留，受管 ASR 资源可单独选择是否删除。用户自己的原始媒体、导出字幕和原地使用的外部模型不属于应用删除范围。

## `0.1.0` 已知限制

- 当前只提供 Windows x64 正式桌面交付；macOS 和 Linux 尚无正式安装包。
- 安装包没有 Authenticode 签名，Windows 可能显示“未知发布者”或 SmartScreen 提示。
- 首轮受管本机 ASR 只公开 CPU 设置路径；NVIDIA 受管安装入口不属于首版承诺。
- 已有受管 ASR 资源不能自动跨盘迁移；模型下载可能占用较多磁盘和网络流量。
- 关闭窗口后的托盘驻留已经支持，但独立 App Host、应用崩溃恢复和进程树守护尚未完成。
- OpenRouter Grok STT 仍是实验能力；长音频、多语言和切句质量仍需更多真实内容验证。
- 远端 ASR 和翻译服务可能产生费用，AI 生成字幕仍需要人工审看。

`0.1.0` 已完成发布验收。发布后的非阻塞待办和后续优先级统一维护在 [CURRENT_BACKLOG.md](docs/CURRENT_BACKLOG.md)。

## CLI 与 Agent

源码环境要求 Python 3.10 或更高版本。安装基础 CLI：

```powershell
python -m pip install -e .
transvortex doctor --json
```

凭据默认写入用户级凭据文件，不写进 Provider YAML：

```powershell
transvortex auth set <credential-id>
transvortex auth status --json
```

运行一次字幕任务：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN --bilingual --output-format both
```

脚本需要立即取得 `task_id` 时使用 detached 模式，并从结构化接口读取后续状态：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN --detach --json
transvortex events --task-id <task_id> --follow
transvortex status --task-id <task_id> --json
transvortex result open --task-id <task_id> --json
```

`--detach --json` 返回排队回执，不是最终字幕结果。机器调用不要解析面向人的日志；完整契约见 [Agent 使用说明](agent/AGENT_USAGE.md)。

正式安装会登记稳定的用户级 Agent 入口：

```text
%LOCALAPPDATA%\TransVortex\Agent\README.md
%LOCALAPPDATA%\TransVortex\Agent\current.json
```

Agent 可以从 `current.json` 取得版本化文档和可直接执行的 CLI 参数，不需要猜安装目录。源码仓库入口见 [agent/README.md](agent/README.md)，环境准备契约可以通过以下命令只读检查：

```powershell
transvortex agent-info --json
transvortex asr setup-plan --json
transvortex asr setup-verify --json --strict
```

## 从源码开发

仓库 CLI 需要系统 `ffmpeg` / `ffprobe`；正式 Windows 安装包使用自己的固定 runtime，不读取开发机 Python 或系统 FFmpeg。

Python core：

```powershell
python -m pip install -e ".[test]"
python -m pytest -q
```

需要开发态进程内 faster-whisper 时额外安装：

```powershell
python -m pip install -e ".[asr]"
```

Flutter Windows 前端：

```powershell
Set-Location desktop_flutter
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
flutter run -d windows
```

CI 当前固定 Flutter `3.44.4`。`flutter build windows --release` 只生成 Flutter Release，不等于包含固定 Python、FFmpeg、manifest 和安装验收的公开安装包；完整构建与发布流程见 [运行与测试指南](docs/运行与测试指南.md) 和 [应用 runtime 文档](docs/APP_RUNTIME.md)。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `desktop_flutter/` | 唯一产品桌面前端 |
| `src/transvortex/` | Python core、CLI、Local Service、Worker 和 provider / ASR 适配 |
| `agent/` | 安装后稳定 Agent 契约、使用说明和按需 workflow |
| `scripts/` | 构建、打包、smoke、安装与验收脚本 |
| `docs/` | 当前专题文档、前端规格和历史归档入口 |
| `samples/` | 字幕交付样例与来源说明 |

## 文档

- [桌面用户指南](docs/USER_GUIDE.md)：安装、首次配置、制作、任务恢复、字幕审看、数据管理和常见故障。
- [文档入口](docs/README.md)：当前文档导航、有效性和冲突判断规则。
- [产品与系统总览](docs/PRODUCT_OVERVIEW.md)：稳定产品模型、核心流程与系统边界。
- [高级配置与协议参考](docs/CONFIG_GUIDE.md)：面向 CLI、Agent 和手工配置的 Provider、凭据、翻译、ASR 与网络字段。
- [架构说明](docs/ARCHITECTURE.md)：Python core、CLI、协议与桌面接入的所有权边界。
- [桌面运行架构](docs/DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md)：Local Service、Worker、托盘和发布基础。
- [Flutter 产品入口](docs/FRONTEND/README.md)：当前产品表面、配置语义和设计规格。
- [当前待办](docs/CURRENT_BACKLOG.md)：`0.1.0` 发布边界、发布后的非阻塞待办和后续优先级。
- [变更记录](CHANGELOG.md)：公开版本中用户可见的重要变化与发布边界。
- [安全策略](SECURITY.md)：支持范围以及普通问题与敏感漏洞的报告方式。

## 问题反馈

一般缺陷和功能讨论可以提交到 [GitHub Issues](https://github.com/zvensmoluya/TransVortex/issues)。请附上 TransVortex 版本、Windows 环境、识别方式、复现步骤和经过脱敏的 `transvortex doctor --json` 结果；不要上传 API key、`auth.json`、私有媒体、完整任务目录或含敏感路径的日志。可能造成凭据泄露、任意代码执行或用户数据暴露的问题不要公开披露，请按[安全策略](SECURITY.md)报告。

公开联系邮箱：[open@zven.cc](mailto:open@zven.cc)。

## License

Copyright 2026 Zven。TransVortex 使用 [Apache License 2.0](LICENSE)。随应用分发的第三方组件保留各自许可：

- FFmpeg core：LGPL-3.0-or-later，见 [分发合规说明](docs/FFMPEG_DISTRIBUTION_COMPLIANCE.md)。
- Noto Sans SC 与 LXGW WenKai Lite：见随字体保存的 [Noto Sans SC OFL](desktop_flutter/assets/fonts/NotoSansSC-OFL.txt) 和 [LXGW WenKai Lite OFL](desktop_flutter/assets/fonts/LXGWWenKaiLite-OFL.txt)。
- 示例素材来源：见 [samples/ATTRIBUTION.md](samples/ATTRIBUTION.md)。
