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

TransVortex Core 应围绕几个可独立调用的能力演进。当前开发版已经具备 `asr`、`translate`、`export`、`result`、`reexport` 等入口，但这些入口仍处于开发态；机器可读输出要保持可解析和不泄露 secret，字段级长期兼容暂不冻结。

### ASR

输入视频或音频，输出带时间轴的 source segments。

```powershell
transvortex asr --input video.mp4 --src ja --json
```

目标 artifact：

```text
asr/segments.raw.jsonl
```

当前云端 ASR 更接近 OpenAI `whisper-1` / `/v1/audio/transcriptions` 兼容支持，不是完整多厂商 ASR 网关。后续云端 ASR provider、火山/腾讯/阿里/Google/Deepgram 等生态调研和适配路线见 `docs/ASR_PROVIDER_DIRECTION.md`。

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

### Translation Memory（未来增强）

输入 source segments 和已有译文，维护可复用的术语、人名、角色称谓和风格规则。

```text
memory/translation_memory.json
memory/memory_patches.jsonl
memory/conflicts.jsonl
```

设计边界：

- Translation Memory 是外部结构化状态，不依赖模型在多次请求之间隐式记忆。
- 模型可以发现候选、提出 patch、解释冲突；代码负责保存、合并、去重、版本化和冲突记录。
- 翻译 chunk 使用已确认 memory 作为只读约束。
- 低置信度或冲突项不自动覆盖，进入人工确认或 refine agent 流程。

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

### Subtitle Refine Agent（未来增强）

输入已有任务结果和用户自然语言指令，输出受控字幕 patch。

```powershell
transvortex refine --task-id tvx_xxx --instruction "把这段对白改得更口语化"
```

目标 artifact：

```text
refine/runs/<run_id>/candidate_patches.json
refine/runs/<run_id>/applied_patches.json
refine/runs/<run_id>/quality_before.json
refine/runs/<run_id>/quality_after.json
```

设计边界：

- Refine Agent 不是通用文件编辑器，而是字幕专用 patch engine。
- 模型可以检索范围、读取上下文、提出修改；代码负责校验、应用、回滚和重导出。
- V1 先只允许修改 `text_tgt`，默认不允许改时间轴、原文、id 或增删 segment。
- 支持用户手选范围、系统质量问题范围、agent 检索范围。
- 默认提供 preview/review 模式，后续再考虑自动应用低风险 patch。

### Visual Context（未来增强）

输入视频封面或关键帧，输出可选的视觉上下文摘要，供翻译阶段使用。

```text
visual/keyframes/*
visual/visual_context.json
visual/visual_context.md
```

设计边界：

- 视觉上下文是翻译前的辅助阶段，不属于 provider 适配层的基础职责。
- 翻译主链路仍以文本 segments 为核心，不要求翻译模型支持多模态。
- 视觉摘要用于补充场景、角色关系、作品风格和语气建议。
- 视觉上下文也可以供 Translation Memory 和 Subtitle Refine Agent 使用，例如识别画面文字、组织徽记、场景氛围和角色关系。
- 视觉分析失败不阻断 ASR、翻译和导出。
- 后续若实现，可作为独立 provider/worker 能力接入，而不是把所有翻译 provider 都升级成多模态网关。

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

### 当前状态：实现领先于文档

当前代码已经超过早期路线文档中的 V1/V1.1 边界：

- 已有 `asr`、`translate`、`export` 独立入口。
- 已有 provider 管理命令和 provider 预检。
- 已有 result open/save 和 reexport。
- 桌面端已经能调用 Python worker、读事件、管理 provider/key、编辑结果并重导出。

这说明实现探索推进得更快，不说明产品形状已经稳定。现阶段仍应允许 CLI 字段、artifact 细节和桌面工作流继续调整。

### V1.x 分层验收

本机性能或依赖不足时，不把 full video pipeline 作为唯一验收标准。推荐拆成四层：

- 协议层：`--json` 输出合法 JSON，事件输出合法 JSONL，错误结构化，输出不泄露 secret。
- 字幕链路：用 SRT 或 segments 输入跑 `translate -> quality -> export/reexport`。
- 环境层：`doctor` 能明确报告 FFmpeg、ASR 依赖、API key 和 provider 配置状态。
- Full pipeline：在具备 FFmpeg、ASR 依赖、合适硬件或云 ASR 条件时再跑真实视频演示。

当前不建议过早做完整快照测试或字段全集冻结。更合适的是先锁软契约，保留产品探索空间。

### V1.x 开发工作台稳定化

- 打扫工程卫生，避免忽略规则误伤源码。
- 持续同步文档和实际实现。
- 优化桌面端任务详情、错误解释、artifact/log viewer、字幕预览和编辑体验。
- 保持 CLI 和桌面端都调用同一套 Python worker，不分叉业务逻辑。

### Agent 协议逐步收口

- 保持 JSON/JSONL 机器输出可解析。
- 明确 exit code 和 structured error 的基本字段。
- 暂不冻结所有字段，等真实 agent/桌面调用模式更清楚后再扩大契约测试。
- 编写 agent skill/tool 使用说明，但不要求 agent 依赖人类日志。

### V1.2 人类 CLI/TUI

- `transvortex` 默认进入交互式入口。
- `config`、`doctor`、`history`、`demo` 等人类友好命令。
- 中文友好提示。

### V1.3 桌面工作台增强

- 配置页、环境页、任务详情页。
- 输出预览和 artifact viewer。
- 更完整的历史任务管理。

### V1.x / V2 可选：视觉上下文分析

- 从封面或关键帧生成 `visual_context` artifact。
- 将视觉摘要注入翻译 prompt，帮助角色语气、场景风格和专名判断。
- 保持成本可控：默认只分析少量关键帧，不在每个翻译 chunk 上传图片。
- 不作为当前模型接入层继续扩展的理由；provider 层优先保持文本翻译稳定。

### V1.x / V2 可选：翻译记忆与字幕精修 Agent

- 增加 `memory/translation_memory.json`，保存人名、术语、角色称谓、风格规则和开放问题。
- 翻译前可 bootstrap 记忆，翻译中将已确认记忆注入 chunk prompt。
- 翻译后可由模型生成 memory patch，代码负责合并和冲突记录。
- 增加 `refine` 能力，让用户用自然语言对已生成字幕做受控精修。
- Refine Agent 可读取字幕、质量报告、translation memory 和 visual context，输出 patch 而不是直接重写文件。
- 桌面端可提供“选择字幕范围 -> 输入修改要求 -> 预览 patch -> 应用并重导出”的工作流。
- 该方向用于提升字幕产品辨识度，但不应阻塞 V1 的稳定端到端验收。

### V1.x / V2 可选：ASR Provider Gateway 与 Agent/MCP 接口

- 将当前 OpenAI Whisper-style 云端 ASR 支持扩展为独立 ASR provider gateway。
- 支持 direct upload、submit/query async job、URL-based transcription、streaming transcription 等调用形态。
- 抽象 `segments/utterances/words/speaker/confidence` 等响应结构。
- 优先评估 `whisper-1` 稳定性，再考虑火山豆包语音、腾讯云、阿里云、Google Chirp、Deepgram、AssemblyAI 等 provider。
- 为 Codex/agent 提供 skill 或 MCP 工具，让 agent 调用 TransVortex 的稳定 worker，而不是临时拼 FFmpeg/ASR/翻译脚本。
- 详细方向见 `docs/ASR_PROVIDER_DIRECTION.md`。

### V2 发布与分发

- Windows 安装包。
- FFmpeg 和 Python worker 分发策略。
- 模型缓存和依赖管理。
- macOS / Linux 评估。
