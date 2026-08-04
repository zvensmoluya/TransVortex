# TransVortex 项目设计说明书（V1.x 开发版）

> **文档状态：历史设计快照。** 本文已经由当前的 [`PRODUCT_OVERVIEW.md`](../../PRODUCT_OVERVIEW.md) 取代，保留阶段判断用于追溯，不再代表当前实现或计划。

## 1. 项目目标
- 将本地视频自动生成高质量字幕（优先输出双语可选）。
- 支持多 AI 厂商模型（OpenAI / Anthropic / Gemini 等）统一接入与切换。
- 在“速度、成本、质量”之间提供可配置平衡策略（V1 速度优先）。
- 全流程可追踪、可重试、可恢复，适配长视频处理。
- 不将完整视频一次性载入内存，支持大文件稳定处理。
- 为未来安卓端落地预留架构边界（核心逻辑可复用）。

## 2. 设计原则
- **极速优先**：优先采用流式处理、并行流水与增量输出，尽快产出首批字幕。
- **低内存**：严禁“整视频入内存”，采用分块/流式读写与中间产物落盘。
- **可插拔**：ASR 与翻译模型都通过统一适配器接入。
- **可恢复**：每个阶段落盘中间产物，失败后支持断点续跑。
- **可观测**：记录耗时、token、错误率、单任务成本。
- **可扩展**：先做单机 CLI，后续可平滑演进服务化与移动端。

## 3. 系统范围
### 3.1 In Scope（V1）
- 本地视频文件输入（常见格式 mp4/mkv/mov）。
- 音频提取与标准化。
- 语音识别（本地 Whisper 优先）。
- 文本翻译（多模型 API 编排）。
- 字幕对齐、校验与导出（当前实现以 SRT/ASS 为主，VTT 作为后续 Web 场景扩展）。

### 3.2 Out of Scope（V1 暂不做）
- 实时流媒体字幕。
- 复杂说话人分离与精细角色标注。
- 多模态翻译输入输出；封面/关键帧理解作为后续“视觉上下文分析”阶段，而不是 V1 provider 适配目标。
- Web 平台多租户管理。

## 4. 总体架构
```text
[CLI/API]
   |
   v
[Pipeline Orchestrator]
   |--> [Media Ingest]
   |--> [ASR Engine]
   |--> [Text Segmenter]
   |--> [LLM Translation Gateway]
   |--> [Aligner + Quality Guard]
   |--> [Exporter]
   |
   v
[Artifacts + Task Store + Logs]
```

## 5. 核心模块设计
### 5.1 模块 A：媒体预处理器（Media Ingest）
- 技术建议：ffmpeg / ffmpeg-python（二选一，CLI 更稳定）。
- 功能：
  - 自动抽取音轨；AAC/MP3 优先无损 copy（减少转码耗时）。
  - 非目标编码时转为标准输入（如 16k/mono wav 或 m4a）。
  - 基于时间片分块（如 30-120 秒）顺序处理，避免大文件内存峰值。
  - 可选静音裁剪（VAD），减少 ASR 与翻译成本。
- 产物：
  - `audio.wav|m4a`（支持分片文件）
  - `media_meta.json`（时长、采样率、声道、编码信息）

### 5.2 模块 B：转录引擎（ASR Engine）
- 默认方案：本地 Whisper（CPU/int8 作为稳定默认，GPU/CUDA 作为高级配置）。
- 可扩展：OpenAI Whisper-style 云端 ASR 作为 fallback。
- 输出统一结构 `segments.json`，每条包含：
  - `id`, `start`, `end`, `text`, `confidence`（可选）
- 说明：不直接输出 SRT，避免过早绑定格式。
- 当前云端 ASR 更接近 OpenAI `whisper-1` / `/v1/audio/transcriptions` 兼容支持。完整 ASR provider gateway、火山/腾讯/阿里/Google/Deepgram 等云端 ASR 生态和 agent/MCP 接口方向见 `docs/ASR_PROVIDER_DIRECTION.md`。

### 5.3 模块 C：翻译编排器（LLM Orchestrator）
- 支持厂商：OpenAI / Anthropic / Gemini（统一接口）。
- 核心策略：
  - 文本脱敏：仅传 `text`，不上传媒体文件。
  - 批处理：30-50 行一组，附稳定序号 `[n]`。
  - Prompt 约束：严格按序号返回，仅返回译文。
  - 并发控制：按模型/账号限流（如 5-10 并发）。
  - 重试机制：超时、限流、响应格式错误时自动重试。
- 路由策略（建议）：
  - 默认低成本模型；
  - 对低置信度片段或术语密集片段升级高质量模型二次翻译。

