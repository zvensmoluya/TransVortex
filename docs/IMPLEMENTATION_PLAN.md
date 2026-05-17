# TransVortex V1.x 实施计划（当前开发快照）

## 版本与日期
- 版本：v1.x-dev
- 日期：2026-05-12

## 摘要
V1 先做 CLI 单机版和开发工作台，核心目标是：**低内存、可恢复、可被 agent/脚本调用**。
当前实现已经超过早期 V1.1 文档范围：CLI 不只包含 `run/resume/status`，还已经具备 `asr`、`translate`、`export`、`result`、`reexport`、`provider` 等开发态入口。

这不表示产品形状已经冻结。现阶段目标是把真实实现、文档和测试口径对齐，保留继续探索的空间。

## 当前已落地范围
- CLI / agent 入口：
  - `agent-info`
  - `run` / `resume` / `status` / `events` / `cancel` / `tasks`
  - `doctor` / `config show` / `probe-provider`
  - `asr` / `translate` / `export`
  - `provider save/delete/models/test/routing`
  - `result open/save` / `reexport`
- 核心 pipeline：
  - 视频分片抽音、ASR、chunk 翻译、校验、repair、对齐、字幕质量优化、SRT/ASS 导出
  - SRT 或 segments 输入的翻译链路，可以绕过视频 ASR
  - checkpoint、events、task artifact、取消和恢复
- Provider：
  - OpenAI/Anthropic/Gemini/custom 风格的文本 provider 适配
  - `providers.local.yaml` 私有配置
  - 零 token 本地协议预检
  - provider 管理命令供桌面端调用
- Desktop：
  - Tauri + React 开发工作台
  - 环境检查、provider/key 配置、启动任务、事件读取、历史任务、结果编辑和重导出

## 仍然不稳定的边界
- JSON/JSONL 机器输出要保持合法、可解析、无密钥泄露，但字段全集暂不冻结。
- `agent-info` 是当前协议说明，不是长期兼容承诺。
- 桌面端仍是开发工作台，不是发布安装包。
- Full video ASR pipeline 受本机性能、FFmpeg、`faster-whisper`、模型和 API key 影响，不作为所有开发机的唯一 V1 验收标准。
- Translation Memory、Refine Agent、Visual Context、多厂商 ASR Gateway 仍属于增强方向，不阻塞当前 V1.x。

## 关键约束
- 不整视频入内存：分片 + 流式 + 增量落盘
- ASR：本地 `faster-whisper` 和 OpenAI Transcriptions 云端 ASR 双路径
- 分片：`60s + 1s overlap`
- 翻译并发：默认 8（可配置）
- 恢复：按分片 checkpoint
- 输出：SRT / ASS / both，支持双语开关
- 移动端/安装包：暂不作为当前开发目标

## 公共接口与配置
- CLI：
  - `transvortex run --input ... --src ... --tgt ...`
  - `transvortex asr --input ... --src ...`
  - `transvortex translate --segments ... --src ... --tgt ...`
  - `transvortex export --segments ... --format ... --output ...`
  - `transvortex resume --task-id ...`
  - `transvortex status --task-id ...`
  - `transvortex events --task-id ...`
  - `transvortex result open --task-id ...`
  - `transvortex reexport --task-id ...`
- 配置优先级：`CLI 参数 > 环境变量 > YAML`
- Provider 配置：
  - `providers[].name`
  - `providers[].base_url`（可自定义）
  - `providers[].api_type`（openai/anthropic/gemini-compatible）
  - `providers[].compat_mode`（openai_chat / anthropic_messages / gemini_generate_content）
  - `providers[].env_key`（如 `ANTHROPIC_API_KEY`）
  - `providers[].models[]`
  - `providers[].auth`（bearer/header/query）
  - `providers[].endpoint`（path_template/method）
  - `providers[].request_mapping / response_mapping`
  - `providers[].capabilities`
  - `routing.primary / routing.fallback[]`
  - `limits.concurrency / timeout / retry`
- 说明：新增文本翻译兼容服务优先改配置，不改业务流程代码

## 协议兼容矩阵
- `openai_chat`：OpenAI 与 OpenAI-compatible 代理，默认提取 `choices[0].message.content`
- `openai_responses`：OpenAI Responses 风格，默认提取 `output_text` 或 `output[].content[].text`
- `openai_completions`：传统 completions 风格，默认提取 `choices[0].text`
- `anthropic_messages`：Anthropic Messages 协议，默认提取 `content[].text`
- `gemini_generate_content`：Gemini 原生协议，默认提取 `candidates[0].content.parts[].text`
- `custom_json`：自定义 JSON 模板和 response path
- 当前 provider adapter 的职责边界是文本翻译请求/响应适配。未来封面、关键帧、多模态理解应作为独立 Visual Context 阶段产出摘要，再注入翻译 prompt，不在 provider adapter 内直接扩成多模态网关。

## 向后兼容规则
- 若 `providers.yaml` 未配置 `compat_mode`，按 `api_type` 自动推断。
- 若未配置 `auth/endpoint/mapping`，自动套用协议默认模板。
- 旧版 `providers.yaml` 可继续运行。

## 失败策略与分类
- 同路由重试（指数退避，最多 `limits.retry`）
- 主路由失败后 fallback
- 行号一致性守卫失败视为 `mismatch_lines`
- 故障分类：`auth_error`, `rate_limit`, `timeout`, `network_error`, `bad_schema`, `mismatch_lines`

## 当前优先级
1. 开发卫生
   - 避免 `.gitignore` 误伤源码目录。
   - 保持文档和真实实现同步。
   - 保持测试可在无真实 provider、无大视频、无本地 ASR 依赖时运行。
2. 分层验收
   - 协议层：JSON/JSONL 输出合法、错误结构化、输出不泄露 secret。
   - 字幕链路：用 SRT 或 segments 跑 `translate -> quality -> export/reexport`，绕过 ASR。
   - 环境层：`doctor` 能准确报告 FFmpeg、ASR 依赖和 key 状态。
   - Full pipeline：只在硬件、依赖、模型和 key 具备时作为真实演示验收。
3. 桌面工作台增强
   - 错误解释、任务详情、artifact/log viewer、字幕预览和编辑体验。
4. 后续增强
   - Translation Memory、Subtitle Refine Agent、Visual Context、多厂商 ASR Gateway。

## 测试与验收
- 单元：
  - 配置加载与优先级
  - provider/base_url/model 动态解析
  - 分片编号与回填一致性
-  - 翻译校验、repair、字幕质量优化、SRT/ASS 导出
-  - task store、checkpoint、events、result workspace
-  - CLI worker 协议的基础行为
- 轻量集成：
  - SRT 或 segments 输入产出 SRT/ASS
  - resume 跳过已完成 chunk
  - provider 预检失败能返回结构化错误
- 真实集成：
  - Full video ASR + translate + export 只在硬件和依赖满足时运行
  - 本机性能不足时，不阻塞其他 V1.x 开发
- 当前不建议过早锁死完整 JSON 快照；优先锁软契约：
  - `--json` 必须是合法 JSON
  - `--stream-events` / `events` 必须是合法 JSONL
  - 错误必须包含稳定的基本字段
  - secret 不得出现在输出中

## 默认假设
- 不上传媒体到云端，只上传文本
- API Key 永不落盘，仅通过 `env_key` 从环境读取
- `providers.yaml` 支持后续扩展到多协议兼容服务端点
- V1.x 不实现多模态输入输出。若后续需要画面理解，优先抽关键帧生成 `visual/visual_context.json|md`，翻译主流程仍消费文本摘要。
