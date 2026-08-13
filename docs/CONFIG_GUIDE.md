# TransVortex 高级配置与协议参考

本文面向 CLI、Agent、手工 YAML 配置和兼容服务接入。使用 Windows 桌面应用完成安装、模型连接、语音识别设置和字幕制作时，先阅读 [`USER_GUIDE.md`](USER_GUIDE.md)；普通桌面用户不需要直接编辑本文提到的配置文件。

本文中的字段名表示代码和协议契约，不等同于桌面界面向用户展示的产品文案。API key、token 和密码只能通过统一凭据入口保存，不能写入 Provider YAML。

## 1. 配置文件分层

推荐使用分层配置，避免误提交真实密钥：

- `providers.example.yaml`：仓库示例配置（可提交）
- `providers.local.yaml`：本机真实配置（已在 `.gitignore` 中忽略）
- `providers.yaml`：兼容旧流程的默认配置文件
- `providers.desktop.yaml`：正式桌面产品种子，仅包含空连接列表

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
- 安装器会把工作数据位置作为独立步骤说明并允许选择，默认跟随程序安装目录的父目录，但不会放进会被整体升级替换的程序目录。检测到既有任务或缓存时继续沿用原位置，不做静默跨盘迁移。工作台提供任务目录、结果目录和重新导出入口；开发期仓库 `artifacts/` 和旧 `.transvortex-desktop` 不会被正式模式自动导入。

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

远程 ASR 的凭据引用保存在 `pipeline.yaml` 的
`asr_engines[].endpoint.credential`。`binding_id` 是解析身份的一部分，
`secret_ref` 指向 `auth.json` 中的凭据记录；只有 canonical OpenAI / OpenRouter
官方 Endpoint 且 binding 明确声明对应 `env_fallback` 时，才会读取
`OPENAI_API_KEY` / `OPENROUTER_API_KEY`。自定义 Endpoint 不会自动读取这些官方
环境变量，必须显式绑定自己的 `secret_ref`。Endpoint 的 YAML Header 不能包含
authorization、cookie、token、key、secret、credential 等敏感语义。

## 3. Anthropic Messages 兼容配置示例

下面使用不可路由的保留域名展示配置结构。实际接入时可在应用中选择官方厂商预设，或把地址、模型和凭据引用替换为目标兼容服务的真实值：

```yaml
providers:
  - name: example_anthropic_gateway
    api_type: anthropic
    compat_mode: anthropic_messages
    base_url: https://gateway.example.invalid/v1
    env_key: TVX_EXAMPLE_PROVIDER_API_KEY
    models:
      - example-model
    auth:
      type: header
      header_name: x-api-key
      prefix: ""
    endpoint:
      path_template: /messages
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
    provider: example_anthropic_gateway
    model: example-model
  fallback: []
```

说明：
- 如果兼容网关要求同时写 `base_url=/v1` 和 `path_template=/v1/messages`，系统会自动规范化，避免变成 `/v1/v1/messages`。
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

- `auto`：使用模型级兼容覆盖或内置模型目录的推荐值；主界面只显示当前解析出的具体档位，选择浮层以“模型默认”标记说明其来源。
- `service_default`：不发送推理强度字段；连接 request mapping 中已有的同字段覆盖也会被移除。
- `none`：明确向支持该值的模型发送“关闭”，与省略字段不同。
- `minimal`、`low`、`medium`、`high`、`xhigh`、`max`：明确发送对应档位。