### 5.4 模块 D：对齐与导出（Final Aligner）
- 按编号将译文回填到原始时间轴片段。
- 质量校验：
  - 行数一致性检查；
  - 空行/丢行检测；
  - 字幕时长与阅读速度约束（CPS）；
  - 失败片段自动补译。
- 输出格式：
  - `*.srt`（默认）
  - `*.ass`（进阶样式）
  - `*.vtt`（Web 场景，后续扩展）

### 5.5 未来模块 E：视觉上下文分析（Visual Context，可选）
- 定位：作为翻译前的辅助上下文提取阶段，而不是扩大模型 provider 适配层的职责。
- 输入：视频封面、关键帧或少量代表性画面。
- 输出：短文本/JSON 摘要，例如场景类型、角色关系、人物年龄感、作品风格、语气建议、专名线索。
- 使用方式：将摘要作为全局上下文注入翻译 prompt，主翻译链路仍只发送字幕文本与上下文文本。
- 产物建议：
  - `visual/keyframes/*`
  - `visual/visual_context.json`
  - `visual/visual_context.md`
- 原则：
  - 不要求所有翻译 provider 支持多模态。
  - 不在每个翻译 chunk 重复上传图片，避免成本和延迟失控。
  - 视觉分析失败不应阻断 ASR/翻译/导出主流程。
  - 当前 V1.x 不作为主线功能，作为后续增强功能评估。

### 5.6 增强模块 F：翻译记忆与动态变量（Translation Memory，可选）
- 定位：为长视频和系列内容提供术语、人名、组织名、角色称谓、风格规则和开放问题的外部记忆层。当前已有基础实现，默认关闭，不阻塞主流程。
- 核心思路：不要依赖模型在多次请求之间“自己记住”。模型负责发现候选和提出 patch，代码负责保存、合并、去重、冲突标记和注入 prompt。
- 使用方式：
  - 翻译前可对全片或大段字幕进行扫描，生成初始 `translation_memory.json`。
  - 每个 translation chunk 调用模型时，将已确认记忆作为只读约束注入。
  - chunk 完成后可让模型基于原文、译文和旧记忆提出 memory patch。
  - 系统校验 patch 后合并到记忆，并记录冲突或待人工确认项。
- 产物建议：
  - `memory/translation_memory.json`
  - `memory/memory_patches.jsonl`
  - `memory/conflicts.jsonl`
- 典型内容：
  - `characters`：角色名、别名、称谓、语气备注。
  - `terms`：专有名词、组织名、地名、技术术语。
  - `style_rules`：口语化程度、粗口力度、字幕压缩偏好。
  - `open_questions`：模型不确定的译名或语义。
- 原则：
  - 记忆应结构化，不使用不可解析的大段自由笔记作为唯一状态。
  - 翻译正文输出与记忆更新输出分离。
  - 自动合并只处理低风险项，高风险冲突应保留给人工确认或后续 refine agent 处理。
  - 该模块增强一致性，但不替代 chunk 级 deterministic validation。

### 5.7 未来模块 G：字幕精修 Agent（Subtitle Refine Agent，可选）
- 定位：在字幕生成后，允许用户用自然语言对字幕进行受控精修，例如统一译名、调整语气、压缩过长字幕、修复生硬直译。
- 形态：不是通用文件编辑 agent，而是字幕专用 patch engine。模型可以规划和提出修改，代码负责范围选择、patch 校验、应用、回滚和重导出。
- 典型交互：
  - “把第 120-180 条改得更像大陆影视字幕，别太书面。”
  - “统一 The Order 都翻成教团。”
  - “只处理 CPS 超标的字幕，尽量压短但别丢信息。”
  - “参考这几张图的氛围，把这段对白改得更紧张。”
- 范围来源：
  - 用户手选：id 范围、时间范围、桌面端选中的字幕行。
  - 系统筛选：质量问题、术语冲突、特定关键词、人名出现范围。
  - agent 检索：先搜索相关字幕并提出待处理范围，再生成 patch。
- 受控工具边界：
  - `search_segments`
  - `read_window`
  - `read_quality_issues`
  - `read_memory`
  - `read_visual_context`
  - `propose_patches`
  - `validate_patches`
  - `apply_patches`
  - `reexport`
- 产物建议：
  - `refine/runs/<run_id>/instruction.txt`
  - `refine/runs/<run_id>/candidate_patches.json`
  - `refine/runs/<run_id>/applied_patches.json`
  - `refine/runs/<run_id>/quality_before.json`
  - `refine/runs/<run_id>/quality_after.json`
