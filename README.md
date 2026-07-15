# TransVortex

TransVortex 是本地优先的字幕制作工具，支持视频、音频和 SRT 输入，通过语音识别、翻译、质量处理和重新导出生成可审看的字幕结果。

当前主要形态：

- Windows Flutter 桌面应用，面向日常使用。
- CLI / Agent 接口，面向脚本、自动化和高级用户。
- 可恢复的 Python Worker，统一承载 ASR、翻译、质量和导出。

## 当前能力

- 受管本机 faster-whisper、FunASR 本地服务或 OpenAI Transcriptions 云端 ASR。
- 视频内嵌字幕自动检查；SRT 直译跳过 ASR。
- 可配置翻译 provider、模型、routing fallback 和容量感知分片。
- 术语记忆初始化、注入和运行中更新。
- 任务事件、checkpoint、取消、继续、结果编辑和重新导出。
- SRT、ASS、WebVTT 和 LRC 输出。
- 固定 Python / FFmpeg runtime 和 NSIS Windows 安装器。

产品与架构总览见 [`项目设计说明书.md`](项目设计说明书.md)，当前待办见 [`docs/CURRENT_BACKLOG.md`](docs/CURRENT_BACKLOG.md)。

## 开发环境

```powershell
python -m pip install -e .[test]
transvortex doctor
python -m pytest -q
```

开发态本机 ASR 需要额外安装：

```powershell
python -m pip install -e .[asr]
```

显式仓库 CLI 使用系统 `ffmpeg` / `ffprobe`。正式 Windows 安装包内置固定 Python 和 FFmpeg，不要求终端用户安装这些开发依赖。

## 配置与凭据

Provider 配置文件职责：

- `providers.example.yaml`：可提交的示例。
- `providers.local.yaml`：本机真实配置，已忽略。
- `providers.yaml`：兼容默认配置。
- `pipeline.yaml`：ASR、翻译、术语记忆、质量和导出策略。

真实 key 默认保存在用户级 `~/.transvortex/auth.json`：

```powershell
transvortex auth set <credential-id>
transvortex auth status --json
```

Provider YAML 只保存 `credential_id`、endpoint 和 model 等非敏感引用。环境变量和 `.env` 仅作为开发兼容方式。

详细说明见 [`docs/CONFIG_GUIDE.md`](docs/CONFIG_GUIDE.md)。

## CLI 快速使用

先检查环境和翻译连接：

```powershell
transvortex doctor --json
transvortex probe-provider --strict
```

前台运行一次任务：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN
```

Agent 或脚本需要立即取得 `task_id` 时：

```powershell
transvortex run --input demo.mp4 --src en --tgt zh-CN --detach --json
transvortex events --task-id <task_id> --follow
transvortex status --task-id <task_id> --json
transvortex result open --task-id <task_id> --json
```

`--detach --json` 返回排队回执，不是最终任务结果。机器调用不要解析人类日志，完整约定见 [`AGENT_USAGE.md`](AGENT_USAGE.md)。

## Flutter 桌面端

```powershell
Set-Location desktop_flutter
flutter pub get
flutter run -d windows
```

桌面端提供：

- 主窗口的一次制作流程。
- 翻译模型和语音识别设置。
- 任务处理、结果编辑和重新导出。
- 内部诊断与 Windows 系统通知。

正式任务位于 `%LOCALAPPDATA%\TransVortex\Workspace\Tasks`，可重建媒体缓存位于 `Workspace\Cache`。受管 ASR 组件、模型和下载分别位于 `Components`、`Models` 和 `Downloads\ASR`。

开发与验证说明见 [`desktop_flutter/README.md`](desktop_flutter/README.md) 和 [`docs/运行与测试指南.md`](docs/运行与测试指南.md)。

## Windows 安装包

内部未签名安装包：

```powershell
.\scripts\build_windows_installer.ps1 -AllowUnsigned -Force
.\scripts\accept_windows_installer.ps1
```

当前 `0.1.0` Alpha 内部安装包已通过本机安装、升级、运行中保护、固定 runtime、快捷方式、卸载和用户数据保留验收。它还不是公开发布件；剩余门槛见 [`docs/APP_RUNTIME.md`](docs/APP_RUNTIME.md)。

## 输出与工件

每个任务保留结构化 source、翻译结果、质量信息、事件、checkpoint 和输出。`Segment` 是唯一业务真实来源；SRT、ASS、WebVTT 和 LRC 是独立 renderer。

字幕表现层样例位于 `samples/subtitle_delivery/`。

## 文档

- [`docs/README.md`](docs/README.md)：文档导航和有效性。
- [`docs/CURRENT_BACKLOG.md`](docs/CURRENT_BACKLOG.md)：当前待办和发布边界。
- [`docs/运行与测试指南.md`](docs/运行与测试指南.md)：开发、构建和验收命令。
- [`docs/CONFIG_GUIDE.md`](docs/CONFIG_GUIDE.md)：配置、凭据、翻译和 ASR 参数。
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：后端代码所有权。
- [`docs/TRANSLATION_DESIGN.md`](docs/TRANSLATION_DESIGN.md)：当前翻译架构。
- [`docs/FRONTEND/README.md`](docs/FRONTEND/README.md)：当前 Flutter 产品与设计规格。

## License

TransVortex 使用 Apache License 2.0。样例和第三方材料的单独授权见 [`samples/ATTRIBUTION.md`](samples/ATTRIBUTION.md)。