主窗口可以在开始任务前从翻译模型菜单内临时覆盖主模型的推理强度。选择浮层会直接展开离散滑杆，把模型实际支持的 `none`、`low`、`high` 等有序档位放入其中；没有声明支持的档位不会被猜测展示。默认状态把解析档位标为“模型默认”，拖动后形成明确覆盖并提供“恢复模型默认”；`service_default` 在高级区域显示为“由模型服务决定”，避免被误解为某个具体强度。最终值随完整 routing 写入任务快照；fallback 仍使用常用模型中各自保存的值，继续任务也沿用原任务快照。

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
  collections: []
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
- `memory.enabled: false` 是一键总禁用，会跳过持久集合、预设术语表、bootstrap、注入、动态维护和一致性质检。
- `memory.collections` 是本任务选择的持久术语库 ID。集合是用户级工作数据，不绑定作品或任务；创建任务时会把所选 revision 与条目冻结到 `memory/selected_collections.json`，恢复任务继续读取该快照，而不是读取集合的最新版本。
- `memory.presets` 有条目时会加载用户选择的预设术语表；空列表表示不加载预设。
- `memory.bootstrap.enabled: true` 会在翻译前生成任务运行时术语文件 `translation_memory.json`。它是当次任务工件，可用于翻译增强、恢复和审计，但不会自动写回持久术语库。
- `memory.inject.enabled: true` 才会把所选集合快照、预设术语表和运行时术语注入翻译；`memory.inject.intensity` 只控制强度：`low`、`auto`、`high`、`max`。
- `memory.patch.enabled: true` 会开启翻译中的动态维护；当前只支持 `mode: serial`，即默认每 3 个 chunk 合并一次修改建议，再继续后续翻译。这样既能让新译名回流后续分片，也避免每片单独请求造成调用放大。开启 patch 要求 `memory.inject.enabled: true`。
- 只生成术语表草稿不属于主翻译 pipeline 的 memory 模式，请使用 `transvortex memory bootstrap` 独立命令。

正式桌面端把持久术语库放在工作数据根的 `Memory/*.json`，并随 `Tasks`、`Cache` 一起迁移；仓库 CLI 使用 `<root>/memory/collections/*.json`。集合写入使用 revision 乐观并发保护。可通过 `transvortex memory collections --json` 查看，再用 `collection-get/create/update/delete`、`entry-upsert/delete`、`promote` 和 `resolve` 操作；破坏性命令要求 `--yes`，写操作支持或要求 `--expected-revision`，适用的命令提供 `--dry-run`。

## 5. ASR 与视频字幕来源

视频输入默认使用 `source_mode: auto`：如果视频里存在匹配 `source_lang` 的文本字幕轨，先提取字幕轨并跳过 ASR；否则抽取音频并运行 ASR。

```yaml
config_schema_version: 2
source_mode: auto        # auto | asr | embedded_subtitle
subtitle_track: auto     # auto 或 ffprobe stream index

asr:
  engine: openrouter_asr
  audio_track: auto
  prompt:
    enabled: true
    active_profile: ""
    profiles: []
    include_previous_text: false
    max_chars: 800

asr_engines:
  - id: faster_whisper_large_v3
    type: faster_whisper_worker
    runtime: {source: managed, id: managed:faster-whisper}
    model: {source: managed, id: large-v3}
    accelerator: {source: managed, id: nvidia-cuda12}
    device: auto
    compute_type: auto
  - id: funasr_sensevoice_local
    type: funasr_service
    model: sensevoice
  - id: openrouter_asr
    type: openrouter_asr
    model: openai/whisper-large-v3
    endpoint:
      credential:
        binding_id: openrouter_asr
        secret_ref: openrouter_asr
    policy_overrides:
      chunking:
        window_target_seconds: 300
        overlap_seconds: 3
```