- 安全边界：
  - V1 先只允许修改 `text_tgt`。
  - 默认不允许增删 segment，不允许改 `id/start/end/text_src`。
  - patch 必须可预览、可校验、可回滚。
  - 应用后重跑字幕质量检查并支持重导出。
  - 视觉/OCR 只能作为参考上下文，不应绕过字幕 patch 校验。

## 6. 数据流与状态机
### 6.1 数据流
1. Input：`video.mp4`
2. Ingest：流式抽音 + 分片，生成 `audio.part.*` + `media_meta.json`
3. ASR：按分片增量生成 `segments.raw.jsonl`（可持续追加）
4. Segment：生成 `segments.chunked.jsonl`
5. Translate：并发翻译并增量写入 `segments.translated.jsonl`
6. Align/QA：聚合成 `segments.final.json`
7. Export：输出 `video.zh-CN.srt`（可选双语）

### 6.2 状态机
`INGEST -> ASR -> SEGMENT -> TRANSLATE -> ALIGN -> EXPORT -> DONE`

失败进入 `FAILED`，并保存失败原因与可重试阶段；重跑时可从最近成功阶段恢复。

## 7. 统一数据模型（草案）
### 7.1 Segment
```json
{
  "id": 12,
  "start": 35.42,
  "end": 38.90,
  "text_src": "Hello everyone.",
  "text_tgt": "大家好。",
  "confidence": 0.94,
  "meta": {
    "chunk_id": "c003",
    "provider": "anthropic",
    "model": "claude-3-5-haiku"
  }
}
```

### 7.2 Task
```json
{
  "task_id": "tvx_20260212_0001",
  "input_file": "video.mp4",
  "source_lang": "en",
  "target_lang": "zh-CN",
  "status": "TRANSLATE",
  "created_at": "2026-02-12T14:00:00Z",
  "updated_at": "2026-02-12T14:01:30Z"
}
```

## 8. 配置设计（Config-first）
- `providers.yaml` / `providers.local.yaml`：厂商协议、模型、限流、超时、重试参数；API Key 只通过 `env_key` 指向环境变量或 `.env`，不直接写入 provider 配置。
- `pipeline.yaml`：分块大小、并发数、ASR 模式、翻译策略、导出格式、字幕质量策略。
- 字幕质量配置当前收敛在 `pipeline.yaml` 的 `subtitle.quality` 与 `subtitle.compression` 下；后续如规则膨胀，再拆独立 `quality.yaml`。

## 9. 非功能需求
- 性能：1 小时视频在高性能机器上目标 3-10 分钟（视模型与并发）。
- 首字时间（TTFS）：目标 20-60 秒内产出第一批字幕（分片并行时）。
- 内存约束：处理峰值内存与视频大小解耦，不随输入文件线性增长。
- 成本：尽量只上传文本，记录每任务 token 与估算费用。
- 稳定性：关键步骤支持至少 3 次重试；失败可恢复。
- 安全：API Key 仅本地环境变量读取，不写入日志。

## 10. 当前实现状态与路线
### 10.1 当前已落地
- CLI / agent 入口：`run`、`resume`、`status`、`events`、`cancel`、`tasks`、`doctor`、`config show`、`probe-provider`、`asr`、`translate`、`export`、`result`、`reexport`、`provider`。
- 核心 pipeline：视频分片抽音、ASR、chunk 翻译、校验、repair、对齐、字幕质量优化、SRT/ASS 导出。
- 输入链路：支持视频输入，也支持 SRT 或 segments 输入后只跑翻译与导出。
- 任务系统：artifact 目录、checkpoint、结构化 events、取消和恢复。
- Provider：OpenAI/Anthropic/Gemini/custom JSON 风格文本 provider 适配，支持 `providers.local.yaml` 私有配置和零 token 本地协议预检。
- Desktop：Flutter 是主体验前端，已接 Local Service、配置、任务运行、历史任务、结果编辑和重导出；冻结的 Tauri 实现只作参考。

### 10.2 仍不稳定的边界
- JSON/JSONL 机器输出需要保持合法、可解析、无密钥泄露，但字段全集暂不冻结。
- Windows Flutter 桌面端已有 `0.1.0` Alpha 内部 NSIS 安装包，但尚未达到公开发布条件。
- Full video ASR pipeline 受运行环境性能、FFmpeg、`faster-whisper`、模型和 API key 影响，不作为所有开发机的唯一验收标准。
- 术语记忆基础已经进入主链路；完整术语管理、Subtitle Refine Agent、Visual Context 和多厂商 ASR Gateway 仍属于增强方向，不阻塞当前 V1.x。

