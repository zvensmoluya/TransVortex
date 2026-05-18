# TransVortex 配置说明

## 1. 配置文件分层

推荐使用分层配置，避免误提交真实密钥：

- `providers.example.yaml`：仓库示例配置（可提交）
- `providers.local.yaml`：本机真实配置（已在 `.gitignore` 中忽略）
- `providers.yaml`：兼容旧流程的默认配置文件

`load_app_config()` 的 provider 文件优先级：

1. CLI `--providers-file` 显式指定
2. `<root>/providers.local.yaml`
3. `<root>/providers.yaml`
4. `<root>/providers.example.yaml`

## 2. 凭据与 API Key

长期默认凭据文件是用户目录下的 `auth.json`：

```text
~/.transvortex/auth.json
```

可通过 `TRANSVORTEX_HOME` 改变目录。文件结构：

```json
{
  "version": 1,
  "credentials": {
    "zven_openai": "sk-xxx"
  }
}
```

解析优先级：

1. 显式一次性 key（例如 provider test/save 命令传入的 key）
2. 真实环境变量（provider 的 `env_key`）
3. `auth.json[credential_id]`
4. `auth.json[provider.name]`
5. 项目 `.env` 中的 `env_key`

保存 key：

```powershell
transvortex auth set zven_openai
# 或从标准输入读取，避免进入 shell 历史：
Get-Content key.txt | transvortex auth set zven_openai --stdin
transvortex auth status --json
```

`providers.yaml` / `providers.local.yaml` 只保存协议、路由和凭据引用，不保存真实 key：

```yaml
providers:
  - name: zven_openai
    env_key: TVX_MODEL_API_KEY
    credential_id: zven_openai
```

`.env` 仍可用于开发兼容，但不再是桌面端默认保存位置。

## 3. VectorEngine Anthropic 兼容配置示例

下面是推荐示例（可放到 `providers.local.yaml`）：

```yaml
providers:
  - name: vector_anthropic
    api_type: anthropic
    compat_mode: anthropic_messages
    base_url: https://api.vectorengine.ai/v1
    env_key: TVX_MODEL_API_KEY
    models:
      - claude-haiku-4-5-20251001
    auth:
      type: header
      header_name: x-api-key
      prefix: ""
    endpoint:
      path_template: /v1/messages
      method: POST
    request_mapping:
      style: anthropic_messages
    response_mapping:
      text_paths:
        - content[].text
    capabilities:
      supports_system_prompt: true
      supports_temperature: true
      supports_json_mode: false
      max_batch_lines: 1000
      max_context_tokens: 0
      max_output_tokens: 32768
      recommended_output_tokens: 16384
      output_token_param: ""
    limits:
      concurrency: 8
      timeout_seconds: 180
      retry: 3
      connect_timeout_seconds: 10
      read_timeout_seconds: 180
      write_timeout_seconds: 60
      pool_timeout_seconds: 5
      max_connections: 20
      max_keepalive_connections: 10
      http2: true
      streaming_enabled: true

routing:
  primary:
    provider: vector_anthropic
    model: claude-haiku-4-5-20251001
  fallback: []
```

说明：
- 即使写的是 `base_url=/v1` + `path_template=/v1/messages`，系统会自动规范化，避免变成 `/v1/v1/messages`。
- `providers.yaml` 只描述 provider 协议、认证、endpoint、响应映射和能力限制；字幕翻译策略、文风和 repair 开关放在 `pipeline.yaml`。

## 4. 翻译策略配置

`pipeline.yaml` 支持 `translation` 块：

```yaml
translation:
  chunk_lines: 120
  context_before_lines: 80
  context_after_lines: 40
  chunking:
    mode: capacity_aware
    min_chunk_lines: 120
    target_chunk_lines: 400
    max_chunk_lines: 900
    boundary_window_lines: 80
    soft_boundary: true
    target_output_tokens: 0
    hard_output_tokens: 0
  batching:
    mode: adaptive
    min_chunk_lines: 20
    grow_after_successes: 3
  style_preset: subtitle_natural
  style_prompt: |
    Translate as natural subtitles.
    Preserve tone, jokes, profanity, and adult references faithfully.
    Do not censor, explain, or add content.
  refusal_detection:
    enabled: true
  repair:
    enabled: true
    max_attempts: 2
```