说明：
- `asr_engines` 只保存引擎意图和稀疏的 `policy_overrides`。分窗、并发、预处理、解码和请求格式的推荐值由引擎适配器统一物化，不再复制到每个种子配置中。
- 当前 pipeline / ASR schema 版本固定为 `2`；未知顶层字段、未知 ASR 字段、放错 Engine 类型的字段和不支持的版本都会直接报错。旧 `asr.provider` / `asr_providers` 已不再作为持久化输入；设置保存先完成解析校验，再使用同目录临时文件原子替换，不建设通用 migration framework。
- `faster_whisper_worker` 的 runtime、model 与 accelerator 是三个独立资源绑定；`managed` 表示产品管理的资源，`registered` 表示经过验证的外部资源记录。模型路径和 Python 路径不直接写入 YAML。
- 远程引擎在自己的 `endpoint` 中声明地址、credential binding、代理和非敏感 Header。`binding_id` 与 `secret_ref` 共同确定解析身份；API key 不进入 YAML。官方环境变量 fallback 只允许 canonical 官方 Endpoint 显式声明，自定义 Endpoint 不能继承。`Authorization`、`X-Api-Key` 等敏感 Header 会被配置校验拒绝。
- Capabilities 同时包含适配器声明与运行时观测，例如可用性、实际设备、支持的 compute type、服务探测结果和已知上传上限。它不是用户配置，也不持久化回种子 YAML。
- 推荐 Policy 是产品策略，不是模型能力声明。当前本地 Whisper 与 OpenAI transcription 推荐约 120 秒窗口，OpenRouter Whisper 与实验性 Grok 推荐 300 秒；FunASR 当前保守使用 120 秒无 overlap。用户只在确有需要时写 `policy_overrides`。
- Policy 中窗口、静音、预处理和请求期限等秒数字段接受有限浮点数；并发、尝试次数、beam size、字节预算和版本字段只接受整数，不会通过 `int()` 静默截断。显式 override 若超过 Engine capability 会返回配置错误；只有未显式指定的推荐值才可按 capability 派生收紧。
- `chunking.mode: none` 表示整段媒体作为唯一窗口，仍必须满足 Engine 的硬时长与上传限制；它不能与 `execution.split_retry: true` 组合。需要细分重试时使用 `fixed` 或 `silence`。
- `silence` 分窗会用 ffmpeg `silencedetect` 寻找静音边界；没有合适静音点时按有效窗口 hard cut。上传体积限制只作为保护，不是“尽量单片上传”的目标。
- 创建任务时会把 Engine、运行时 Capabilities 和有效 Policy 冻结到 `settings.asr_intent`。媒体探测后，稳定 segment id/index、任务目录内规范化相对路径、分片内容哈希、source/trusted 时间范围、cut reason、媒体信息、并发、请求期限和时间轴策略版本写入任务目录 `asr/asr_plan.json`；恢复任务逐项校验并使用该快照，不依赖机器绝对路径，也不受后来主页配置或默认值变化影响。
- 细分重试会先持久化失败窗口的 retry decision 和替代子窗口，再执行子窗口；崩溃恢复后读取该决定，不会重新提交原失败窗口。当前 intent schema 为 `2`、plan schema 为 `4`、retry schema 为 `2`、时间轴 strategy version 为 `1`。版本或执行语义不兼容时明确拒绝恢复并要求新建任务，不长期分发旧算法实现。
- 本地 ASR 会把任务的 `source_lang` 传给 faster-whisper，例如 `--src ja` 会使用 `language: ja`，避免让模型重新猜语言。
- 本地 Whisper 的有效解码 Policy 默认使用 `beam_size: 5`、`temperature: 0` 并关闭 `condition_on_previous_text`；`vad_filter` 固定为 `false`，避免 worker 内部再次丢弃无人声区间。设备与 compute type 由 Engine 偏好和运行时探测共同解析。
- ASR Engine 不复用翻译 routing。共享部分只限凭据解析和 HTTP 传输等薄基础设施；OpenAI transcription、OpenRouter STT、FunASR 与本地 worker 保留各自的请求和时间轴适配。
- `openrouter_stt` 使用 OpenRouter 的 `/api/v1/audio/transcriptions` JSON 接口，音频会编码为 base64 放入 `input_audio` 上传。OpenRouter 也支持 OpenAI-compatible 的 `multipart/form-data`：它把模型、语言等参数作为普通表单字段，把音频作为二进制 `file` 字段上传，不是流式识别，官方当前说明该路径上限为 25 MB。multipart 只改变传输编码，不能据此推导模型可处理的音频时长；当前 TransVortex 仍使用已经实测通过的 JSON base64，不会在两种传输间自动切换。桌面端从用户级凭据中的 `openrouter_asr` 读取密钥，并以 `OPENROUTER_API_KEY` 作为开发兼容兜底；Provider YAML 不保存密钥。
- OpenRouter ASR 采用“共享传输 + 显式模型 profile”，不会把模型目录中所有 transcription 模型自动视为兼容。当前只开放 `openai/whisper-large-v3` 和实验性的 `x-ai/grok-stt-1.0`；新增模型前必须验证请求参数、响应结构和时间轴语义，再加入 profile。
- OpenRouter 的可复用平台层只处理结构化错误、`Retry-After`、`X-Generation-Id` 和通用 HTTP 语义，不持有 ASR 或翻译模型规则。未来即使增加 OpenRouter 翻译 provider，也只能复用这一层；翻译 payload、prompt、路由与 ASR 时间轴/profile 继续分别实现。
- OpenRouter 聊天接口的 provider routing 参数当前不适用于 transcription endpoint。`openrouter_stt` 不发送 `order`、`only`、`allow_fallbacks`、`data_collection` 或 `sort`；请求中的 `provider` 仅承载当前模型 profile 明确允许的 provider-specific options。
- `openai/whisper-large-v3` 请求 `verbose_json + segment timestamps`。真实有声请求如果只有 `text`、没有 `segments`，任务会以 `openrouter_asr_timestamps_missing` 明确失败，不会伪造可用于成片的时间轴。默认最长上传窗口为 300 秒并保留 3 秒 overlap；可重试失败会把窗口二分为约 150 秒后重试。2026-07-27 的 3.447 秒合成英文短音频真实请求经 Together 上游返回了准确文本和 `0-3.447125` 的 segment，证明当前请求与响应解析可用；长音频、分片边界、多语言和真实内容仍需人工验收。
- `x-ai/grok-stt-1.0` 的 xAI 原生 API 文档列出了 word timestamps、说话人分离和多声道能力。2026-07-28 的 OpenRouter 真实请求确认：`response_format: json` 即使附带 `timestamp_granularities: [word]` 也只有 `text + usage`；改为 `verbose_json + word` 后，JSON base64 与 multipart 都会返回 `words`。当前 Grok profile 因而固定请求 `verbose_json + word`。各上传窗口保留 3 秒音频重叠，项目先在重叠区内按规范化 token 与绝对词时间做单调对齐，合并 words 后再按标点、停顿、最长 6 秒及说话人/声道变化生成统一字幕段。无法可靠对齐的接缝只按 manifest 的 trusted boundary 分配词，不启用模糊整句删重，并将无文本诊断写入 `quality/asr_word_overlap.json`；若响应缺少有效 `words` 则明确失败，不按上传窗口伪造粗时间轴。57.033 秒合成英文音频单次 JSON 请求约 4.877 秒完成并返回 95 个 words，但上游只给了一个覆盖全长的 `segments`，因此项目必须自行做 word-to-caption 分段。
- OpenRouter 公布的是约 60 秒上游“处理时间”超时，而不是 60 秒音频上限。Whisper 与 Grok 的 300 秒窗口均为当前工程安全阈值，不是上游官方推荐或保证：16 kHz 单声道 PCM WAV 在 300 秒时约 9.2 MiB，4 路并发的 base64 请求仍在当前 64 MiB inflight 预算内。Whisper 上游公开能力和 Grok 短样本处理倍率都为 300 秒保留了较大处理时间余量；真实长内容、不同语言、网络条件和负载仍需验收。Grok 正常窗口和超时后的细分重试共用同一套词级 overlap 合并。
- OpenRouter multipart 的顶层 `prompt` 当前会被接受但忽略。Whisper JSON profile 会按文档把提示词映射到 `provider.options.groq.prompt`；Grok profile 当前不发送 prompt。`extra_json_fields` 和 `provider_options` 会按具体 profile 白名单校验，未知字段会失败关闭，避免把某个上游的参数误发给另一个模型。
- OpenRouter 成功响应中的 `usage.cost`、`usage.seconds` 和 token 字段会按 generation ID 去重并汇总到 `source/asr/openrouter_usage.json` 与任务诊断。每个成功响应会先写入 `source/asr/usage_receipts/`，因此后续 fallback、分裂重试、任务失败、取消或进程中断不会丢掉已经发生的费用。Flutter 在所有成功响应都含有 usage/cost 时显示“OpenRouter 用量”，否则显示“OpenRouter 已报告用量”。进入已配置密钥的 OpenRouter ASR 设置时会通过普通 API key 可访问的 `/api/v1/key` 自动展示该 key 的周期用量、限额、剩余额度和重置周期，原“查询用量”按钮用于手动刷新；该查询不发模型请求，并以 5 秒单次请求快速失败。未保存的 provider draft 必须显式提供一次性 key，留空沿用凭据时 draft 的凭据引用必须与已保存的 OpenRouter provider 一致。需要 management key 的账户级 `/credits` 不属于当前 ASR 凭据边界。任务汇总和 key 用量都不等同于最终账单，最终费用仍以 OpenRouter Activity 和账单为准。
- `funasr_service` 面向用户自行运行的 FunASR 本地 OpenAI-compatible 服务；已验证的外部环境也可以由桌面端点火器启动。点火器独立保存可执行文件、参数数组、工作目录与本机健康检查地址，不属于 Provider YAML，也不部署、更新或诊断 FunASR。服务保留自己的 VAD、切句和时间戳语义，当前产品策略使用 120 秒无 overlap 的保守窗口；这不是 FunASR 的固有时长上限，后续可在真实服务验收后调整 Policy。
- 长期 ASR hint 使用 prompt profile：正文保存在 `prompts/asr/*.md`，`pipeline.yaml` 只保存 `active_profile` 和 profile 元数据；临时任务可用 `--asr-prompt-text` 传入一次性 hint，不会写回配置文件。有效 ASR hint 会作为 OpenAI transcription `prompt` 发送，也会映射到本地 faster-whisper 的 `initial_prompt`；FunASR 官方 OpenAI-compatible server 当前没有 `prompt` 表单字段，`funasr_openai` 默认不会发送。
- 远程 ASR 的默认预处理 Policy 会使用 ffmpeg 裁剪上传窗口两端的真实静音，返回时间轴会加回裁剪 offset；它不会识别背景音乐或环境声中的“无人声”。
- 远程 ASR 的并发由有效 Policy、运行时能力、窗口数量和 inflight 音频预算共同解析；遇到 timeout、429 或 5xx 时调度层会降并发，单片失败后可细分重跑，仍失败才失败任务。
- ASR 行进入 `source/segments.normalized.jsonl` 前会过滤确定性垃圾，例如纯音乐符号、替换字符乱码、长时间重复 hallucination；raw response 和 `source/asr/quality/*.json` 会保留诊断信息。
- 连续周期回环不会覆盖 `text_src`：原始识别文本继续作为审计证据保存在 source artifact 中，清洗器只在 segment meta 写入有界的模型/展示视图。分片、术语初始化和最终双语排版使用该视图，避免把数百字机械重复送入模型或铺满画面。
- ASR 边界风险检测会在 source cleaning 之后运行，标记过长段、多句揉在一起、文本密度过高、重叠或缺失 segment 时间戳等问题；风险写入 `meta.asr_risk` 并汇总到 `quality/asr_boundary_quality.json`。该检测默认不阻断任务、不自动重听，只让后续字幕优化和 reflow 对高风险 ASR 段更保守。
- 请求字段由 Engine 适配器和模型 profile 管理。OpenAI transcription 使用 multipart；OpenRouter 使用 JSON base64，并只发送 profile 白名单允许的参数；FunASR 只发送其兼容接口支持的字段。UI 不把 `response_format` 或时间戳粒度伪装成所有引擎都可自由选择的通用选项。
- 远程 Endpoint 默认优先 HTTP/2，实际不可用时按传输层能力降级并记录协议；短重试次数来自有效 Execution Policy。OpenRouter 返回 `Retry-After` 时会在有界范围内采用该等待时间。
- ASR 云端 URL 会自动规整重复路径，例如 `base_url=https://api.example.com/v1` + `endpoint=/v1/audio/transcriptions` 会请求 `/v1/audio/transcriptions`，不会变成 `/v1/v1/audio/transcriptions`。
- `asr.engine` 选择识别引擎；CLI 的 `--asr-engine` 可做本次选择覆盖，`--asr-model` 只对本次加载的 ASR Engine 做临时模型覆盖，不影响翻译模型，也不写回 YAML。
- ASR、SRT、内嵌字幕和外部 segments 都会归一化为 `source/segments.normalized.jsonl`，翻译层只读取统一 `Segment`。
- `source/segments.normalized.jsonl` 随任务保留，可直接交给 `transvortex translate --segments ...`。桌面端“重新翻译”会在提交时复制该文件到新任务并记录 `settings.provenance.derived_from_task_id` 与 `source_sha256`；它不依赖数据库，也不重新运行 ASR。`resume` 仍只用于继续原任务。
- 支持自动提取的内置字幕轨格式包括 `subrip`、`ass`、`ssa`、`webvtt`、`mov_text`；图形字幕轨不会替代 ASR。
- CLI 可用 `--source-mode`、`--subtitle-track`、`--asr-engine`、`--asr-model`、`--asr-audio-track`、`--asr-prompt-profile`、`--asr-prompt-text`、`--asr-prompt-enabled`、`--asr-prompt-include-previous-text` 和 `--asr-prompt-max-chars` 做任务级覆盖。Engine Policy 通过 schema v2 配置和解析器校验，不再暴露旧 cloud/chunking 散装参数。

