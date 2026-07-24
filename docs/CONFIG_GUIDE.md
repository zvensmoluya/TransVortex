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

### 桌面端任务数据

仓库 CLI 与正式 Flutter 桌面端使用不同的数据位置：

- 显式以仓库作为 `--root` 运行 CLI 时，继续使用 `pipeline.yaml` 的 `artifacts_dir`，默认写入仓库 `artifacts/`。这是开发、实验和 Agent 可复现工作区。
- Flutter 正常启动时，配置副本固定放在 `%LOCALAPPDATA%\TransVortex\Config`。正式安装时另行选择“工作数据位置”，任务写入 `<工作数据位置>\Tasks`；选择结果保存在用户级 `Config/workspace_storage.json`。
- ffmpeg 分离音轨、ASR WAV 分片、上传预处理音频和细分重试文件放在 `<工作数据位置>\Cache`。这些文件可能较大；成功任务会自动清理对应缓存，失败或取消的任务暂时保留，以支持继续任务。
- ASR 原始响应、识别文本、质量信息、翻译状态和最终结果属于任务资料，不进入 Cache。最终字幕仍写入用户选择的输出目录。
- 安装器会把工作数据位置作为独立步骤说明并允许选择，默认跟随程序安装目录的父目录，但不会放进会被整体升级替换的程序目录。检测到既有任务或缓存时继续沿用原位置，不做静默跨盘迁移。任务处理窗提供任务目录、结果目录和重新导出入口；开发期仓库 `artifacts/` 和旧 `.transvortex-desktop` 不会被正式模式自动导入。

本机 Whisper 使用另一套独立位置。全新正式安装在用户选择的 TransVortex 产品根下使用 `Resources`，例如程序位于 `D:\TransVortex\App` 时，资源位于 `D:\TransVortex\Resources`；开发环境仍可回退到应用数据根，已有安装继续沿用原登记位置。该目录只承载 `Components`、`Models/faster-whisper` 和 `Downloads/ASR`。语音识别设置只在需要下载组件时显示下载目标和更改入口；“应用设置 > 识别资源”只管理已经下载的组件。选择结果保存在 `%LOCALAPPDATA%\TransVortex\Config\asr_storage.json`，并在重新安装时优先恢复。已有受管资源或断点时不会直接切换位置，当前版本不自动迁移大文件。不要手工修改路径文件或移动目录。

开发和自动化可使用 `TRANSVORTEX_HOME` 整体覆盖桌面数据根。Local Service 的 `--artifacts-dir` / `--cache-dir` 及内部环境变量 `TRANSVORTEX_ARTIFACTS_DIR` / `TRANSVORTEX_CACHE_DIR` 用于把固定任务目录和缓存目录传给 Python worker，不是普通用户设置。

### 全局网络方式

Flutter 可在“应用设置 > 网络”或“翻译模型设置 > 网络”保存同一份应用全局网络方式。配置位于用户级 `pipeline.yaml` 的 `network` 节点，不写入 Provider YAML，也不保存代理账号或密码：

```yaml
network:
  mode: local_proxy
  proxy_port: 7890
```

- `system`：跟随 Windows 系统代理及进程代理环境；没有代理时直连。这是默认值。
- `direct`：忽略系统代理和 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`，直接连接远程服务。
- `local_proxy`：通过 `http://127.0.0.1:<proxy_port>` 连接本机代理软件，应填写 HTTP 或 Mixed 端口，不是 SOCKS 端口。

