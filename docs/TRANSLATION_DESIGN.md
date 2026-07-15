# TransVortex 翻译架构

本文只描述当前翻译链路的稳定边界。可调字段和示例以 [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md) 为准，未来事项以 [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md) 为准。

## 1. 输入与输出

翻译输入统一为带稳定 `id` 和时间轴的 `source/segments.normalized.jsonl`。视频、音频、内嵌字幕和 SRT 在进入翻译前都先归一化为同一种 `Segment`。

翻译只负责 `text_src -> text_tgt`，不能修改：

- `id`
- `start` / `end`
- `text_src`
- segment 数量和顺序

翻译完成后生成结构化 final segments，再由独立 renderer 输出 SRT、ASS、WebVTT 或 LRC。

## 2. 当前流程

```text
normalized source segments
  -> optional preset memory load
  -> optional whole-document memory bootstrap
  -> capacity-aware chunk planning
  -> read-only before / after context
  -> provider translation request
  -> id and content validation
  -> format recovery or bounded repair
  -> incremental result and checkpoint write
  -> alignment / subtitle quality
  -> final segments and subtitle renderers
```

每个翻译分片独立落盘。取消、崩溃或继续任务时，Worker 读取 checkpoint 并跳过已经完成的分片。

## 3. 分片与模型容量

默认使用容量感知分片，而不是把整片一次性发送给模型：

- 模型级用户覆盖优先于全局模型目录和连接级限制。
- 模型目录与连接限制同时存在时取较低上限。
- 容量未知时使用保守行数，不把未知解释为无限。
- 标点和停顿只能作为软边界，硬上限仍由输入、输出预算和最大行数决定。
- 当前分片只翻译 `TRANSLATE_ONLY`，前后文只读，不进入回填范围。
- 明确容量错误可以触发局部自适应拆分；timeout、429、5xx 和格式错误使用各自的重试或修复策略。

## 4. Prompt 边界

系统约束与用户风格分开：

- 系统 prompt 固定编号、翻译范围、输出格式和禁止解释等协议要求。
- 用户风格只影响措辞、语气、本地化和字幕压缩倾向，不能覆盖格式约束。
- 术语记忆作为结构化只读上下文注入，不依赖模型跨请求隐式记忆。
- Prompt 文件位于 `prompts/translation/` 和 `prompts/memory/`，代码保留最小兜底文本。

## 5. 校验与修复

模型返回必须经过代码校验：

- 请求与返回的 id 集合一致。
- 没有空译文、多余 id、漏行或上下文 id。
- 没有解释性前后缀或明显拒绝话术。
- 译文长度、未翻译比例和格式没有极端异常。

处理顺序是：

1. 同一上下文下做一次轻量格式恢复。
2. 对连续缺失行做有界批量补回。
3. 对少量坏行做有上限的单行修复。
4. 容量问题触发局部拆分。
5. 仍失败时保留 artifact 和结构化错误，不伪造成功。

模型请求只在真实请求开始时计数；模型返回和本地拆分不重复计数。请求按术语初始化、分片翻译、术语更新、格式恢复、批量补回、单行修复和质量处理分类。

## 6. 术语记忆

当前术语记忆由几种不同能力组成：

- 预设术语表：用户选择的人工或项目术语。
- 运行时术语库：当前任务自动生成的 `translation_memory.json`。
- bootstrap：翻译前从整片 source segments 初始化术语建议。
- inject：按当前分片命中关系和强度把术语注入翻译。
- patch：翻译过程中按窗口合并模型提出的术语更新。
- 受保护条目：人工确认内容，自动 patch 不能覆盖。

`memory.enabled` 是总开关；`bootstrap`、`inject` 和 `patch` 分别控制生成、使用和动态维护。主窗口的“自动生成术语建议”只控制生成相关行为，不代表关闭已有人工术语的使用。

完整术语审看、保护、合并和跨任务复用仍是产品待办。

## 7. 主要工件

```text
source/segments.normalized.jsonl
chunks/chunks.json
translate/segments.translated.jsonl
translate/validation.jsonl
translate/repairs.jsonl
memory/translation_memory.json
memory/memory_patches.jsonl
quality/
final/segments.final.json
output/
```

工件用于恢复、审计和结果编辑。模型不能直接改写这些文件；模型只返回翻译或修改建议，代码负责校验和落盘。

## 8. 扩展边界

- 字幕精修应作为受控 patch 流程，只修改允许字段，并支持预览、校验和回滚。
- Visual Context 应先生成短文本或结构化摘要，再注入翻译；不能要求所有翻译 provider 支持图片。
- 多模型审校默认输出 patch，不整片重写。
- 字幕质量、时间轴和格式渲染继续位于 translation 之外。
