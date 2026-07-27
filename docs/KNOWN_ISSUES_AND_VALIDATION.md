# Known Issues And Validation Backlog

本文件记录已经观察到、但暂不进入高优先级开发的待验证问题。

这里的条目不是已承诺路线，也不是默认要立即实现的功能。它们用于保存真实使用中的现象、当前判断、验证条件和可能方向，避免讨论结论散落在聊天记录或路线文档里。

## OpenRouter 云 ASR 真实服务兼容性

状态：已完成最小真实服务验证，待长音频、多语言和真实内容人工验收。

当前实现：
- 已接入 OpenRouter `/api/v1/audio/transcriptions` JSON 传输、完整任务预检、用户级凭据解析、桌面设置入口和模型专项 profile。
- 当前显式支持 `openai/whisper-large-v3` 与 `x-ai/grok-stt-1.0`，不会自动开放 OpenRouter 模型目录中的其他 transcription 模型。
- Whisper profile 要求上游返回 segment timestamps；只有文本时明确失败。Grok profile 暂按短窗生成粗时间轴，并在界面标为“实验性”。
- OpenRouter 平台层会解析官方结构化错误，区分余额不足、权限、限流、请求拒绝和上游不可用；重试会读取有界的 `Retry-After`，成功与失败诊断都会保留不含凭据的 `X-Generation-Id`。
- 成功响应中的 `usage.cost`、`usage.seconds` 和 token 字段会按 generation ID 去重并聚合到 `source/asr/openrouter_usage.json` 与任务诊断；单次响应先写 usage receipt，后续 fallback、分裂重试、失败、取消或进程中断不会丢掉已发生的费用。Flutter 会区分完整的“OpenRouter 用量”和字段不全的“OpenRouter 已报告用量”。设置页另有普通 key 的 `/api/v1/key` 用量/限额查询，不发模型请求；需要 management key 的账户 `/credits` 不接入 ASR 凭据。最终费用仍以 OpenRouter Activity 和账单为准。
- 共享边界只覆盖 HTTP、错误和追踪元数据，不把 ASR profile、时间轴或请求字段与翻译 provider 共用。

已完成证据（2026-07-27）：
- 使用用户配置的 OpenRouter key 做了有界、极省用量的真实请求；没有在文档中保存密钥或 generation id。
- 0.25 秒静音 Whisper provider test 成功，验证了当前地址、凭据和基本协议。
- 3.447 秒合成英文语音经 `openai/whisper-large-v3` 返回准确文本和 `0-3.447125` 的 segment，响应含 usage 与 generation id；OpenRouter 实际路由到 Together，`usage.cost` 为 `0.000086178125` 美元。
- 同一音频经 `x-ai/grok-stt-1.0` 返回准确文本和 usage，但响应只有 `text + usage`，没有 `words` 或 `segments`；`usage.cost` 为 `0.00009583333333333334` 美元。
- 三次最小请求总费用约 `0.000188` 美元。该结果证明两个专项 profile 的基本真实调用可用，但不等于长音频或生产字幕质量已经验收。

尚缺证据：
- Whisper 的 prompt、长音频分片、跨分片时间轴和至少一种非英语素材仍需真实验证。
- Grok 仍需观察 OpenRouter 后续是否透出 word timestamps、说话人和多声道字段。xAI 原生 API 文档列出了 `words`、`diarize` 和 multichannel 能力；当前解析器会在响应真的出现 `words` 时归一化保留，但 OpenRouter 标准响应说明和本次真实响应都没有给出该字段，不能据此宣称已有 Grok 精确字幕。
- 仍需用真实内容人工对照文本质量、粗时间轴偏差，以及 OpenRouter 当前 STT 超时、文件大小、费用和数据处理边界。

验收条件：
- 使用可公开测试音频完成跨分片音频和至少一种非英语素材的真实请求，并保留脱敏后的响应结构与 generation 追踪信息。
- Whisper 结果具有稳定、单调且可用于字幕的 segment 时间轴；如果某条路由不支持 `verbose_json`，产品提示能明确引导切换方案。
- Grok 的粗时间轴偏差被量化；只有在确认 OpenRouter 持续透出相应字段后，才把 word timestamps、说话人或多声道能力从防御性解析提升为正式承诺。
- 确认 OpenRouter 当前 STT 超时、文件大小、费用和数据处理边界与产品提示一致。

暂不做：
- 不因为两个短音频请求成功就自动加入更多 OpenRouter ASR 模型。
- 不将模型页宣称的原生能力等同于 OpenRouter API 已经透出的标准字段。
- 不用整段文本静默伪造 Whisper 的精确字幕时间轴。

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

## ASMR profile 与专用人声检测

状态：待记录，低优先级实验方向。