该策略覆盖翻译请求、Provider 模型列表与连接测试、远程 ASR 和受管组件下载。本地 ASR / FunASR localhost 请求显式绕过代理。Base URL 仍表示远程模型 API 或中转网关地址，与这里的本机网络代理是两个概念。

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
      max_input_tokens: 0
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
- `max_output_tokens` 和 `recommended_output_tokens` 是规划预算，不等于网关一定接受对应请求字段。`output_token_param` 留空时按协议使用默认字段，填写真实字段名时使用该字段；若网关不允许客户端传输出上限，填写 `none`，系统仍保留预算用于分块规划，但不会发送输出 token 参数。
- 某个模型不接受 `temperature` 时，将该单模型 provider 的 `supports_temperature` 设为 `false`。如果同一网关下不同模型支持情况不同，应为它们拆分 provider 配置，避免把一种模型的请求能力套给另一种模型。
- `provider test` 会向所选模型发送一次最小生成请求，可能产生少量用量；它使用正式请求的模型目录、映射、默认参数和可用的流式传输路径，并返回不含 prompt / key 的字段摘要。测试只验证当前实际发送的配置，不主动探测所有可选参数，也不承诺识别被上游隐藏的兼容性问题。
- Flutter 打开已保存连接时会自动尝试读取上游模型列表，但发现结果只用于选择，不直接写入配置。`providers*.yaml` 中的 `models` 始终表示用户已经为 TransVortex 启用的模型；不支持列表接口、自动获取失败或上游列表不完整时，可以继续手动添加模型 ID。上游本次未返回某个已启用模型时，应用不会自动删除它。

### 3.1 模型能力预设

正规厂商预设可以通过模型级 `model_configs` 提供厂商规格和 TransVortex 的稳定分片建议。Flutter 连接页默认暴露每批行数上限；已知厂商模型可使用“自动（推荐）”或切换到“小批量（120 行）”。“高级容量设置”允许为自定义模型覆盖上下文窗口、最大输入、最大输出和目标输出预算，留空表示继续继承目录或连接配置。

应用还内置一份经过核对的全局模型目录，首批覆盖 OpenAI、Anthropic、Google Gemini 和 DeepSeek 的主流文本模型。目录按精确模型 ID 或显式别名匹配，与连接名称和 Base URL 无关：例如自定义网关中的 `openai/gpt-5.6-terra` 可以继承 GPT-5.6 Terra 的官方容量和翻译建议，但 `gpt-5.6-terra:extended`、`my-gpt-5.6-terra-proxy` 这类未核对变体不会被猜测匹配。模型级用户覆盖具有最高优先级；没有模型级覆盖时，目录规格与连接级渠道限制都视为上限，取两者中较低的已知值。目录只能补齐未知能力，不能把代理商或自定义网关声明的限制放大。

目录同时保存资料来源、核对日期和可确认的官方标准计费参考。这些资料不参与账单计算，也不在连接设置中堆叠说明文字；OpenRouter、Zven、云平台、代理商和促销套餐仍以实际渠道账单为准。目录属于随版本发布的静态参考，预览模型和临时推广价需要在后续版本重新核对。

内置 DeepSeek 预设覆盖 `deepseek-v4-flash` 与 `deepseek-v4-pro`：上下文窗口 1M、最大输出 384K、目标输出预算 32768、思考档位 `high` / `max`。单批 240 行是 TransVortex 面向编号字幕翻译的均衡建议，不是 DeepSeek 的上下文硬限制。新配置不再预设官方公告于 2026-07-24 停用的 `deepseek-chat` / `deepseek-reasoner` 兼容别名。

模型没有可信规格时，容量字段可以保持未知。运行时优先使用独立的 `max_input_tokens` 规划输入；没有该值时才按上下文窗口和安全比例估算。输入与输出容量仍未知时，运行时会把单批字幕限制在 120 行，不把未知容量解释成无限；用户仅填写很大的行数、但没有同时提供可信容量时，也不会绕过这层保护。

现有配置键 `recommended_output_tokens` 在产品界面中称为“目标输出预算”：它是容量规划使用的软目标，不是模型或渠道的最大输出能力；硬上限仍由 `max_output_tokens` 表达。

### 3.2 推理强度作用域

连接的 `capabilities.reasoning_effort_param` 与 `capabilities.reasoning_efforts` 只声明协议字段和可用档位。用户默认值保存在常用模型的 routing route 上，主模型和每个 fallback 可以分别设置：

