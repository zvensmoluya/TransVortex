# TransVortex 云端 ASR 生态与适配方向

## 1. 当前判断

当前 TransVortex 的云端 ASR 首先面向 OpenAI Transcriptions API。

现有实现路线是：

```text
OpenAI /v1/audio/transcriptions adapter
```

也就是：

- 将 FFmpeg 切出的音频片段上传到 `/v1/audio/transcriptions`。
- 传入 `model`、`response_format=verbose_json`、`temperature`、`timestamp_granularities[]` 等 OpenAI transcription 字段。
- 优先解析响应里的 `segments[]`。
- 若服务只返回整段 `text`，当前只能退化成一条弱时间轴结果，不适合高质量字幕。

因此，当前最稳的云端 ASR 目标是 OpenAI `whisper-1`。多厂商 ASR provider gateway 是后续方向，不影响当前 OpenAI 适配优先级。

参考：

- OpenAI Speech to Text: https://platform.openai.com/docs/guides/speech-to-text
- OpenAI Audio Transcriptions API: https://platform.openai.com/docs/api-reference/audio/createTranscription

## 2. 为什么云端 ASR 需要独立 provider 层

翻译 provider 大多可以抽象成“输入文本 prompt，输出文本 response”。ASR provider 更复杂，因为不同厂商的调用形态差异很大：

```text
direct upload:
  上传音频，立即返回转录结果。

submit/query async job:
  先提交任务，再轮询或回调拿结果。

url-based transcription:
  传音频 URL，服务端异步拉取文件。

streaming transcription:
  WebSocket 或 streaming API，适合实时字幕和语音 agent。
```

响应结构也不统一：

```text
plain text
segments / utterances
word timestamps
speaker labels
confidence
punctuation / normalization
profanity filtering
hotwords / keyterms
diarization
```

所以云端 ASR 不应长期复用翻译 provider 的协议映射模型。更合适的是新增 ASR provider gateway，明确 provider 的能力与返回结构。

## 3. 候选云端 ASR 服务

### OpenAI

当前项目最容易接入的是 `whisper-1`，因为它支持当前代码依赖的 `verbose_json` 和 segment 时间轴。

OpenAI 也提供更新的转录模型，例如 `gpt-4o-transcribe`、`gpt-4o-mini-transcribe` 和带说话人区分方向的转录能力。但这些模型的 response format 和时间戳能力需要单独适配，不能简单等同于 `whisper-1`。

适配价值：

- 国际化和通用场景好。
- 与当前云端 ASR 实现最接近。
- 新模型可能有更好的识别质量，但要确认时间戳、分段和字幕工作流兼容性。

参考：

- https://platform.openai.com/docs/guides/speech-to-text
- https://developers.openai.com/api/docs/models/gpt-4o-transcribe

### 火山引擎 / 豆包语音

火山引擎豆包语音提供大模型录音文件识别能力。其标准版偏 `submit/query` 两阶段，极速版 `volc.bigasr.auc_turbo` 更接近一次请求返回。

它的结果结构包含 `utterances`、`start_time`、`end_time`、`words` 等字段时，对字幕生成很有价值。

适配价值：

- 中文、方言和国内视频场景值得优先评估。
- utterance/word 时间戳天然适合字幕切分。
- 需要实现火山的认证、任务提交/查询和响应解析。

参考：

- 大模型录音文件识别 API: https://www.volcengine.com/docs/6561/1354868
- 大模型录音文件极速版识别 API: https://www.volcengine.com/docs/6561/1631584

### Azure AI Speech

Azure Speech-to-Text REST API 覆盖 fast transcription、batch transcription 和 custom speech。Batch 适合长音频和批量文件，fast transcription 适合较快返回结果。

适配价值：

- 企业和多地区部署友好。
- 支持 batch/custom speech 路线。
- 需要处理 Azure 的区域、版本、异步任务和返回格式。

参考：

- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text
- https://learn.microsoft.com/en-us/azure/ai-services/speech-service/batch-transcription-create

### Google Cloud Speech-to-Text

Google Cloud Speech-to-Text V2 的 Chirp 3 是多语种 ASR 方向的重要候选。它支持多种识别方式，并有自动标点、说话人、适配等能力组合。

适配价值：

- 多语种和全球化场景强。
- Batch/streaming/recognize 形态适合长期扩展。
- 配置和返回结构比 OpenAI-style 更复杂。

参考：

- Chirp 3: https://cloud.google.com/speech-to-text/v2/docs/chirp-model

### Deepgram

Deepgram Nova-3 等模型偏实时、低延迟和大规模吞吐。它同时覆盖 streaming 和 prerecorded transcription。

适配价值：

- 实时字幕、会议、语音 agent 场景强。
- API 设计适合高并发和低延迟。
- 对字幕文件生成也可用，但需要映射 utterance/word 时间轴。

参考：

- https://developers.deepgram.com/docs/models-languages-overview

### AssemblyAI

AssemblyAI Universal 系列偏成品化语音理解平台。Universal-3 Pro 支持 prompting、keyterms、方言和复杂音频场景。

适配价值：