说明：
- `translation.chunking.mode: capacity_aware` 会按 provider 输出预算和 `max_batch_lines` 规划初始大 chunk；`chunk_lines` 保留为旧 fixed 分片兼容项。
- `batching.mode: adaptive` 只负责 provider 超时或网关错误后的失败 chunk 二分重试。
- `context_before_lines` / `context_after_lines` 只作为只读上下文发给模型，不会进入回填范围。
- `style_prompt: ""` 表示不追加用户文风；固定格式约束始终由系统控制。
- 旧配置 `translation_batch_size` 仍可用，并作为 `translation.chunk_lines` 的兼容别名。
- 默认 memory 流程是 `bootstrap_first`：先用全片 source subtitles 生成全局记忆，再翻译大 chunk；翻译过程中的动态 patch 默认关闭，可按需显式开启。

```yaml
memory:
  enabled: true
  mode: bootstrap_first
  bootstrap:
    enabled: true
    mode: whole_document
    max_candidates: 120
  patch:
    enabled: false
    after_each_window: false
```

## 5. ASR 与视频字幕来源

视频输入默认使用 `source_mode: auto`：如果视频里存在匹配 `source_lang` 的文本字幕轨，先提取字幕轨并跳过 ASR；否则抽取音频并运行 ASR。

```yaml
source_mode: auto        # auto | asr | embedded_subtitle
subtitle_track: auto     # auto 或 ffprobe stream index

asr:
  mode: local
  provider: openai_whisper
  local:
    device: auto
    model_size: small
    compute_type: int8
    max_initial_timestamp: 30.0
  prompt:
    enabled: true
    text: ""
    include_previous_text: false
    max_chars: 800
  preprocessing:
    cloud_trim_silence:
      enabled: true
      backend: ffmpeg_silencedetect
      noise_db: -35
      min_silence_seconds: 0.2
      keep_preroll_seconds: 0.25
      trim_trailing: true
      keep_postroll_seconds: 0.1
      min_upload_seconds: 0.5
  execution:
    cloud_concurrency: 8
    adaptive_concurrency: true
    min_cloud_concurrency: 1
    max_cloud_concurrency: 8
    max_inflight_upload_mb: 128
  chunking:
    mode: silence        # silence | fixed | auto | none
    window_seconds: 300
    max_window_seconds: 120
    min_window_seconds: 12
    overlap_seconds: 5
    short_audio_seconds: 300
    max_upload_mb: 24
    silence:
      noise_db: -35
      min_silence_seconds: 0.25
      cut_padding_seconds: 0.15
      fallback_mode: hard_cut
    fuzzy_dedupe: true

asr_providers:
  - name: openai_whisper
    protocol: openai_transcriptions
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: TVX_MODEL_API_KEY
    credential_id: openai_asr
    timeout_seconds: 300
    retry: 2
    request:
      response_format: verbose_json
      temperature: 0
      timestamp_granularities: [segment]
      include: []
      array_format: brackets
      extra_form_fields: {}
```