```yaml
routing_profiles:
  - id: default
    name: Default
    primary:
      provider: zven_openai
      model: gpt-5.6-terra
      reasoning_effort: auto
    fallback:
      - provider: backup
        model: gpt-5.5
        reasoning_effort: service_default
```

- `auto`：使用模型级兼容覆盖或内置模型目录的推荐值；界面会显示当前解析出的具体档位。
- `service_default`：不发送推理强度字段；连接 request mapping 中已有的同字段覆盖也会被移除。
- `none`：明确向支持该值的模型发送“关闭”，与省略字段不同。
- `minimal`、`low`、`medium`、`high`、`xhigh`、`max`：明确发送对应档位。

主窗口可以在开始任务前从翻译模型菜单内临时覆盖主模型的推理强度。界面先在互斥的“自动 / 手动”策略中选择：只有进入手动后才展开离散滑杆，并把模型实际支持的 `none`、`low`、`high` 等有序档位放入其中；没有声明支持的档位不会被猜测展示。`service_default` 在高级区域显示为“由模型服务决定”，避免被误解为另一档自动强度。最终值随完整 routing 写入任务快照；fallback 仍使用常用模型中各自保存的值，继续任务也沿用原任务快照。

连接页当前模型旁的“测试请求”思考程度只作用于下一次连接测试，用来验证该模型、协议映射和上游账号是否接受指定档位。测试使用当前选中的已启用模型，而不是固定取列表第一个模型；该临时值会传入 `provider.test`，但不会写入 Provider YAML、`model_configs` 或 routing。旧 Provider `model_configs[].reasoning_effort` 仍作为 `auto` 的兼容来源，但新的桌面配置不再把它当作连接级用户偏好。

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
- `batching.mode: adaptive` 只在当前 chunk 遇到明确硬容量错误时局部拆分；timeout、限流、5xx 和输出协议失败走 retry/fallback/repair，仍失败则暴露错误。
- 输出协议失败会对同一 chunk 做一次轻量格式恢复重试，仍然保持原上下文和 memory；这不是无限自救，也不会把后续 chunk 自动缩小。
- `context_before_lines` / `context_after_lines` 只作为只读上下文发给模型，不会进入回填范围。
- `style_prompt: ""` 表示不追加用户文风；固定格式约束始终由系统控制。
- 旧配置 `translation_batch_size` 仍可用，并作为 `translation.chunk_lines` 的兼容别名。
- 默认 memory 行为由独立开关组成：先用全片 source subtitles 生成运行时术语记忆，再按 `memory.inject.intensity` 选择当前 chunk 命中条目和必要的强背景记忆注入翻译。动态维护默认关闭，需要显式开启 `memory.patch.enabled`。

```yaml
memory:
  enabled: true
  presets: []
  bootstrap:
    enabled: true
    mode: whole_document
    max_candidates: 120
  inject:
    enabled: true
    locked: true
    confirmed: true
    proposed: true
    intensity: high
    max_prompt_tokens: 2400
    max_notes_chars_per_entry: 60
  patch:
    enabled: false
    mode: serial
    window_chunks: 3
```

说明：
- `memory.enabled: false` 是一键总禁用，会跳过预设术语表、bootstrap、注入、动态维护和一致性质检。
- `memory.presets` 有条目时会加载用户选择的预设术语表；空列表表示不加载预设。
- `memory.bootstrap.enabled: true` 会在翻译前生成运行时术语库文件 `translation_memory.json`。
- `memory.inject.enabled: true` 才会把预设术语表和运行时术语库注入翻译；`memory.inject.intensity` 只控制强度：`low`、`auto`、`high`、`max`。
- `memory.patch.enabled: true` 会开启翻译中的动态维护；当前只支持 `mode: serial`，即默认每 3 个 chunk 合并一次修改建议，再继续后续翻译。这样既能让新译名回流后续分片，也避免每片单独请求造成调用放大。开启 patch 要求 `memory.inject.enabled: true`。
- 只生成术语表草稿不属于主翻译 pipeline 的 memory 模式，请使用 `transvortex memory bootstrap` 独立命令。

