# TransVortex

TransVortex 是一个面向本地视频字幕生成的 CLI-first 流水线，支持：
- 流式/分块处理，不需要一次把整片视频装入内存
- 本地 faster-whisper 或云端 OpenAI Whisper ASR
- 可配置的翻译 provider / model / base URL
- 强模型优先的全片 memory bootstrap 与 capacity-aware 大 chunk 翻译
- 可恢复任务与稳定工件目录
- 可选的 Tauri 桌面工作台

## 项目定位

TransVortex 目标是成为一个可被脚本和 agent 调用的无界面核心，同时保留对人类友好的命令行和桌面工作台。长期方向见 `docs/PRODUCT_DIRECTION.md`。

## 快速开始

1. 安装依赖
   - `python -m pip install -e .`
   - 如需本地 ASR：`python -m pip install -e .[asr]`
2. 确保 `ffmpeg` 和 `ffprobe` 在 `PATH` 中。
3. 准备 provider 配置和凭据。
   - 推荐把真实配置放在 `providers.local.yaml`（已加入 `.gitignore`）。
   - 长期默认凭据文件是 `~/.transvortex/auth.json`，可用 `TRANSVORTEX_HOME` 改目录。
   - 推荐使用 `transvortex auth set <credential-id>` 保存 key。
   - `.env` 只作为开发兼容 fallback。
4. 先做健康检查：
   - `transvortex doctor`
   - `transvortex doctor --json`
5. 先做零 token 预检：
   - `transvortex probe-provider --strict`
6. 运行一次任务：
   - 人工前台运行：`transvortex run --input demo.mp4 --src en --tgt zh-CN`
   - Agent/脚本立即获取 `task_id`：`transvortex run --input demo.mp4 --src en --tgt zh-CN --detach --json`
7. 一键 demo：
   - `.\scripts\run_demo.ps1 -ApiKey "<your-key>"`

## 凭据与配置

更完整的配置说明见 `docs/CONFIG_GUIDE.md`。简要规则是：

- `providers.example.yaml`：示例配置，可提交
- `providers.local.yaml`：本机真实配置，建议不提交
- `providers.yaml`：兼容旧流程的默认文件
- 真实 key 不要写进 provider YAML
- 真实运行优先用 `auth.json` 或环境变量，`.env` 只用于开发兼容

## 桌面端

桌面端是 Windows 日常使用的推荐入口。

```powershell
cd desktop
npm install
npm run typecheck
npm run build
npm run tauri dev
```

在应用里：
- 先检查 Environment
- 需要时保存 provider key
- 选择视频，配置 Provider、ASR、Translation 和 Output
- 输出格式可选 `srt`、`ass` 或 `both`
- 任务结束后可从 History 打开 SRT/ASS

## 云端 ASR 示例

如果要用 OpenAI `whisper-1` 云端 ASR，可以这样配置：

`pipeline.yaml`:

```yaml
asr:
  mode: cloud
  provider: openai_whisper
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
  execution:
    cloud_concurrency: 8
    adaptive_concurrency: true
  chunking:
    mode: silence
    window_seconds: 300
    max_window_seconds: 120
    min_window_seconds: 12
    overlap_seconds: 5
    max_upload_mb: 24
    silence:
      noise_db: -35
      min_silence_seconds: 0.25

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

保存 key：

```powershell
transvortex auth set openai_asr
```

当前云端 ASR 适配的是 OpenAI Transcriptions multipart API；原始响应会先归一化为 `source/segments.normalized.jsonl`，翻译层不直接依赖 ASR 原始格式。长期 ASR hint 使用 prompt profile：正文保存在 `prompts/asr/*.md`，`pipeline.yaml` 只保存 `active_profile` 和 profile 元数据；临时任务可用 `--asr-prompt-text` 传入一次性 hint，不会写回配置文件。有效 ASR hint 会作为云端 transcription `prompt` 发送，也会映射到本地 faster-whisper 的 `initial_prompt`。provider `request` 保存 OpenAI transcription 表单字段和受限 `extra_form_fields` 扩展，`response_format` 第一版固定使用 `verbose_json`。数组字段默认按 OpenAI curl 示例使用 `field[]`，需要重复同名 key 时可设 `array_format: repeat`。`timestamp_granularities` 默认请求 `segment`。Cloud ASR 默认通过统一 `httpx` 传输层请求，`http2: true` 表示优先 HTTP/2，实际不可用时会按客户端能力降级。Cloud ASR 默认用 ffmpeg 静音边界切成约 120 秒以内的自然片段，并发 8 个上传；`max_upload_mb: 24` 只作为 OpenAI 25MB 上传限制保护。请求遇到 timeout、429 或 5xx 会重试并降并发，单片仍失败会细分重跑。明显垃圾 ASR 行会在进入标准 source 前过滤，raw 和 quality diagnostics 会保留。

## 常用命令

- `transvortex run --input <video> --src <lang> --tgt <lang> [--bilingual] [--output <path>] [--json] [--stream-events] [--detach]`
- `transvortex resume --task-id <id> [--json] [--stream-events] [--detach]`
- `transvortex status --task-id <id> [--json]`
- `transvortex events --task-id <id>`
- `transvortex cancel --task-id <id> [--json]`
- `transvortex tasks [--json]`
- `transvortex doctor [--json]`
- `transvortex config show [--json]`
- `transvortex probe-provider [--provider <name>] [--model <name>] [--strict]`
- `transvortex auth set/delete/list/status [--json]`

运行时常用覆盖项包括：`--provider`、`--model`、`--asr-mode`、`--asr-device`、`--asr-model-size`、`--asr-compute-type`、`--asr-cloud-base-url`、`--asr-cloud-endpoint`、`--asr-model`、`--asr-cloud-env-key`、`--asr-cloud-credential-id`、chunk 设置、batch size 和并发。

`run`、`resume`、`asr`、`translate` 是长任务。`--json` 不带 `--detach` 时只会在任务结束后输出一个 JSON；如果需要立即拿到 `task_id`，使用 `--detach --json`。detached JSON 只是排队回执，不是最终结果；再用 `status --task-id <id> --json` 和 `events --task-id <id> --follow` 跟踪进度。

## 任务工件

每个任务都会写入稳定目录 `artifacts/<task_id>/`，常见内容包括：

- `task.json`
- `checkpoint.json`
- `events.jsonl`
- `media/`
- `asr/`
- `chunks/`
- `translate/`
- `final/`
- `output/`

其中：

- `translate/` 保存 `segments.translated.jsonl`、`validation.jsonl`、`repairs.jsonl`
- `final/` 保存对齐/重排后的段落
- `output/` 保存最终字幕文件

## 输出格式

TransVortex 可以导出 SRT、ASS 或 WebVTT。

- SRT 是兼容格式，使用 UTF-8 BOM，适合通用播放器、人工审稿和平台交付。
- ASS 是表现型格式，默认使用 `cinematic` preset，包含 CJK 友好的字体候选说明、主译文/辅原文层级、克制描边阴影、安全区和自动换行。双语顺序可用 `--subtitle-bilingual-order target_source|source_target` 选择，默认译文在上、原文在下；`--subtitle-prefer-single-line true|false` 控制是否尽量保持单行。ASS 样式本身只声明一个 `Fontname`，实际缺字替换取决于播放器和系统字体。
- WebVTT 是网页/HTML5 格式，可通过 `--format vtt` 或 `output_format: vtt` 导出。
- 导出阶段会生成 `quality/subtitle_delivery.json`，检查样式、换行、双语拥挤、格式兼容和时间轴表现问题。
- 结构化 `Segment` 始终是唯一真实来源；SRT、ASS、VTT 是不同 renderer，不会互相作为主中间格式。
- 最终文件写入任务目录的 `output/`。

表现层样例在 `samples/subtitle_delivery/`：

```powershell
python -m transvortex.cli --root . export --segments samples\subtitle_delivery\segments.delivery_sample.json --format both --output samples\subtitle_delivery\preview --bilingual --json
python -m transvortex.cli --root . export --segments samples\subtitle_delivery\segments.delivery_sample.json --format vtt --output samples\subtitle_delivery\preview --bilingual --json
```

## 参考文档

- `docs/CONFIG_GUIDE.md`：配置、凭据和 provider 约定
- `docs/运行与测试指南.md`：运行、验证和桌面端的简化说明
- `docs/IMAGEGEN_GUIDE.md`：用本地流式 imagegen helper 生成产品插画和空状态图的约定
- `docs/PRODUCT_DIRECTION.md`：长期产品方向
- `docs/ARCHITECTURE.md`：代码结构与边界
- `docs/KNOWN_ISSUES_AND_VALIDATION.md`：低优先级待验证问题和优化观察

<details>
<summary>English summary (secondary)</summary>

TransVortex is a CLI-first subtitle pipeline for local videos.

- Streamed/chunked processing
- Local faster-whisper or cloud OpenAI Whisper ASR
- Configurable translation providers and resumable tasks
- Optional Tauri desktop workbench

Key commands:

```powershell
transvortex doctor
transvortex probe-provider --strict
transvortex run --input demo.mp4 --src en --tgt zh-CN
```

Credentials default to `~/.transvortex/auth.json`; `.env` is a development fallback.

</details>

## License

TransVortex is licensed under the Apache License, Version 2.0. See `LICENSE` for details.

Samples and third-party materials may have separate attribution or licensing terms. See `samples/ATTRIBUTION.md`.
