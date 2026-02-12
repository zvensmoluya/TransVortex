# TransVortex V1.1 实施计划（模型调用兼容层）

## 版本与日期
- 版本：v1.1
- 日期：2026-02-12

## 摘要
V1 先做 CLI 单机版，核心目标是：**极致速度、低内存、可恢复**。  
模型接入升级为 **协议适配器 + 能力声明 + 映射配置**：通过 `providers.yaml` 自定义厂商、模型、`base_url`、`compat_mode`、认证方式、endpoint、请求/响应映射与能力约束；密钥只从环境变量读取（由 `env_key` 映射）。

## 关键约束（已锁定）
- 不整视频入内存：分片 + 流式 + 增量落盘
- ASR：`faster-whisper`
- 分片：`60s + 1s overlap`
- 翻译并发：固定 8（可配置）
- 恢复：按分片 checkpoint
- 输出：SRT 单语，支持双语开关
- 安卓 V1：仅任务发起 + 结果下载（重计算在服务端）

## 计划落盘要求
- 目标文件：`docs/IMPLEMENTATION_PLAN.md`
- 后续每次方案调整都更新该文件（版本号 + 日期）

## 公共接口与配置（重点变更）
- CLI：
  - `transvortex run --input ... --src ... --tgt ...`
  - `transvortex resume --task-id ...`
  - `transvortex status --task-id ...`
- 配置优先级：`CLI 参数 > 环境变量 > YAML`
- `providers.yaml`（新增、核心）：
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
- 说明：新增兼容服务优先改配置，不改业务流程代码

## 协议兼容矩阵
- `openai_chat`：OpenAI 与 OpenAI-compatible 代理，默认提取 `choices[0].message.content`
- `anthropic_messages`：Anthropic Messages 协议，默认提取 `content[].text`
- `gemini_generate_content`：Gemini 原生协议，默认提取 `candidates[0].content.parts[].text`

## 向后兼容规则
- 若 `providers.yaml` 未配置 `compat_mode`，按 `api_type` 自动推断。
- 若未配置 `auth/endpoint/mapping`，自动套用协议默认模板。
- 旧版 `providers.yaml` 可继续运行。

## 失败策略与分类
- 同路由重试（指数退避，最多 `limits.retry`）
- 主路由失败后 fallback
- 行号一致性守卫失败视为 `mismatch_lines`
- 故障分类：`auth_error`, `rate_limit`, `timeout`, `network_error`, `bad_schema`, `mismatch_lines`

## 模块实现顺序
1. 搭建 CLI、任务状态机、artifact 目录、checkpoint
2. ffmpeg 分片抽音（copy 优先，必要时转码）
3. faster-whisper 分片识别，输出 `segments.raw.jsonl`
4. chunk 编号与翻译输入组装
5. Provider Adapter（读取 `providers.yaml`），支持自定义 `base_url`
6. 主备路由、重试、限流（固定8默认，可配置）
7. 对齐、质量校验、SRT 导出
8. resume/status 与日志指标完善

## 测试与验收
- 单元：
  - 配置加载与优先级
  - provider/base_url/model 动态解析
  - 分片编号与回填一致性
- 集成：
  - 端到端产出 SRT
  - 主模型失败自动切备
  - 中断后 resume 可续跑
- 性能：
  - 内存峰值不随视频大小线性增长
  - TTFS 20–60 秒（硬件允许时）

## 默认假设
- 不上传媒体到云端，只上传文本
- API Key 永不落盘，仅通过 `env_key` 从环境读取
- `providers.yaml` 支持后续扩展到多协议兼容服务端点
