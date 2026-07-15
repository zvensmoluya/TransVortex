# 本机 ASR 组件发布与运行边界

## 产品边界

首个 Windows x64 安装版本默认选择本机 Whisper，但基础包不包含 faster-whisper、CTranslate2、CUDA 或模型。未安装时后端返回 `needs_action`，Flutter 显示对应安装动作，不把 `auth.type=none` 当成可用。

FunASR、本机 Whisper 和 OpenAI Whisper 互不回退。本机 Whisper 任务由 Worker 启动独立 JSONL 子进程，模型在一个任务内只加载一次；Worker 退出或被强制取消时，Windows Job Object 负责结束子进程并释放显存。旧的进程内实现只保留给 CLI 和开发实验。

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

“使用已有模型”只复用兼容的 faster-whisper / CTranslate2 模型目录。应用会用受管运行组件加载模型并完成最小转录，验证成功后只登记模型规格、原目录和文件指纹；不会复制、移动、删除或重新下载该目录。目录不可访问或关键文件发生变化后必须重新验证。外部 Python 环境仅保留给 CLI 和开发兼容路径，不进入 Flutter 产品界面。

## 受信下载清单

运行时清单是 `src/transvortex/resources/asr_components.json`。应用只接受清单中的 HTTPS 地址、固定大小和 SHA-256。模型使用固定 Hugging Face revision 和逐文件哈希。ZIP 组件在切换最终目录前拒绝绝对路径、`..`、符号链接和超出限制的解压体积。

下载写入 `.part` 文件并使用 HTTP Range 续传；取消后保留部分文件，重新点击安装即继续。最终目录只有在所有文件校验完成后才替换。

## 构建与发布

构建运行组件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_whisper_components.ps1 -Json
```

该脚本构建隔离的 CPython 3.13 Windows x64 运行组件和单独的 NVIDIA 包，输出资产哈希与 `asr_components_build.json`，不下载模型，也不修改产品清单。

上传并启用清单：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\publish_whisper_components.ps1 `
  -BuildManifest dist\asr-components\1.0.0\asr_components_build.json -Json
```

发布脚本需要已认证的 GitHub CLI。它先校验构建资产未被改动，再创建 / 上传 GitHub Release；全部上传成功后才写入资产大小、SHA-256 并把 `published` 改为 `true`。在此之前 Flutter 应显示“组件尚未发布”，安装接口返回 `component_unpublished`。

## 发布包检查

`scripts/package_flutter_release.ps1` 要求基础包包含下载清单和 Whisper Host，同时拒绝 `model.bin`、NVIDIA / CTranslate2 / faster-whisper 目录及相关 DLL。包内 Local Service 自检会确认默认 Provider 是 `local_worker`，并确认没有组件时 `readiness.can_run=false`。
