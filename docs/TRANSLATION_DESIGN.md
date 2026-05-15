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
  -> optional translation memory bootstrap
  -> size-bounded chunk planning
  -> sliding read-only context package
  -> first-pass translation
  -> deterministic validation
  -> repair bad rows
  -> optional translation memory update
  -> optional model review
  -> subtitle quality pass
  -> optional refine agent patches
  -> SRT / ASS / VTT / burn-in export
```

职责边界：

```text
ASR:
  只负责产出 Segment(id, start, end, text_src, confidence)

Translation:
  负责 text_src -> text_tgt
  负责上下文、prompt、provider、重试、repair
  可选负责 translation memory 的只读注入和 patch 生成

Subtitle quality:
  负责时间轴、CPS、断行、双语排版、重复/漏译告警

Refine agent:
  负责翻译完成后的自然语言精修，但只通过受控 patch 修改字幕

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
  chunk_lines: 120
  min_chunk_lines: 40
  max_chunk_lines: 200
  context_before_lines: 40
  context_after_lines: 20
  boundary_hints:
    punctuation: true
    pause_seconds: 2.0
    hard_pause_seconds: 6.0
```

强模型可以进一步调大：

```yaml
translation:
  chunk_lines: 200
  max_chunk_lines: 300
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
  context_before_lines: 40
  context_after_lines: 20
```

滑动上下文不会改变最终回填范围。系统只接受 `TRANSLATE_ONLY` 中的 id，context 区域若被模型输出，应视为多余 id 并触发校验失败或 repair。

这种策略比纯固定小块孤立翻译更连贯，也比整片一次输出更容易恢复和校验。

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

## 11. 翻译记忆与动态变量

翻译记忆用于解决长视频中人名、组织名、术语、称谓和风格规则的一致性问题。

它不应依赖模型在多次请求之间“自己记住”。当前翻译过程会分 chunk 并发请求模型，不同请求之间没有共享内部状态。正确做法是把记忆作为外部 artifact 管理：

```text
segments.raw.jsonl
  -> memory bootstrap
  -> memory/translation_memory.json
  -> chunk translation prompt injects confirmed memory as read-only context
  -> memory patch extraction
  -> code validates and merges patch
  -> memory/conflicts.jsonl for unresolved decisions
```

建议记忆结构：

```json
{
  "characters": [
    {
      "source": "John",
      "target": "约翰",
      "aliases": ["Johnny"],
      "notes": "male lead, informal tone",
      "confidence": 0.92
    }
  ],
  "terms": [
    {
      "source": "The Order",
      "target": "教团",
      "domain": "organization",
      "confidence": 0.82
    }
  ],
  "style_rules": [
    "Use concise natural Chinese subtitles.",
    "Keep profanity strength close to source."
  ],
  "open_questions": [
    {
      "source": "Mercury",
      "candidates": ["水星", "墨丘利"],
      "reason": "unclear if planet, codename, or person"
    }
  ]
}
```

记忆更新不应混在翻译正文中。推荐让模型单独输出 memory patch：

```json
{
  "add_terms": [
    {
      "source": "The Order",
      "target": "教团",
      "domain": "organization",
      "evidence_ids": [120, 121]
    }
  ],
  "conflicts": [
    {
      "source": "Commander",
      "targets": ["指挥官", "司令"],
      "evidence_ids": [42, 318]
    }
  ]
}
```

合并规则：

- 代码负责合并、去重、版本化和冲突记录。
- 已确认记忆在翻译 prompt 中是只读约束，不允许模型在正文中自行改写。
- 低置信度或多候选项目进入 `open_questions` 或 `conflicts`，不自动覆盖已有译名。
- 并发翻译时，memory patch 可以先追加到 JSONL，后续由单线程 merge step 统一处理，避免并发写冲突。
- 用户或 refine agent 的明确指令优先级高于模型自动发现的低置信度记忆。

建议 artifact：

```text
memory/
  translation_memory.json
  memory_patches.jsonl
  conflicts.jsonl
  decisions.jsonl
