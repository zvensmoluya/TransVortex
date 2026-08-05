# 本机 ASR 组件发布与运行边界

## 产品边界

首个 Windows x64 安装版本默认选择本机 Whisper，但基础包不包含 faster-whisper、CTranslate2、CUDA 或模型。未安装时后端返回 `needs_action`，Flutter 显示对应安装动作，不把 `auth.type=none` 当成可用。

FunASR、本机 Whisper 和 OpenAI Whisper 互不回退。本机 Whisper 任务由 Worker 启动独立 JSONL 子进程，模型在一个任务内只加载一次；Worker 退出或被强制取消时，Windows Job Object 负责结束子进程并释放显存。旧的进程内实现只保留给 CLI 和开发实验。

## 开发态 APP E2E 桥接

`scripts/run_flutter_app_e2e.ps1` 可以在隔离的 APP 数据目录中，把已验证的本机 Python 和 faster-whisper 模型登记为 `external` runtime，供可见 Flutter APP 的端到端验收使用。任务仍必须由 `local_worker` 启动独立 JSONL Whisper Host；它不是旧的进程内 ASR 路径。

该能力只面向开发和验收，不在产品界面暴露 Python 选择器，也不改变 Flutter 正式版本只使用受管运行组件的产品边界。语音识别设置保存时会恢复受管策略，因此开发桥接会话中不应保存该页配置。

开发桥接通过不等于受管组件闭环通过。受管 runtime/NVIDIA 组件的构建、清单发布、下载校验、安装、正式安装目录和干净系统仍需分别验收。

## 用户数据目录

```text
%LOCALAPPDATA%\TransVortex\
  Components\
    faster-whisper\<version>\
    accelerators\nvidia-cuda12\<version>\
  Models\faster-whisper\<model>\<revision>\
  Downloads\ASR\
  Config\asr_runtime_state.json
```

模型与运行组件分开安装和删除。Flutter 始终使用 TransVortex 管理的隔离运行组件，不要求用户选择 `python.exe`，也不会在用户环境中执行 `pip install` 或升级依赖。

Agent 环境准备沿用同一 runtime 边界，但模型和 GPU 加速资源分别支持 `managed` 与 `external` 来源。Agent 可以使用自己的工具下载或准备外部资源；随后由 TransVortex 固定 runtime 完成 probe/register，并通过 `resources-activate` 写入资源引用。外部模型与 NVIDIA 用户态库目录始终由用户或 Agent 所在环境管理，应用的组件删除与卸载不会删除这些目录。

“使用已有模型”只复用兼容的 faster-whisper / CTranslate2 模型目录。用户可以选择模型目录或包含模型的上层目录；后端在最多 6 层、4096 个目录和 32 个结果的边界内查找含可读 `config.json` 与 `model.bin` 的候选，跳过符号链接，避免无边界扫描。候选仍需由受管运行组件真实加载并完成最小转录，验证成功后只登记模型规格、原目录、关键文件指纹和可选的用户显示名称；显示名称可以由桌面端修改，也可以由 Agent 在 `model-register --label` 时提供，不影响模型路径和指纹。应用不会复制、移动、删除或重新下载该目录。目录不可访问或关键文件发生变化后必须重新验证。

受管下载模型继续按清单固定 revision、大小和 SHA-256；已有模型不再用官方 `config.json` 哈希作为硬性准入条件。配置与清单相符时只登记为对应的兼容规格，其他实际可加载的模型登记为自定义模型，因此转换为 CTranslate2 的客户微调 Whisper 可以使用；原始 PyTorch / Transformers 权重仍需先转换。外部 Python 环境仅保留给 CLI 和开发兼容路径，不进入 Flutter 产品界面。

## 受信下载清单

运行时清单是 `src/transvortex/resources/asr_components.json`。应用只接受清单中的 HTTPS 地址、固定大小和 SHA-256。模型使用固定 Hugging Face revision 和逐文件哈希。ZIP 组件在切换最终目录前拒绝绝对路径、`..`、符号链接和超出限制的解压体积。

下载写入 `.part` 文件并使用 HTTP Range 续传；取消后保留部分文件，重新点击安装即继续。最终目录只有在所有文件校验完成后才替换。

完整 `.part` 缓存会先按期望大小和 SHA-256 验证。验证通过时直接安装，无需创建 HTTP 客户端；不匹配时才会丢弃缓存并按受信 HTTPS 地址重新下载。这一规则同时支撑断点续传和零网络的本地暂存验收。

## 构建与发布

