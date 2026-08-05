# TransVortex 变更记录

本文件只记录公开版本中用户可见的重要变化和发布边界，不收录日常重构、测试扩展或一次性开发过程。安装包文件名、SHA-256、对应 commit 和下载地址以每个版本的 [GitHub Release](https://github.com/zvensmoluya/TransVortex/releases) 为准。

## [0.1.0] - 2026-08-06

首个 Windows x64 公开版本。

### 新增

- 提供 Flutter Windows 桌面应用，将片源导入、模型设置、字幕制作、任务处理、结果审看与重新导出整合为一个工作流。
- 支持视频、音频和 SRT 输入；视频可以优先提取匹配语言的内嵌文本字幕，SRT 可以跳过语音识别直接翻译。
- 支持受管本机 Whisper、用户提供的 FunASR 服务、OpenAI Transcriptions 和 OpenRouter 语音识别。
- 支持可配置翻译 provider、模型与 fallback，以及容量感知分片、上下文、术语记忆、结构校验和有界修复。
- 提供事件、checkpoint、取消、继续和失败恢复；任务状态与工件保存在本机，关闭主窗口后任务可以继续在托盘运行。
- 支持字幕片段与时间码编辑，以及 SRT、ASS、WebVTT、LRC 的单语或双语导出和重新导出。
- 提供机器可读 CLI / Agent 接口、稳定安装后入口，以及只读 ASR 环境规划与验证契约。
- Windows 安装器包含固定 Embedded Python 和 FFmpeg runtime；本机 Whisper runtime 与模型按需下载。
- 凭据默认保存在用户级 `~/.transvortex/auth.json`，Provider YAML 只保存非敏感引用；当前版本不集成产品遥测或第三方 analytics。

### 发布边界

- 正式桌面交付仅支持 Windows x64；macOS 和 Linux 尚无正式安装包。
- 安装包没有 Authenticode 签名，安装前必须从 GitHub Releases 下载并核对 SHA-256。
- 公开受管本机 Whisper 路径只保证 CPU；受管 NVIDIA 安装入口不属于首版范围。
- 桌面界面和用户文档仅提供简体中文；字幕源语言和目标语言不受界面语言限制。
- OpenRouter Grok STT 仍属实验能力，远端识别和翻译服务可能产生费用，AI 字幕需要人工审看。
- 独立 App Host、应用崩溃恢复、完整进程树守护和已有 ASR 资源自动跨盘迁移尚未完成。

安装包文件名、SHA-256、对应 commit 和完整发布说明见 [`v0.1.0` GitHub Release](https://github.com/zvensmoluya/TransVortex/releases/tag/v0.1.0)。
