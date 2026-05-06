# TransVortex 翻译模块设计说明

## 1. 目标

翻译模块的目标不是简单调用一次模型，而是把 ASR 产出的时间轴文本转换成可校验、可恢复、可审校、可导出的字幕译文。

核心目标：

- 保持字幕时间轴和 segment id 稳定。
- 支持长视频分批翻译，不把整部视频一次性塞给模型。
- 支持用户自定义文风，但不允许破坏返回格式约束。
- 忠实翻译用户提供的字幕内容，包括脏话、成人台词、冒犯性表达、玩笑和反讽，不主动审查或改写。
- 用代码处理确定性问题，用模型处理语义、上下文和文风问题。
- 每个 chunk 可独立重试、修复、落盘和恢复。

## 2. 当前实现概览

当前实现是 MVP 级分批编号翻译：

```text
Segment(id, start, end, text_src)
  -> number_and_chunk_segments()
  -> [id] text_src lines
  -> LLM provider translate_batch()
  -> parse [id] text_tgt lines
  -> validate id set
  -> apply_translations()
  -> export_srt()
```

当前 prompt 的核心约束是：

```text
You are a subtitle translation engine.
Translate from {source_lang} to {target_lang}.
Keep numbering exactly unchanged, output only translated lines.
Do not add explanations.
```

优点：

- 简单，容易恢复和并发。
- 只上传文本，不上传媒体。
- 编号回填清晰，不容易打乱时间轴。
- 适合 MVP 和长视频基础处理。

不足：

- 固定按条数分组，缺少语义边界。
- chunk 之间上下文弱，术语、人名、梗和语气可能不一致。
- prompt 不支持用户自定义文风、术语表、目标受众。
- 缺少拒绝话术检测；模型若返回带编号的拒绝文本，可能被当作译文。
- 翻译 chunk 成功后目前不是立即落盘，崩溃时会损失已完成结果。

## 3. 目标架构

专业化后的翻译流程建议如下：

```text
ASR segments
  -> source normalization
  -> size-bounded chunk planning
  -> sliding read-only context package
  -> first-pass translation
  -> deterministic validation
  -> repair bad rows
  -> optional model review
  -> subtitle quality pass
  -> SRT / ASS / VTT / burn-in export
```

职责边界：

```text
ASR:
  只负责产出 Segment(id, start, end, text_src, confidence)

Translation:
  负责 text_src -> text_tgt
  负责上下文、prompt、provider、重试、repair

Subtitle quality:
  负责时间轴、CPS、断行、双语排版、重复/漏译告警

Exporter:
  只负责格式输出，如 SRT / ASS / VTT / burn-in
```

## 4. Chunk 分组策略

当前按固定条数分组。后续不建议把 ASR 停顿作为主分组策略，也不建议默认整片一次性翻译。

最终推荐策略：

```text
size-bounded chunks + sliding read-only context
```

也就是：chunk 的主体由容量控制，停顿、标点和 ASR 置信度只作为软边界信号。

原因：

- ASR 输出经常没有标点，也没有稳定句子边界。
- 停顿不等于语义结束，电影对白、访谈、演讲里尤其明显。
- 若按停顿硬切，可能导致一句一组或上下文过碎，翻译质量反而下降。
- 大上下文模型可以提供更多上下文，但长输出仍容易出现漏编号、格式漂移和失败重试成本过高。

分组输入：

- segment id
- start / end
- text_src
- source language
- 目标 chunk 行数
- 最大 chunk 行数
- 估算输入 token
- 估算输出 token
- provider/model 上下文窗口能力
- 可选边界信号：停顿、标点、ASR confidence

分组规则建议：

- 默认按 `chunk_lines` 或 token 预算累计 segment。
- 到达目标大小附近后，在允许浮动范围内优先选择更自然的边界。
- 边界优先级可参考：标点 > 长停顿 > 短停顿 > 固定容量切分。
- 若找不到好边界，按容量硬切，保证可控性。
- 不因一个停顿立即切组，除非已接近目标容量或达到硬上限。
- 保留原 segment id 和时间轴；translation chunk 只是模型工作单元。

示例配置：

```yaml
translation:
  chunk_lines: 40
  min_chunk_lines: 20
  max_chunk_lines: 80
  context_before_lines: 20
  context_after_lines: 10
  boundary_hints:
    punctuation: true
    pause_seconds: 2.0
    hard_pause_seconds: 6.0
```