构建运行组件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_whisper_components.ps1 -Json
```

该脚本构建隔离的 CPython 3.13 Windows x64 运行组件和单独的 NVIDIA 包，输出资产哈希与 `asr_components_build.json`，不下载模型，也不修改产品清单。

## 本地暂存与机器验收

公开发布资产尚未就绪时，可以把已验证的构建产物和模型文件暂存到隔离 APP 数据目录：

```powershell
$sessionRoot = Join-Path $env:TEMP "transvortex-managed-asr-e2e-large-v3"
$modelRoot = "C:\path\to\verified\faster-whisper-large-v3"

.\scripts\stage_managed_asr_e2e.ps1 `
  -BuildManifest .\dist\asr-components\1.0.0\asr_components_build.json `
  -ModelId large-v3 `
  -ModelPath $modelRoot `
  -SessionRoot $sessionRoot `
  -Json
```

这是默认资源根。Flutter 在首次受管下载前可以选择另一个本地专用文件夹，随后仍使用相同的 `Components`、`Models` 和 `Downloads` 子目录结构。界面提供可用空间预览，安装 operation 在写入前重新读取目标盘空间并保留安全余量。配置、任务、Cache 和用户级凭据不会跟随 ASR 资源根移动；已有受管资源或 `.part` 断点时首版拒绝切换，避免无校验地遗留或覆盖大文件。

脚本会重新校验构建清单、ZIP 和模型的大小与 SHA-256，生成只在会话内有效的清单副本，并把组件和模型写入受管下载缓存的 `.part` 路径。副本使用 `https://local-staging.invalid/` 占位地址，但安装前会先命中已验证的完整缓存，因此不访问该地址，也不修改 `src/transvortex/resources/asr_components.json`。

默认拒绝覆盖非空目录。仅当目录含有匹配的 TransVortex 会话归属标记时，才允许使用 `-Force` 替换；`-PlanOnly` 只校验输入并返回计划，不写入会话。

随后用 TransVortex API 完成实际安装、硬件探测、readiness 和最小转录：

```powershell
python .\scripts\accept_managed_asr_staging.py `
  --stage-report "$sessionRoot\stage_report.json" `
  --pipeline-seed .\pipeline.desktop.yaml `
  --providers-seed .\providers.yaml `
  --output-report "$sessionRoot\managed_asr_acceptance.json" `
  --source-lang en
```

成功报告必须同时记录 `readiness.state=ready`、`runtime_source=managed`、`transport=stdio_jsonl`、设备和 compute type，并重新计算安装后模型文件哈希。该机器验收会真实加载模型并转录探测音频，但不代替可见 APP 的完整媒体任务、结果审看或公开下载验收。

从隔离安装目录启动可见 APP、完成确实需要 ASR 的任务并在任务处理窗审看和重新导出后，在卸载前固定安装物、任务、Worker、识别行和输出证据：

```powershell
& "$installRoot\runtime\python\python.exe" .\scripts\verify_managed_asr_app_e2e.py `
  --stage-report "$sessionRoot\stage_report.json" `
  --task-id "tvx_YYYYMMDD_HHMMSS_xxxxxx" `
  --installer ".\dist\installer\windows\TransVortex-setup-internal.exe" `
  --install-root $installRoot `
  --output "$sessionRoot\managed_asr_installed_app_e2e.json"
```

验收器要求任务与 checkpoint 都为 `DONE`、Python Worker 正常退出并持久化最终事件、所有 ASR 行证明 `managed + stdio_jsonl + cuda + int8_float16`，同时要求 SRT / ASS 非空且在 Worker 结束后重新写出。2026-07-18 的可见安装版验收已满足这些条件，并在无活动 Worker 后静默卸载；程序目录被删除，隔离任务和机器报告保留。2026-07-30 又完成公开 CPU runtime 下载及 `small + CPU` 可见 APP 真实任务；2026-08-06，发布负责人确认最终候选已完成干净 Windows 首启和精简真实媒体回归，`0.1.0` 的本机 ASR 发布验收由此闭环。

上传并启用清单：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\publish_whisper_components.ps1 `
  -BuildManifest dist\asr-components\1.0.0\asr_components_build.json -Json
```

发布脚本需要已认证的 GitHub CLI。它先校验构建资产未被改动，再创建 / 上传 GitHub Release；全部上传成功后才写入资产大小、SHA-256 并把 `published` 改为 `true`。在此之前 Flutter 应显示“组件尚未发布”，安装接口返回 `component_unpublished`。

## 发布包检查

`scripts/package_flutter_release.ps1` 要求基础包包含下载清单和 Whisper Host，同时拒绝 `model.bin`、NVIDIA / CTranslate2 / faster-whisper 目录及相关 DLL。包内 Local Service 自检会确认默认 Provider 是 `local_worker`，并确认没有组件时 `readiness.can_run=false`。
