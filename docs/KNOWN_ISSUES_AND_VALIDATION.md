# Known Issues And Validation Backlog

本文件记录已经观察到、但暂不进入高优先级开发的待验证问题。

这里的条目不是已承诺路线，也不是默认要立即实现的功能。它们用于保存真实使用中的现象、当前判断、验证条件和可能方向，避免讨论结论散落在聊天记录或路线文档里。

## ASR 局部重复后的短时漏听

状态：待验证，低优先级优化。

现象：
- 使用本地 `faster-whisper` / `large-v3` 时，遇到高密度重复词、口吃式重复、多人重叠或强背景声，ASR 可能先输出局部重复文本。
- 重复之后的几秒语音可能被漏听，表现为后续一小段像“失聪”一样没有字幕，或者时间轴出现明显空洞。

当前判断：
- 这不应先归因于 `condition_on_previous_text`。当前默认配置里 `asr.local.condition_on_previous_text` 和 `asr.prompt.include_previous_text` 都是关闭的。
- 这也不应先通过缩短主 ASR 窗口处理。当前 `silence` 分片和约 120 秒上限是经验上更稳的默认值，盲目缩短可能引入更多边界问题。
- 更可能是 Whisper 类模型在局部高密度、重复或混响场景里的解码和时间戳对齐失稳。

待验证方向：
- 收集带有明确时间点的坏例，保留原始音频片段、`source/asr/rows/segment_*.json`、`source/segments.raw.jsonl` 和最终 normalized segments。
- 先用现有 artifact 做人工对照：检查坏例是否集中在 FFmpeg 静音分片边界、ASR window 边缘或单个窗口内部。
- 优先复用现有 FFmpeg 静音分片和 ASR 时间轴信息，确认“重复后短时漏听”是否稳定复现，以及是否和 overlap 合并有关。
- 如果要实验回补，只对疑似坏段前后加 padding 后局部重跑，不改变主流程的 120 秒窗口策略。
- 对比 `vad_filter`、`repetition_penalty`、`no_repeat_ngram_size`、`hallucination_silence_threshold` 等参数在坏段上的收益和副作用。
- 人声 VAD 或 word timestamps 只作为后续对照实验，不作为当前默认方案；引入前需要证明它们能明显提升漏听定位或回补效果。
- 评估修复是否真的提高漏听恢复率，并确认不会增加真实重复词误删、幻觉文本或时间轴错位。

暂不做：
- 不把全片默认 ASR 窗口改短作为首选方案。
- 不默认开启上一段文本提示。
- 不为了这个问题优先引入新的 VAD 依赖。
- 不在没有真实坏例和对照结果前实现自动回补逻辑。