```

## 12. 模型审校

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

## 13. 字幕精修 Agent

字幕精修 Agent 是翻译完成后的受控 patch engine。它提供类似“自然语言改字幕”的体验，但不允许模型任意改文件。

推荐流程：

```text
user instruction
  -> select scope
  -> read segments + context + quality + memory + optional visual context
  -> model proposes patches
  -> deterministic patch validation
  -> preview / approval
  -> apply patches to final/segments.final.json
  -> rerun subtitle quality
  -> reexport SRT/ASS
```

范围选择可以来自三类来源：

- 用户手选：id 范围、时间范围、桌面端选中的字幕行。
- 系统筛选：CPS 超标、行宽超标、术语冲突、特定关键词或角色出现范围。
- agent 检索：模型先根据用户指令调用检索工具提出待处理范围，再生成 patch。

V1 patch schema 应保持简单，只允许修改 `text_tgt`：

```json
{
  "patches": [
    {
      "id": 128,
      "text_tgt": "你到底想干什么？",
      "reason": "更口语化，保留质问语气"
    }
  ]
}
```

默认禁止：

- 修改 `id`
- 修改 `start/end`
- 修改 `text_src`
- 增删 segment
- 输出整片重写结果替代 patch

可用的受控工具可以设计为：

```text
search_segments(query)
read_window(start_id, end_id)
read_quality_issues()
read_memory()
read_visual_context()
propose_patches(scope, instruction)
validate_patches(patches)
apply_patches(patches)
reexport()
```

建议工作模式：

```text
safe mode:
  只生成候选 patch，不应用。

review mode:
  生成 patch，用户确认后应用。

auto mode:
  自动应用低风险 patch，高风险 patch 留给用户确认。
```

建议 artifact：

```text
refine/
  runs/<run_id>/instruction.txt
  runs/<run_id>/scope.json
  runs/<run_id>/candidate_patches.json
  runs/<run_id>/applied_patches.json
  runs/<run_id>/quality_before.json
  runs/<run_id>/quality_after.json
```

精修 Agent 可以消费 translation memory 和 visual context：

- memory 用于统一译名、术语、角色称谓。
- visual context/OCR 用于判断画面文字、组织名、场景氛围、人物关系。
- 视觉信息只作为参考，不绕过 patch validation。

## 14. Artifact 与恢复

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
memory/
  translation_memory.json
  memory_patches.jsonl
  conflicts.jsonl
refine/
  runs/<run_id>/
```

## 15. 配置建议

未来可在 `pipeline.yaml` 加：

```yaml
translation:
  chunking: size_bounded
  chunk_lines: 120
  min_chunk_lines: 40
  max_chunk_lines: 200
  context_before_lines: 40
  context_after_lines: 20
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
  memory:
    enabled: false
    bootstrap: true
    update_after_chunk: false
    inject_confirmed_terms: true
  refusal_detection:
    enabled: true
refine:
  enabled: false
  default_mode: review
  allow_timing_edits: false
  allow_segment_insert_delete: false
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

## 16. 里程碑

建议按以下顺序实现：

1. 增量落盘：chunk 完成即写入结果和 checkpoint。
2. 可配置 `chunk_lines` / `context_before_lines` / `context_after_lines`。
3. Prompt 分层：固定格式约束 + 用户 `style_prompt`。
4. 拒绝话术、空译文、错编号检测。
5. bad row repair，不整批重翻。
6. 滑动只读上下文。
7. 容量主导分组 + 停顿/标点软边界。
8. 根据 provider/model 能力自动推荐 chunk/context 默认值。
9. translation memory bootstrap：术语、人名、角色表。
10. translation memory patch：chunk 后动态更新与冲突记录。
11. 可选模型审校 patch。
12. 全局一致性检查。
13. 字幕精修 Agent：自然语言生成受控 patch。
14. Visual Context/OCR 与 memory/refine 联动。

## 17. 关键原则

- 不让模型管理时间轴。
- 不让用户 prompt 覆盖格式约束。
- 不把整部视频一次性扔给模型。
- 不因单行失败重做整片。
- 不把拒绝文本当作有效译文。
- 不把 SRT/ASS/VTT 当作翻译逻辑的一部分；它们只是导出格式。
- 不让模型直接任意改字幕文件；模型提出 patch，代码验证和应用。
- 不依赖模型隐式记忆；长期一致性必须落到结构化 artifact。