## 5. ASR 与视频字幕来源

视频输入默认使用 `source_mode: auto`：如果视频里存在匹配 `source_lang` 的文本字幕轨，先提取字幕轨并跳过 ASR；否则抽取音频并运行 ASR。

```yaml
source_mode: auto        # auto | asr | embedded_subtitle
subtitle_track: auto     # auto 或 ffprobe stream index

asr:
  mode: local
  provider: openai_whisper
  local:
    device: cuda
    model_size: large-v3
    compute_type: int8_float16
    max_initial_timestamp: 30.0
    beam_size: 5
    temperature: 0.0
    condition_on_previous_text: false
    hotwords: ""
  prompt:
    enabled: true
    active_profile: ""
    profiles: []
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
    http2: true
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
- `asr.local.max_initial_timestamp` 控制每个 ASR 解码窗口第一句可出现的最晚时间，默认 `30.0` 秒，约等于 Whisper 的一个音频上下文窗口，用于避免片段开头有静音、空镜、标题卡时首句被硬拉到 0 秒附近。本地 ASR 还会传入 `beam_size`、`temperature`、`condition_on_previous_text` 和 `hotwords`；`vad_filter` 固定为 `false`，避免 faster-whisper 内部再丢弃无人声区间。
- 当前本地 ASR 的默认档位是 `large-v3 + cuda + int8_float16`，并默认关闭 `condition_on_previous_text`。这套配置适合有 NVIDIA GPU 的机器；如果要迁回 CPU 或更低显存环境，手动把 `device` 和 `model_size` 降回去即可。
- ASR 使用独立 provider，不复用翻译 provider routing；不同 ASR 服务用各自的 `protocol` 接入，例如 `openai_transcriptions` 和 `funasr_openai`，不通过通用 response mapping 互相模拟。
- `funasr_openai` 面向用户自行启动的 FunASR 本地 OpenAI-compatible 服务，默认 `chunking.mode: none`，优先把完整音频交给 FunASR 自己做 VAD、切句和时间戳；不要套用云端 OpenAI 上传限制下的 30 秒短切片。配置里的 3600 秒窗口只是避免 TransVortex 预先切碎常规长视频的上限哨兵，不代表官方保证任意 1 小时音频都稳定。
- 长期 ASR hint 使用 prompt profile：正文保存在 `prompts/asr/*.md`，`pipeline.yaml` 只保存 `active_profile` 和 profile 元数据；临时任务可用 `--asr-prompt-text` 传入一次性 hint，不会写回配置文件。有效 ASR hint 会作为 OpenAI transcription `prompt` 发送，也会映射到本地 faster-whisper 的 `initial_prompt`；FunASR 官方 OpenAI-compatible server 当前没有 `prompt` 表单字段，`funasr_openai` 默认不会发送。
- `asr.preprocessing.cloud_trim_silence` 只默认作用于 cloud ASR，使用 ffmpeg 分析真实静音并裁剪上传音频，返回时间轴会加回裁剪 offset；它不会识别背景音乐或环境声中的“无人声”。
- `asr.execution.cloud_concurrency` 控制 cloud ASR 并发上传，默认 8；遇到 timeout、429 或 5xx 时调度层会降并发，单片失败后会尝试细分成更小片重跑，仍失败才失败任务。
- ASR 行进入 `source/segments.normalized.jsonl` 前会过滤确定性垃圾，例如纯音乐符号、替换字符乱码、长时间重复 hallucination；raw response 和 `source/asr/quality/*.json` 会保留诊断信息。
- 连续周期回环不会覆盖 `text_src`：原始识别文本继续作为审计证据保存在 source artifact 中，清洗器只在 segment meta 写入有界的模型/展示视图。分片、术语初始化和最终双语排版使用该视图，避免把数百字机械重复送入模型或铺满画面。
- ASR 边界风险检测会在 source cleaning 之后运行，标记过长段、多句揉在一起、文本密度过高、重叠或缺失 segment 时间戳等问题；风险写入 `meta.asr_risk` 并汇总到 `quality/asr_boundary_quality.json`。该检测默认不阻断任务、不自动重听，只让后续字幕优化和 reflow 对高风险 ASR 段更保守。
- `asr_providers[].request` 按协议生效。OpenAI transcription 支持 `prompt`、`temperature`、`timestamp_granularities`、`include` 和受限 `extra_form_fields`；保留字段不能在 `extra_form_fields` 中覆盖，`response_format` 第一版必须是 `verbose_json`。数组字段默认按 OpenAI curl 示例使用 `field[]`，需要重复同名 key 时可设 `array_format: repeat`。FunASR 官方 OpenAI-compatible server 对齐 `file`、`model`、`language` 和 `response_format`，`funasr_openai` 不发送 `prompt`、`temperature`、`timestamp_granularities`、`include` 或扩展字段。
- `asr_providers[].http2` 默认 `true`，表示云端 ASR 优先使用统一 `httpx` 传输层的 HTTP/2；客户端或服务端不可用时会按实际能力降级，并在 ASR meta 中记录实际协议。
- `asr_providers[].retry` 控制 HTTP ASR 请求短重试次数，timeout、429 和 5xx 会重试；重试仍失败会保留失败，不会静默丢弃音频片段。
- ASR 云端 URL 会自动规整重复路径，例如 `base_url=https://api.example.com/v1` + `endpoint=/v1/audio/transcriptions` 会请求 `/v1/audio/transcriptions`，不会变成 `/v1/v1/audio/transcriptions`。
- `asr.provider` 选择 ASR provider；`--asr-model` 只覆盖 ASR provider 的模型字段，不影响翻译模型。
- ASR、SRT、内嵌字幕和外部 segments 都会归一化为 `source/segments.normalized.jsonl`，翻译层只读取统一 `Segment`。
- `source/segments.normalized.jsonl` 随任务保留，可直接交给 `transvortex translate --segments ...`。桌面端“重新翻译”会在提交时复制该文件到新任务并记录 `settings.provenance.derived_from_task_id` 与 `source_sha256`；它不依赖数据库，也不重新运行 ASR。`resume` 仍只用于继续原任务。
- 支持自动提取的内置字幕轨格式包括 `subrip`、`ass`、`ssa`、`webvtt`、`mov_text`；图形字幕轨不会替代 ASR。
- CLI 可用 `--source-mode`、`--subtitle-track`、`--asr-mode`、`--asr-model`、`--asr-max-initial-timestamp`、`--asr-beam-size`、`--asr-temperature`、`--asr-condition-on-previous-text`、`--asr-hotwords`、`--asr-prompt-profile`、`--asr-prompt-text`、`--asr-cloud-base-url`、`--asr-cloud-endpoint`、`--asr-cloud-env-key`、`--asr-cloud-credential-id`、`--asr-chunking-mode`、`--asr-window-seconds`、`--asr-overlap-seconds`、`--asr-max-upload-mb`、`--asr-audio-track`、`--asr-cloud-concurrency` 覆盖。

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

## 7. 常见错误

- `missing environment variable: TVX_MODEL_API_KEY`
  - 未设置 key，执行：
  - `PowerShell: $env:TVX_MODEL_API_KEY = "your_key"`

- `response mapping did not extract text from sample`
  - 这是翻译 provider 的协议检查错误，表示 `response_mapping.text_paths` 与目标协议不匹配；ASR provider 不使用这个翻译层 response mapping。

- URL 多了重复 `/v1`
  - 现在已自动去重，若仍异常请检查 `base_url` 是否含非法路径