### 临时运行时投影

`AsrProviderConfig` 现在只由 Engine + 有效 Policy 单向生成，用于尚未迁移的 Client / Worker
执行接口和桌面协议快照；它不会从 YAML 读取，也不会持久化或回写。删除该临时类型前还需完成：

- 将 `core/asr.py` 的本地 worker、OpenAI、OpenRouter 与 FunASR client 构造参数改为 Engine/Endpoint/Policy 类型；
- 将 `app/asr_runtime.py` 与 `app/asr_testing.py` 的 readiness、fingerprint、credential 和连接测试改为 Engine resolution；
- 将 orchestrator 的活动 ASR 查找与 `AppConfig.asr_providers` 改为 Engine resolution，并同步 doctor、Agent setup 与 desktop snapshot 消费方；
- 最后删除 `app/models.py` 中的 `AsrProviderConfig`、`PipelineConfig.asr_provider` 等兼容命名，以及桌面 RPC 中仍保留的 `asr.provider.*` / `asr_providers` 字段。

## 6. 零 Token 协议预检

在正式 `run` 前建议先执行：

```powershell
transvortex probe-provider --strict
```

可选参数：

```powershell
transvortex probe-provider --provider example_anthropic_gateway --model example-model --providers-file .\providers.local.yaml --source-lang en --target-lang zh-CN --strict
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
  - 这是翻译 provider 的协议检查错误，表示 `response_mapping.text_paths` 与目标协议不匹配；ASR Engine 不使用这个翻译层 response mapping。

- URL 多了重复 `/v1`
  - 现在已自动去重，若仍异常请检查 `base_url` 是否含非法路径
