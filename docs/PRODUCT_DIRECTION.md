# TransVortex 产品方向与入口设计

## 1. 定位

TransVortex 不只是一个“把视频转成字幕”的脚本，而是一个可被人和 agent 共同调用的本地媒体智能处理能力层。

推荐长期定位：

```text
Agent-callable Headless Core + Human-friendly CLI/TUI + Desktop Workbench
```

核心能力保持在同一套 worker 中，所有入口都调用同一份任务协议、配置系统、artifact 目录和事件流。

```text
TransVortex Core / Worker
  -> Agent CLI: machine-readable, stable, automatable
  -> Human CLI / TUI: guided terminal experience
  -> Desktop Client: visual configuration and task management
```

这样可以避免 CLI、桌面端、未来服务端各自实现一套业务逻辑。

## 2. 目标用户

### Agent / 自动化系统

Agent 需要的是稳定、低歧义、机器可读的接口：

- 固定命令和参数。
- JSON 输出和 JSONL 事件流。
- 明确 exit code。
- 稳定 artifact 结构。
- 可恢复、可取消、可查询状态。
- 不依赖自由文本日志解析。

典型调用方包括 Codex、脚本、批处理工具、工作流系统和未来的服务端 API。

### 终端用户 / 高级用户

终端用户不应该被迫记住大量路径、环境变量和 provider 参数。

理想体验是：

```powershell
transvortex
```

进入一个交互式 CLI/TUI，用引导方式完成：

- 环境检查。
- provider 配置。
- API key 保存。
- 视频选择或路径输入。
- 源语言和目标语言配置。
- 任务启动、暂停、恢复。
- 历史任务查看。
- 输出文件打开。

### 桌面用户

桌面端不是附属品，而是普通用户和复杂任务调试的重要入口。

桌面端应当支持：

- 拖拽视频。
- 可视化配置 provider、模型、ASR、输出目录。
- 保存和检查本地 key。
- 运行前环境诊断。
- 查看实时进度、事件、错误和 artifact。
- 管理历史任务。
- 打开 SRT、任务目录和日志。

## 3. CLI 与 Agent 友好性的关系

CLI 和 agent 友好不是两件完全分开的事。

推荐把 CLI 分成两层：

### 3.1 机器层命令

机器层命令稳定、英文、可脚本化，适合 agent 调用。

示例：

```powershell
transvortex run --input video.mp4 --src en --tgt zh-CN --json
transvortex run --input video.mp4 --src en --tgt zh-CN --stream-events
transvortex status --task-id tvx_xxx --json
transvortex events --task-id tvx_xxx
transvortex cancel --task-id tvx_xxx --json
transvortex resume --task-id tvx_xxx --stream-events
```

机器层输出必须遵守契约：

- `--json` 只输出一个 JSON object 或 array。
- `--stream-events` 只输出 JSONL events。
- stderr 用于不可恢复的诊断信息。
- exit code 表示任务发起或命令执行是否成功。
- 长任务状态通过 artifact 和 `events` 查询。

### 3.2 人类层命令

人类层命令更少参数、更友好，可以中文化。

示例：

```powershell
transvortex
transvortex doctor
transvortex config
transvortex history
transvortex demo
```

这些命令可以使用交互式 UI，也可以输出漂亮的表格、提示和修复建议。

人类层命令可以调用机器层 worker，但不要反过来让 agent 依赖人类层输出。

## 4. Skill / Agent 集成思路

TransVortex 很适合被封装成 agent skill 或工具。

Skill 不应该重新实现 ASR 或翻译逻辑，而应该只负责：

- 发现项目是否安装。
- 运行 `transvortex doctor --json` 检查环境。
- 使用 `transvortex run/asr/translate --json` 发起任务。
- 监听 `--stream-events` 或读取 `events`。
- 从 artifact 中取回 SRT、segments、translation artifacts。
- 根据 exit code 和 structured error 决定是否重试或提示用户。

未来可以为 agent 提供一份专门的工具说明：

```text
When you need local video ASR, subtitle translation, or SRT export,
call TransVortex through its machine-readable CLI.
Do not parse human logs. Use JSON/JSONL outputs and artifact paths.
```

## 5. 能力边界