强模型可以调大：

```yaml
translation:
  chunk_lines: 120
  max_chunk_lines: 200
  context_before_lines: 80
  context_after_lines: 40
```

弱模型或兼容性较差的 provider 应保守：

```yaml
translation:
  chunk_lines: 30
  max_chunk_lines: 50
  context_before_lines: 10
  context_after_lines: 5
```

## 5. 滑动上下文包

不建议整部字幕一次翻译。更稳的做法是让模型看到前后文，但只翻译当前 chunk。

```text
Context before:
  只读，不翻译

Translate only:
  必须逐 id 翻译

Context after:
  只读，不翻译
```

示例：

```text
Use the context only to understand tone, references, pronouns, and jokes.
Translate only the lines in TRANSLATE_ONLY.

CONTEXT_BEFORE
[95] ...
[96] ...

TRANSLATE_ONLY
[97] ...
[98] ...
[99] ...

CONTEXT_AFTER
[100] ...
[101] ...
```

这样可以提升上下文理解，同时避免模型翻译不该翻译的行。

推荐默认：

```yaml
translation:
  context_before_lines: 20
  context_after_lines: 10
```

滑动上下文不会改变最终回填范围。系统只接受 `TRANSLATE_ONLY` 中的 id，context 区域若被模型输出，应视为多余 id 并触发校验失败或 repair。

这种策略比纯固定 40 行孤立翻译更连贯，也比整片一次输出更容易恢复和校验。

## 6. Prompt 分层

Prompt 应分成固定系统约束和用户可编辑文风两层。

固定系统约束不可由用户覆盖：

- 只翻译 `TRANSLATE_ONLY`。
- 保持 id 完全一致。
- 不漏行、不合并、不拆分 id。
- 不解释、不总结、不输出 Markdown。
- 不翻译 context 区域。
- 输出格式必须可解析。

用户可编辑部分用于表达偏好：

- 文风
- 口语化程度
- 目标受众
- 是否保留脏话和粗口力度
- 是否本地化梗
- 人名、地名、术语表
- 是否偏直译或意译

建议配置：

```yaml
translation:
  style_preset: subtitle_natural
  style_prompt: |
    Translate as natural Chinese subtitles.
    Keep the wording concise, spoken, and context-aware.
    Preserve profanity, insults, jokes, sarcasm, adult references, and character voice faithfully.
    Do not censor, soften, moralize, summarize, or add explanations.
```

## 7. 内容风险与拒绝处理

字幕翻译的输入是用户提供的已有内容。目标行为是忠实翻译，不新增违法或露骨细节，不主动审查、道德评价或拒绝。

Prompt 应明确：

```text
This is translation of user-provided subtitle text.
Translate faithfully, including profanity, offensive language, sexual references, or violent dialogue if present.
Do not censor, moralize, refuse, summarize, or add content.
```

确定性拒绝检测应覆盖常见模式：

- `I can't help with that`
- `I cannot translate`
- `I'm sorry`
- `抱歉`
- `无法协助`
- `不能提供`
- `违反政策`
- 输出解释而非译文

处理策略：

1. 若整批输出无编号或编号不完整，判定为格式失败，重试。
2. 若个别行疑似拒绝，标记 bad row。
3. 优先只 repair bad row，不整批重翻。
4. repair prompt 强调“只做忠实翻译，不新增内容，不拒绝”。
5. 多次失败后可切 fallback 模型。
6. 仍失败则任务进入 `FAILED`，并保留坏行和错误原因。

## 8. 输出格式

当前 `[id] text` 格式可继续作为通用兼容格式。

优点：

- 对 OpenAI / Anthropic / Gemini 兼容接口都简单。
- 人类可读，便于调试。
- 失败时容易定位。

可选升级：

```json
[
  {"id": 97, "text_tgt": "..."},
  {"id": 98, "text_tgt": "..."}
]
```

JSON 适合支持稳定结构化输出的 provider。短期不建议强制所有 provider 使用 JSON，因为兼容模型可能对 JSON 稳定性不同。

## 9. 确定性校验

翻译结果必须通过代码校验，不依赖模型自称成功。

校验项：