背景：
- 当前 ASR 切分主要依赖 FFmpeg `silencedetect` 的响度静音边界，并用 overlap 和后续去重兜底。
- 对普通对白视频，这种切分方式通常足够；但 ASMR、低语、气声、呼吸、耳边拟声和环境音混合场景里，“低响度”不等于“无人声”，“有声”也不等于“需要字幕”。
- Hugging Face 上存在面向日语 ASMR / 低语场景的人声检测模型，例如 `TransWithAI/Whisper-Vad-EncDec-ASMR-onnx`。它不是 ASR 模型，不输出文字，而是给出更贴近 ASMR 场景的人声概率时间线。

当前判断：
- ASMR 专用 VAD 更适合被理解为“ASR 前置切窗 / 风险诊断组件”，而不是替代 ASR 的新模型。
- 它可能帮助减少 Whisper 类模型在低能量、弱声学证据、长窗口非语音区域里的循环幻觉，也可能帮助定位“ASR 输出长文本但 VAD 认为无人声”的高风险片段。
- 这类能力不应默认影响普通视频。更合适的产品语义是后续增加独立 `ASMR` 内容类型、ASMR profile，或 `voice_activity.profile: asmr` 这样的可选配置。

待验证方向：
- 用现有私有 ASR 评测样本，优先覆盖 clean 音频和带音效音频，先离线跑 ASMR VAD，输出人声概率时间线和候选语音窗口。
- 对比 FFmpeg 静音切分与 ASMR VAD 切分在低语、呼吸、拟声和长安静区间上的差异。
- 用 ASMR VAD 生成 5-10 秒短窗，分别喂给当前候选 ASR，例如 `SenseVoice-Small`、`faster-whisper/large-v3`、Kotoba-Whisper 或 Parakeet，对比漏听、重复幻觉、时间轴覆盖、切句粒度和耗时。
- 评估 VAD 辅助 hallucination risk 标记：当 ASR 在低人声概率区输出长文本或重复串时，是否能稳定标记为高风险，而不误伤真实低语台词。
- 明确产品语义：ASMR 场景里呼吸、拟声、摩擦音和环境声哪些需要进入字幕，哪些只应作为事件标签或直接忽略。

暂不做：
- 不把 ASMR VAD 作为默认 ASR 切分方式。
- 不在没有样本对照前新增用户可见的 ASMR 模式。
- 不让 ASMR profile 影响普通对白、访谈、影视或教学视频的默认切分策略。
- 不把 VAD 概率直接当作删除字幕的唯一依据；最多先用于切窗、风险标记和人工复核提示。

## FunASR / SenseVoice-Small 本地 ASR 支持评估

状态：待评估，低优先级增强。

背景：
- 当前本地 ASR 默认走 `faster-whisper` / `large-v3`。这条路径准确率基线较稳，但在长视频、本机 GPU 不强或 CPU 环境下速度成本较高。
- FunASR 不是单一模型，而是 ASR 推理框架和工具链；`SenseVoice-Small` 是其中适合优先评估的具体模型。
- FunASR 可以通过本地服务提供 OpenAI-compatible transcription 接口。产品语义上它仍是本地 ASR，因为音频不离开本机；代码接入上更像一个 localhost ASR provider。

当前判断：
- FunASR 的潜在收益主要在速度、低配机器可用性、VAD/标点/热词等 ASR 侧能力，而不是确定性替代 `large-v3` 的准确率。
- 第一版不应把 FunASR Python 依赖直接塞进当前 worker。更稳的实验路线是先支持 `funasr-server` 这种本地 HTTP 服务，避免 `torch`/CUDA 依赖和现有 `faster-whisper`/CTranslate2 环境互相影响。
- 配置和 UI 不应把 localhost FunASR 称为“云端 ASR”。它应被表达为“本地 ASR 服务”或“自托管 ASR provider”。

待验证方向：
- 用同一批代表性素材对比 `large-v3`、`large-v3-turbo`、FunASR + `SenseVoice-Small`，优先包含已知慢例、漏听例、多人重叠、强背景声、专名密集和长视频片段。
- 同时记录识别耗时、GPU/CPU 占用、显存、漏听率、重复/幻觉文本、专名错误、时间轴稳定性，以及对后续翻译质量的影响。
- 验证 FunASR OpenAI-compatible 响应是否能稳定映射为项目需要的 `start`、`end`、`text`、`confidence`、`speaker` 等字段；如字段不一致，应走 ASR response mapping，而不是在翻译层兼容原始格式。
- 增加本地服务 provider 语义时，应支持 `auth: none` 或等价机制，避免要求用户为 localhost 服务填写假 API key。
- 本地服务默认并发应保守，不直接复用云端 ASR 的高并发默认值，避免把单张 GPU 或单个服务进程打满。

暂不做：
- 不在没有对照结果前替换默认 `faster-whisper` / `large-v3` 路线。
- 不把 FunASR 作为“云端 ASR provider”宣传或展示。
- 不在第一阶段引入 FunASR in-process backend；除非本地服务方案已经验证有明显收益且部署体验可控。