- keyterms/prompting 与字幕术语记忆方向契合。
- 适合需要领域词和说话内容理解的场景。
- 需要适配异步任务和返回结果。

参考：

- https://www.assemblyai.com/docs/getting-started/models
- https://www.assemblyai.com/docs/speech-to-text

### 腾讯云、阿里云、百度智能云

国内云厂商 ASR 在中文、方言、热词、说话人、会议和媒体场景上都有成熟产品。它们不小众，但接口和能力模型通常与 OpenAI-style transcription 不同。

适配价值：

- 国内网络、中文语音、方言和合规环境更友好。
- 需要逐家处理认证、异步任务、热词、脏词过滤和时间戳结构。

参考：

- 腾讯云 ASR: https://intl.cloud.tencent.com/product/asr
- 腾讯云录音文件识别: https://intl.cloud.tencent.com/document/product/1118/66925
- 阿里云智能语音交互: https://ai.aliyun.com/nls/

## 4. 速度、成本与审查

云端 ASR 通常会比本地 CPU ASR 更快，尤其是长音频和较大模型场景。但速度不只取决于模型：

- 音频时长仍然是主成本。
- 上传速度和网络稳定性会影响端到端时间。
- 异步任务可能有排队时间。
- 当前项目若顺序提交每个音频片段，云端优势会被削弱；后续应支持云端 ASR 分片并发。
- 本地 CUDA 在隐私和稳定成本上仍有优势。

内容处理要区分两类：

```text
profanity filter:
  一些厂商提供显式开关，可屏蔽、替换或保留脏词。

platform policy:
  云服务会受各自平台政策约束，极端或违法内容可能被拒绝、标记或影响账号。
```

字幕转写默认目标应是忠实转录。若 provider 有 profanity filter，应默认关闭或让用户显式选择。

## 5. 推荐实现路线

### 阶段 1：把现有 whisper-1 路线跑稳

- 明确当前云端 ASR 是 OpenAI Transcriptions API 适配。
- 保证 `whisper-1` 返回的 `segments[]` 能稳定进入 `source/segments.normalized.jsonl`。
- 在 doctor/probe 中区分“云端 ASR key 缺失”和“翻译 provider key 缺失”。
- 完整化 OpenAI transcription 常用请求字段：`prompt`、`temperature`、`timestamp_granularities[]`、`include[]` 和受限 `extra_form_fields`。
- 对 timeout、429 和 5xx 增加短重试；重试仍失败时保留失败状态，不静默丢弃音频片段。
- 在 cloud ASR 前增加 ffmpeg 静音预处理：裁剪真实静音、记录 preprocess artifact、把时间轴 offset 回填到 source segments。

### 阶段 2：ASR response mapping 与更强 VAD

为 ASR 单独引入 response mapping：

```yaml
asr_providers:
  - name: openai_whisper
    protocol: openai_transcriptions
    endpoint: /v1/audio/transcriptions
    models: [whisper-1]
    response_mapping:
      segment_path: segments[]
      start_path: start
      end_path: end
      text_path: text
```

目标是支持：

- `segments[]`
- `utterances[]`
- `words[]`
- `speaker`
- `confidence`
- word-level alignment 与真正的人声 VAD，可用于处理“开头有音乐但无人声”的场景；第一阶段的 ffmpeg silence trim 只处理真实静音。

### 阶段 3：云端 ASR 并发

- 对 FFmpeg 切出的音频片段并发提交 ASR。
- 按 provider 限流配置控制并发。
- 每个片段完成即落盘，复用 checkpoint/resume。
- 对异步 provider 支持 submit/query 状态。

### 阶段 4：国内云 ASR 优先适配

优先候选：

1. 火山引擎豆包语音 ASR：中文视频和 utterance 时间轴友好。
2. 腾讯云 ASR：中文、方言、说话人、热词能力成熟。
3. 阿里云智能语音交互：中文和企业云生态可评估。

### 阶段 5：高级 ASR 能力

- diarization：说话人区分，写入 segment meta。
- hotwords/keyterms：与 translation memory 联动。
- word timestamp：更细粒度字幕切分和对齐。
- profanity filter control：默认忠实转录，可配置。
- realtime/streaming：为实时字幕或语音 agent 预留。

## 6. Agent / Skill / MCP 接口方向

TransVortex 应成为 agent 可调用的专业字幕 worker，而不是让通用 agent 临时拼脚本。

短期 agent skill 可以只包装 CLI：

```text
doctor -> config/probe -> run/asr/translate -> events/status -> result/reexport
```

长期可提供 MCP 工具：

```text
transvortex.doctor
transvortex.list_asr_providers
transvortex.run_asr
transvortex.run_pipeline
transvortex.get_events
transvortex.open_result
transvortex.refine_subtitles
```

MCP/skill 不应该重新实现 ASR、翻译或字幕修复逻辑。它只负责：

- 暴露机器可读参数。
- 调用稳定 CLI/worker 协议。
- 返回 task id、event stream、artifact paths。
- 将 provider 缺失、环境缺失、任务失败映射成结构化错误。

这样 Codex 等 agent 负责理解用户意图和调度，TransVortex 负责稳定执行字幕生产工作流。
