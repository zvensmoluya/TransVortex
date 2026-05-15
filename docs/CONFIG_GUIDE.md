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
      max_tokens: 4096
    response_mapping:
      text_paths:
        - content[].text
    capabilities:
      supports_system_prompt: true
      supports_temperature: true
      supports_json_mode: false
      max_batch_lines: 50
    limits:
      concurrency: 8
      timeout_seconds: 30
      retry: 3

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
  chunk_lines: 40
  context_before_lines: 20
  context_after_lines: 10
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
- `chunk_lines` 是当前 chunk 的待翻译行数；运行时会自动受 provider `capabilities.max_batch_lines` 限制。
- `context_before_lines` / `context_after_lines` 只作为只读上下文发给模型，不会进入回填范围。
- `style_prompt: ""` 表示不追加用户文风；固定格式约束始终由系统控制。
- 旧配置 `translation_batch_size` 仍可用，并作为 `translation.chunk_lines` 的兼容别名。

## 5. ASR 与视频字幕来源

视频输入默认使用 `source_mode: auto`：如果视频里存在匹配 `source_lang` 的文本字幕轨，先提取字幕轨并跳过 ASR；否则抽取音频并运行 ASR。

```yaml
source_mode: auto        # auto | asr | embedded_subtitle
subtitle_track: auto     # auto 或 ffprobe stream index

asr:
  mode: local
  device: auto
  model_size: small
  compute_type: int8
  chunking:
    mode: auto           # auto | fixed | none
    window_seconds: 300
    overlap_seconds: 30
    short_audio_seconds: 300
    fuzzy_dedupe: true
```

说明：
- `auto` ASR 会对短音频使用单窗口；长音频使用 sliding window，并在合并时只采信 trusted region。
- 支持自动提取的内置字幕轨格式包括 `subrip`、`ass`、`ssa`、`webvtt`、`mov_text`；图形字幕轨不会替代 ASR。
- CLI 可用 `--source-mode`、`--subtitle-track`、`--asr-chunking-mode`、`--asr-window-seconds`、`--asr-overlap-seconds` 覆盖。

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