### 10.3 后续路线
- **R1（开发卫生）**：保持文档和真实实现同步，确保测试在无真实 provider、无大视频、无本地 ASR 依赖时也能运行。
- **R2（分层验收）**：协议层验证 JSON/JSONL 与错误结构；字幕链路用 SRT/segments 验证 `translate -> quality -> export/reexport`；完整视频链路作为具备依赖后的真实演示。
- **R3（桌面增强）**：完善错误解释、任务详情、artifact/log viewer、字幕预览和编辑体验。
- **R4（产品化）**：在已有 Windows 安装包和固定 Python / FFmpeg runtime 基础上，完成签名、干净机验收、公开分发合规和按需本机 ASR 组件体验。
- **R5（后续增强）**：完整术语管理、Subtitle Refine Agent、Visual Context、多厂商 ASR Gateway。

## 11. 风险与应对
- 模型响应格式不稳定：强约束输出 + 解析容错 + 自动补译。
- 长视频成本波动：分段路由 + 低成本优先 + 二次精修。
- 字幕可读性不足：CPS/行长规则 + 自动重排断句。
- 移动端算力不足：安卓端优先做“任务发起 + 下载结果”，重计算放服务端。

## 12. FFmpeg 原理（面向非音视频背景）
- FFmpeg 本质是一个“解封装 + 编解码 + 过滤 + 封装”的流水线工具。
- `copy` 表示不重编码，只把音轨从容器中抽出来，速度最快、质量无损。
- 只有当源编码不满足后续 ASR 需要时，才做转码（会增加时间与 CPU/GPU 开销）。
- 我们采用“按时间片切分 + 顺序/并行处理”，所以不需要把整个视频读进内存。

## 13. 开发与运行前置依赖
本节是目标开发机/运行机的通用依赖清单，不描述某一台电脑的当前状态。

- Python：开发态 CLI 需要项目支持的 Python 环境；Windows 安装包内置固定 Embedded Python，不要求终端用户单独安装。
- FFmpeg / FFprobe：开发态 CLI 可使用系统 `PATH`；Windows 安装包内置固定 FFmpeg runtime，不要求终端用户单独安装。
- 本地 ASR：开发态可安装 `.[asr]`；桌面基础包不携带本机 Whisper runtime、模型或 CUDA，由用户按需安装受管组件和模型。
- Provider API Key：默认保存在用户级 `~/.transvortex/auth.json`，环境变量和 `.env` 只作开发兼容；不要提交真实 key。
- 可选：NVIDIA CUDA 环境（用于本地 Whisper 加速）。CPU/int8 仍应作为稳定默认路径。

---
本说明书描述 V1.x 的产品和架构演进。当前文档入口见 `docs/README.md`，短期优先级见 `docs/CURRENT_BACKLOG.md`。

## 14. 产品形态与后续方向

### 14.1 当前判断
- 当前项目已经形成 V1.x 开发版：本地视频经 FFmpeg 抽音频与切片，使用 `faster-whisper` 或 OpenAI Whisper-style 云端 ASR 产出 segments，再调用可配置 LLM provider 翻译，最终导出 SRT/ASS。
- 原 V1 目标方向合理，但范围较大：高质量字幕、多厂商、极速、低内存、可观测、桌面端、移动端预留都在同一产品愿景下。当前实现应继续以“稳定生成可用字幕、保持核心可被脚本和 agent 调用”为主线。
- UI 不必等内核完全成熟后再做。这个产品涉及拖拽视频、选择路径、配置语言和模型、查看进度、失败恢复、打开结果文件，桌面 UI 对手测和产品体验都有直接价值。
- 同时，CLI/agent 入口也应保留。字幕生成是典型长任务工具，适合被脚本、自动化流程和 agent 直接调用。

### 14.2 产品定位
TransVortex 的产品定位为：

```text
Agent-callable Headless Core + Optional Desktop UI
```

也就是核心能力不绑定界面，稳定的 headless worker 是产品底座。CLI、桌面 UI、未来可能的服务端 API 都调用同一套 worker 协议。

```text
TransVortex Core
  ├─ Python worker：ASR / 翻译 / 对齐 / 导出
  ├─ JSONL event protocol：进度、日志、错误、产物
  ├─ Artifact store：任务状态、checkpoint、输出文件
  └─ Stable commands：run / resume / status / cancel / events / probe

Frontends
  ├─ CLI：给 agent、脚本、高级用户
  └─ Flutter Desktop App：给拖拽、配置、进度、结果管理
```