TransVortex Core 应逐步拆成三个可独立调用的能力：

### ASR

输入视频或音频，输出带时间轴的 source segments。

```powershell
transvortex asr --input video.mp4 --src ja --json
```

目标 artifact：

```text
asr/segments.raw.jsonl
```

### Translate

输入 segments，输出 translated segments。

```powershell
transvortex translate --segments segments.raw.jsonl --src ja --tgt zh-CN --json
```

目标 artifact：

```text
translate/segments.translated.jsonl
translate/validation.jsonl
translate/repairs.jsonl
```

### Full Pipeline

输入视频，输出字幕。

```powershell
transvortex run --input video.mp4 --src ja --tgt zh-CN --bilingual --json
```

目标 artifact：

```text
final/segments.final.json
output/*.srt
```

## 6. 国际化策略

项目应该中文友好，但底层协议保持英文。

推荐规则：

- 命令名、参数名、JSON 字段、错误码使用英文。
- 桌面 UI 默认支持中文，后续可加英文。
- 交互式 CLI/TUI 可以默认中文，提供英文模式。
- 文档可以中英并存；开发协议文档优先英文或中英对照。
- 错误提示面向用户时可以中文解释，但 structured error code 必须稳定英文。

示例：

```json
{
  "error_type": "missing_env",
  "message": "Missing environment variable: TVX_MODEL_API_KEY",
  "hint_zh": "缺少模型 API Key。请在配置页保存 key，或设置 TVX_MODEL_API_KEY。"
}
```

## 7. 配置体验目标

长期不应该要求用户手动拼大量环境变量。

推荐配置入口：

- `transvortex doctor` 检查环境。
- `transvortex config` 交互式配置 provider/key。
- 桌面端配置页保存 `.env` 和本地 provider 配置。
- 机器层仍然支持环境变量和 `--providers-file`，方便 agent 和 CI。

配置文件职责：

```text
providers.yaml / providers.local.yaml
  描述 provider 协议、URL、认证、模型、response mapping。

pipeline.yaml
  描述 ASR、chunking、翻译策略、并发、导出质量。

.env
  保存本地 secret，不提交。
```

## 8. 桌面客户端方向

短期桌面端定位为开发工作台。

下一阶段重点：

- 环境诊断页。
- provider/key 状态页。
- 任务详情页。
- artifact/log viewer。
- 输出字幕预览。
- 更清晰的错误分类和修复建议。

中长期桌面端可以成为主产品入口，并与 CLI 共享同一套 worker。

## 9. 发布形态

推荐同时保留两种发布形态：

### 纯 CLI 包

适合 agent、服务器、开发者和批处理。

目标：

- 安装轻。
- 协议稳定。
- 易于被脚本调用。
- 能运行 headless。

### 桌面客户端

适合普通用户和可视化任务管理。

目标：

- 内置或引导安装依赖。
- 提供配置 UI。
- 提供历史任务和输出管理。
- 支持拖拽和可视化进度。

## 10. 近期路线建议

### V1 稳定跑起来

- 修正 provider key 命名和配置体验。
- 增加 `doctor` 环境诊断。
- 跑通真实 demo 端到端。
- 清理 checkpoint、events、error 状态一致性。
- 保证桌面端能稳定启动任务和展示错误。

V1 当前落地范围：只做开发机稳定可用，不做安装包、不做完整 TUI、不拆 ASR/Translate 独立子命令。验收路径是 `doctor -> probe-provider -> run -> status/events/artifacts`。

### V1.1 Agent 协议收口

- 固化 JSON/JSONL 输出。
- 明确 exit code。
- 增加 structured error。
- 为 ASR、Translate、Full Pipeline 拆出稳定子命令。
- 编写 agent skill/tool 使用说明。

### V1.2 人类 CLI/TUI

- `transvortex` 默认进入交互式入口。
- `config`、`doctor`、`history`、`demo` 等人类友好命令。
- 中文友好提示。

### V1.3 桌面工作台增强

- 配置页、环境页、任务详情页。
- 输出预览和 artifact viewer。
- 更完整的历史任务管理。

### V2 发布与分发

- Windows 安装包。
- FFmpeg 和 Python worker 分发策略。
- 模型缓存和依赖管理。
- macOS / Linux 评估。