说明：
- `silence` ASR 会用 ffmpeg `silencedetect` 寻找静音边界，默认把 cloud ASR 切成最长约 120 秒的自然语音片段；没有合适静音点时按 `max_window_seconds` hard cut。`max_upload_mb` 只作为 OpenAI 上传上限保护，不再作为“尽量单片上传”的目标。
- 本地 ASR 会把任务的 `source_lang` 传给 faster-whisper，例如 `--src ja` 会使用 `language: ja`，避免让模型重新猜语言。
- `asr.local.max_initial_timestamp` 控制每个 ASR 解码窗口第一句可出现的最晚时间，默认 `30.0` 秒，约等于 Whisper 的一个音频上下文窗口，用于避免片段开头有静音、空镜、标题卡时首句被硬拉到 0 秒附近。
- `mode: cloud` 使用独立 ASR provider，不复用翻译 provider routing；当前实现 `protocol: openai_transcriptions`。
- `asr.prompt.text` 是任务级 ASR hint，会作为 transcription `prompt` 发送；它适合短专名、术语或上一段上下文，不要复用翻译 prompt。
- `asr.preprocessing.cloud_trim_silence` 只默认作用于 cloud ASR，使用 ffmpeg 分析真实静音并裁剪上传音频，返回时间轴会加回裁剪 offset；它不会识别背景音乐或环境声中的“无人声”。
- `asr.execution.cloud_concurrency` 控制 cloud ASR 并发上传，默认 8；遇到 timeout、429 或 5xx 时调度层会降并发，单片失败后会尝试细分成更小片重跑，仍失败才失败任务。
- ASR 行进入 `source/segments.normalized.jsonl` 前会过滤确定性垃圾，例如纯音乐符号、替换字符乱码、长时间重复 hallucination；raw response 和 `source/asr/quality/*.json` 会保留诊断信息。
- `asr_providers[].request` 支持 `temperature`、`timestamp_granularities`、`include` 和 `extra_form_fields`；保留字段不能在 `extra_form_fields` 中覆盖，`response_format` 第一版必须是 `verbose_json`。数组字段默认按 OpenAI curl 示例使用 `field[]`，需要重复同名 key 时可设 `array_format: repeat`。默认请求 `timestamp_granularities: [segment]`，让归一化层优先消费 `segments[]` 时间戳。
- `asr_providers[].retry` 控制云端 ASR 请求短重试次数，timeout、429 和 5xx 会重试；重试仍失败会保留失败，不会静默丢弃音频片段。
- ASR 云端 URL 会自动规整重复路径，例如 `base_url=https://api.example.com/v1` + `endpoint=/v1/audio/transcriptions` 会请求 `/v1/audio/transcriptions`，不会变成 `/v1/v1/audio/transcriptions`。
- `asr.provider` 选择云 ASR provider；`--asr-model` 只覆盖 ASR provider 的模型字段，不影响翻译模型。
- ASR、SRT、内嵌字幕和外部 segments 都会归一化为 `source/segments.normalized.jsonl`，翻译层只读取统一 `Segment`。
- 支持自动提取的内置字幕轨格式包括 `subrip`、`ass`、`ssa`、`webvtt`、`mov_text`；图形字幕轨不会替代 ASR。
- CLI 可用 `--source-mode`、`--subtitle-track`、`--asr-mode`、`--asr-model`、`--asr-max-initial-timestamp`、`--asr-cloud-base-url`、`--asr-cloud-endpoint`、`--asr-cloud-env-key`、`--asr-cloud-credential-id`、`--asr-chunking-mode`、`--asr-window-seconds`、`--asr-overlap-seconds`、`--asr-max-upload-mb`、`--asr-audio-track`、`--asr-cloud-concurrency` 覆盖。

## 6. 零 Token 协议预检

在正式 `run` 前建议先执行：

```powershell
transvortex probe-provider --strict
```

可选参数：

```powershell
transvortex probe-provider --provider vector_anthropic --model claude-haiku-4-5-20251001 --providers-file .\providers.local.yaml --source-lang en --target-lang zh-CN --strict
```

检查项包括：

- `api_type` / `compat_mode` 是否合法
- model 是否在 provider 的 `models` 列表中
- `env_key` 是否已设置（只检查存在，不输出密钥）
- URL 与 auth 构造是否成功（含 `/v1` 去重）
- request payload 是否可按兼容模式构造
- `response_mapping.text_paths` 是否能从内置模拟响应提取文本

输出为 JSON，每项状态是 `PASS / WARN / FAIL`。

- 默认退出码：`0`
- 开启 `--strict` 时：只要有 `FAIL`，退出码为 `1`

## 6. 常见错误

- `missing environment variable: TVX_MODEL_API_KEY`
  - 未设置 key，执行：
  - `PowerShell: $env:TVX_MODEL_API_KEY = "your_key"`

- `response mapping did not extract text from sample`
  - `response_mapping.text_paths` 与目标协议不匹配

- URL 多了重复 `/v1`
  - 现在已自动去重，若仍异常请检查 `base_url` 是否含非法路径