### 14.3 UI 方向
- 当前主体验桌面端使用 Flutter；`desktop/` 下的 Tauri 实现已经冻结，不建立新兼容约束。
- Flutter 负责窗口、文件选择、任务状态和用户交互，通过 typed client 调用 Python Local Service。
- Python worker 继续负责现有核心业务：FFmpeg、`faster-whisper`、provider 翻译、artifact/checkpoint。
- Local Service、Worker、未来 Supervisor 与托盘的生命周期边界见 `docs/DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`。
- 这种方式既保留 agent / CLI 自动化入口，也提供普通用户需要的桌面工作流。

### 14.4 为什么短期不全量 Rust 化
- FFmpeg 调用、任务管理、HTTP provider、桌面壳都可以用 Rust 实现。
- 但当前 ASR 依赖 `faster-whisper`，它是 Python 主路径，底层依赖 CTranslate2。短期把 ASR 从 Python 搬到 Rust 收益不高，风险较大。
- 因此保留 Python core/worker；Flutter 与 Windows native runner 只负责桌面交互、应用生命周期、进程监督和系统集成。
- 长期若需要进一步原生化，再评估 `whisper.cpp`、CTranslate2 C++ 绑定、ONNX 或其他本地 ASR 路径。

### 14.5 当前命令协议
CLI/worker 当前已支持的核心命令包括：

```text
transvortex run --input <video|srt> --src <lang> --tgt <lang> [--bilingual] [--json] [--stream-events]
transvortex resume --task-id <task-id> [--json] [--stream-events]
transvortex status <task-id> [--json]
transvortex events --task-id <task-id> [--follow]
transvortex cancel --task-id <task-id> [--json]
transvortex probe-provider [--strict]
transvortex asr --input <video> --src <lang>
transvortex translate --segments <segments|srt> --src <lang> --tgt <lang>
transvortex export --segments <segments.final.json> --format <srt|ass|both> --output <path>
transvortex result open/save --task-id <task-id>
transvortex reexport --task-id <task-id>
```

其中 `--json` 和 `events` 面向 agent、脚本和桌面 UI，保证机器可读。

### 14.6 当前事件协议
worker 通过结构化事件记录任务过程，供 CLI 和 Flutter Local Service 链路消费：

```json
{"type":"stage","stage":"INGEST","message":"Extracting audio","progress":0.05}
{"type":"progress","stage":"ASR","message":"segment 8/20","progress":0.42}
{"type":"artifact","name":"segments.raw.jsonl","path":"..."}
{"type":"error","stage":"TRANSLATE","message":"rate limit"}
{"type":"done","output_path":".../video.zh-CN.srt"}
```

事件协议是 UI 与内核解耦的关键。桌面 UI 不应解析自由文本日志，而应只消费结构化事件和 artifact 状态。

### 14.7 当前优先级
- 开发卫生：避免文档、README、实现和测试口径漂移；保持测试可在无真实 provider、无大视频、无本地 ASR 依赖时运行。
- 分层验收：协议层验证 JSON/JSONL、错误结构和密钥脱敏；字幕链路用 SRT/segments 跑通翻译、质量优化、导出和重导出；完整视频链路在依赖齐全时作为真实演示。
- 桌面工作台增强：错误解释、任务详情、artifact/log viewer、字幕预览和编辑体验。
- 运行环境体验：完善 FFmpeg/FFprobe、`faster-whisper`、provider env、输出目录权限等检查和提示。

### 14.8 阶段化路线
- R1：巩固 Windows 开发版，确保 CLI/worker、SRT/ASS 输出、任务恢复、桌面工作台形成稳定闭环。
- R2：增强桌面端任务详情、日志查看、字幕编辑和重导出体验。
- R3：Windows 安装基础已经落地；继续完成签名、对应源码托管、干净机验证和本机 ASR 按需安装体验。
- R4：macOS CPU 版；Linux 和 CUDA 作为后续高级目标。
- R5：按实际需求推进完整术语管理、Subtitle Refine Agent、Visual Context 和多厂商 ASR Gateway。

### 14.9 当前主要风险
- Python worker 打包：`faster-whisper`、CTranslate2、模型文件和可选 CUDA 动态库会增加分发复杂度。
- FFmpeg 分发：Windows 包已内置固定 LGPL shared runtime，公开发布仍需提供完整对应源码。
- CUDA 兼容：默认不应依赖 CUDA。CPU/int8 作为稳定默认，CUDA 作为高级设置。
- 质量体验：真实视频会出现重复片段、断句差、翻译漏行、字幕过长等问题，需要逐步加入质量守卫。
- 跨平台：真正复杂的是 Python worker、FFmpeg、ASR 模型和 GPU 支持在不同平台上的分发；当前仍以 Windows 为主。