- 返回 id 集合等于请求 id 集合。
- 没有多余 id。
- 没有漏 id。
- 每个 `text_tgt` 非空。
- 输出没有解释性前后缀。
- 输出没有疑似拒绝话术。
- 译文长度没有极端异常。
- 未翻译比例不异常。
- 不包含 context 区域 id。

校验结果分级：

```text
ERROR:
  必须 repair 或失败，例如漏行、空译文、错编号。

WARNING:
  可继续但记录，例如过长、疑似直译、CPS 过高。
```

## 10. Repair 流程

不建议因为一个坏行重翻整个 chunk。

推荐 repair 单元：

```text
bad row -> repair prompt -> validate -> write patch
```

repair 输入包含：

- 坏行 id 和原文
- 同 chunk 上下文
- 当前坏译文，若存在
- 失败原因
- 用户 style prompt

repair 输出仍然必须是同一个 id。

repair 成功后写入同一个 chunk result，或写入独立 patch artifact：

```text
translate/
  segments.translated.jsonl
  repairs.jsonl
```

## 11. 模型审校

模型审校是可选增强，不应默认重写整部字幕。

审校目标：

- 人名、术语、称呼一致。
- 梗、反讽、双关更自然。
- 口语化和角色语气更稳定。
- 发现明显误译、漏译、过度审查。

推荐输出 patch，不输出整片字幕：

```json
[
  {
    "id": 120,
    "text_tgt": "...",
    "reason": "term consistency"
  }
]
```

审校 patch 仍需通过 deterministic validation。

## 12. Artifact 与恢复

翻译是长任务，必须增量落盘。

目标行为：

```text
chunk 完成一个
  -> 立即 append segments.translated.jsonl
  -> 更新 checkpoint.translate_done_chunks
  -> 写 progress event
```

崩溃或取消后 resume：

- 读取已完成 chunk。
- 跳过已完成 chunk。
- 只重做缺失或失败 chunk。
- repair 也应可恢复。

建议 artifact：

```text
translate/
  chunks.json
  segments.translated.jsonl
  validation.jsonl
  repairs.jsonl
  review_patches.jsonl
```

## 13. 配置建议

未来可在 `pipeline.yaml` 加：

```yaml
translation:
  chunking: size_bounded
  chunk_lines: 40
  min_chunk_lines: 20
  max_chunk_lines: 80
  context_before_lines: 20
  context_after_lines: 10
  boundary_hints:
    punctuation: true
    pause_seconds: 2.0
    hard_pause_seconds: 6.0
  style_preset: subtitle_natural
  style_prompt: |
    Translate as natural Chinese subtitles.
    Preserve tone, jokes, profanity, and adult references faithfully.
    Do not censor, explain, or add content.
  output_format: numbered_lines
  repair:
    enabled: true
    max_attempts: 2
  review:
    enabled: false
    mode: patch_only
  refusal_detection:
    enabled: true
```

未来可在 `providers.yaml` 保持 provider 协议配置，不放用户文风。provider 文件负责“怎么调用模型”，pipeline 文件负责“字幕翻译策略”。

provider 能力可逐步扩展，用于自动选择 chunk/context 默认值：

```yaml
capabilities:
  context_window_tokens: 200000
  max_output_tokens: 8192
  reliable_json: true
```

默认策略应根据模型能力保守估算输入/输出预算，而不是只看上下文窗口。上下文大不等于长输出一定稳定。

## 14. 里程碑

建议按以下顺序实现：

1. 增量落盘：chunk 完成即写入结果和 checkpoint。
2. 可配置 `chunk_lines` / `context_before_lines` / `context_after_lines`。
3. Prompt 分层：固定格式约束 + 用户 `style_prompt`。
4. 拒绝话术、空译文、错编号检测。
5. bad row repair，不整批重翻。
6. 滑动只读上下文。
7. 容量主导分组 + 停顿/标点软边界。
8. 根据 provider/model 能力自动推荐 chunk/context 默认值。
9. glossary / 术语表。
10. 可选模型审校 patch。
11. 全局一致性检查。

## 15. 关键原则

- 不让模型管理时间轴。
- 不让用户 prompt 覆盖格式约束。
- 不把整部视频一次性扔给模型。
- 不因单行失败重做整片。
- 不把拒绝文本当作有效译文。
- 不把 SRT/ASS/VTT 当作翻译逻辑的一部分；它们只是导出格式。
