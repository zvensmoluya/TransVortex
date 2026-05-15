# TransVortex

TransVortex 是一个面向本地视频字幕生成的 CLI-first 流水线，支持：
- 流式/分块处理，不需要一次把整片视频装入内存
- 本地 faster-whisper 或云端 OpenAI Whisper ASR
- 可配置的翻译 provider / model / base URL
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
   - `transvortex run --input demo.mp4 --src en --tgt zh-CN`
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

如果要用 OpenAI Whisper-style 云端 ASR，可以这样配置：

`pipeline.yaml`:

```yaml
asr:
  mode: openai
  provider: openai_asr
  model: whisper-1
  cloud:
    base_url: https://api.openai.com
    endpoint: /v1/audio/transcriptions
    model: whisper-1
    env_key: TVX_MODEL_API_KEY
    timeout_seconds: 120
```

`providers.local.yaml`:

```yaml
providers:
  - name: openai_asr
    api_type: openai-compatible
    compat_mode: openai_chat
    base_url: https://api.openai.com
    env_key: TVX_MODEL_API_KEY
    models: [whisper-1]
    auth:
      type: bearer
      header_name: Authorization
      prefix: "Bearer "
    endpoint:
      path_template: /v1/audio/transcriptions
      method: POST
```

保存 key：

```powershell
transvortex auth set openai_asr
```

## 常用命令

- `transvortex run --input <video> --src <lang> --tgt <lang> [--bilingual] [--output <path>] [--json] [--stream-events]`
- `transvortex resume --task-id <id> [--json] [--stream-events]`
- `transvortex status --task-id <id> [--json]`
- `transvortex events --task-id <id>`
- `transvortex cancel --task-id <id> [--json]`
- `transvortex tasks [--json]`
- `transvortex doctor [--json]`
- `transvortex config show [--json]`
- `transvortex probe-provider [--provider <name>] [--model <name>] [--strict]`
- `transvortex auth set/delete/list/status [--json]`

运行时常用覆盖项包括：`--provider`、`--model`、`--asr-mode`、`--asr-device`、`--asr-model-size`、`--asr-compute-type`、`--asr-provider`、`--asr-model`、chunk 设置、batch size 和并发。

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

TransVortex 可以导出 SRT 或 ASS。

- SRT 使用 UTF-8 BOM，兼容部分旧播放器
- ASS 支持基础样式、字号、描边、阴影和双语顺序
- 最终文件写入任务目录的 `output/`

## 参考文档

- `docs/CONFIG_GUIDE.md`：配置、凭据和 provider 约定
- `docs/运行与测试指南.md`：运行、验证和桌面端的简化说明
- `docs/PRODUCT_DIRECTION.md`：长期产品方向
- `docs/ARCHITECTURE.md`：代码结构与边界

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
