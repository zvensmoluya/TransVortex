# TransVortex 配置说明书（MVP）

## 1. 配置文件总览
- `providers.yaml`：模型厂商、协议兼容模式、认证、路由与限流
- `pipeline.yaml`：流水线参数（分片、并发、重试、ASR参数等）
- 环境变量：API Key 与部分 pipeline 覆盖项

配置优先级：
1. CLI 参数
2. 环境变量
3. YAML 文件默认值

---

## 2. providers.yaml 说明

### 2.1 基础结构
```yaml
providers:
  - name: anthropic_main
    api_type: anthropic
    compat_mode: anthropic_messages
    base_url: https://api.anthropic.com/v1
    env_key: ANTHROPIC_API_KEY
    models:
      - claude-3-5-haiku-latest
    auth:
      type: header
      header_name: x-api-key
      prefix: ""
    endpoint:
      path_template: /messages
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
    provider: anthropic_main
    model: claude-3-5-haiku-latest
  fallback:
    - provider: gemini_backup
      model: gemini-2.0-flash
```

### 2.2 字段说明
- `api_type`：兼容老配置；可选 `openai` / `openai-compatible` / `anthropic` / `gemini-compatible`
- `compat_mode`：协议适配模式
  - `openai_chat`
  - `anthropic_messages`
  - `gemini_generate_content`
- `base_url`：自定义模型网关地址（可替换成代理地址）
- `env_key`：从环境变量读取 API Key 的变量名
- `auth.type`：
  - `bearer`（Header，通常 `Authorization: Bearer xxx`）
  - `header`（自定义 Header，如 `x-api-key: xxx`）
  - `query`（URL 查询参数，如 `?key=xxx`）
- `endpoint.path_template`：支持 `{model}` 占位符
- `request_mapping.style`：请求构造风格，通常与 `compat_mode` 一致
- `response_mapping.text_paths`：响应文本提取路径，支持多路径回退
- `capabilities.max_batch_lines`：单次最多翻译行数
- `limits`：该 provider 的并发、超时、重试

### 2.3 向后兼容
- 若不写 `compat_mode`，系统会根据 `api_type` 自动推断
- 若不写 `auth/endpoint/mapping`，会自动套用协议默认模板

---

## 3. pipeline.yaml 说明

示例：
```yaml
artifacts_dir: artifacts
chunk_seconds: 60
chunk_overlap_seconds: 1
translation_batch_size: 40
default_concurrency: 8
timeout_seconds: 30
retry: 3
max_cps: 20
asr:
  model_size: small
  device: auto
  compute_type: int8
```

关键参数：
- `chunk_seconds`：音频分片时长（推荐 60）
- `chunk_overlap_seconds`：分片重叠（推荐 1）
- `translation_batch_size`：每批翻译行数（推荐 30-50）
- `default_concurrency`：翻译并发上限（默认 8）
- `asr.*`：faster-whisper 参数

---

## 4. 环境变量

### 4.1 API Key
按 `providers.yaml` 中 `env_key` 设置，例如：
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- `CUSTOM_PROXY_API_KEY`

### 4.2 可覆盖的 pipeline 参数
- `TVX_CHUNK_SECONDS`
- `TVX_CHUNK_OVERLAP_SECONDS`
- `TVX_TRANSLATION_BATCH_SIZE`
- `TVX_DEFAULT_CONCURRENCY`
- `TVX_TIMEOUT_SECONDS`
- `TVX_RETRY`
- `TVX_MAX_CPS`

---

## 5. CLI 与配置关系
- `transvortex run ... --chunk-seconds ... --concurrency ...` 会覆盖 YAML 与 ENV。
- `transvortex resume --task-id ...` 会继续使用当前配置优先级加载。
- `transvortex status --task-id ...` 仅查询任务状态，不读取 provider API。

---

## 6. 常见问题

- 报错 `Missing environment variable`：
  - 检查 `providers.yaml` 的 `env_key` 与系统环境变量名是否一致。

- 报错 `mismatch_lines`：
  - 模型返回格式不符合编号规范；降低 `translation_batch_size` 或调整 prompt/模型。

- 报错 `bad_schema`：
  - `response_mapping.text_paths` 与实际返回 JSON 不匹配，需修正映射路径。

- 报错 `auth_error`：
  - API Key 无效，或 `auth.type/header_name/prefix` 配置错误。
