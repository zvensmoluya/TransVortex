# TransVortex 产品与系统总览

本文只描述相对稳定的产品模型、业务真实来源和系统边界，不维护版本能力清单、发布状态、安装细节或短期待办。面向用户的当前能力以仓库根 [`README.md`](../README.md) 为准，桌面操作以 [`USER_GUIDE.md`](USER_GUIDE.md) 为准，短期状态以 [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md) 为准，具体实现由对应专题文档负责。

## 1. 产品模型

TransVortex 是本地优先的字幕制作工具：输入视频、音频或 SRT，经过片源检查、语音识别、翻译、质量处理和人工审看，生成可继续修改与重新导出的字幕结果。

产品有两类入口：

- Flutter 桌面应用是唯一产品桌面前端，负责日常任务、设置、系统集成和结果工作区。
- CLI / Agent 接口面向脚本、自动化和高级用户，提供机器可读的任务与环境契约。

两类入口共享同一套 Python core、任务协议、配置解析、凭据解析和 Worker，不分别实现字幕业务流程。

## 2. 核心业务流程

```text
Input
  -> media inspection / source normalization
  -> ASR or embedded subtitle extraction
  -> normalized source segments
  -> translation memory bootstrap and injection
  -> capacity-aware translation chunks
  -> deterministic validation and bounded repair
  -> alignment and subtitle quality processing
  -> reviewed final segments
  -> SRT / ASS / WebVTT / LRC renderers
```

结构化 `Segment` 是字幕业务的真实来源：

- ASR 原始响应是诊断与追溯证据，不能直接成为翻译主状态。
- SRT、ASS、WebVTT 和 LRC 是从结构化结果生成的交付格式，不能反向承担业务状态。
- 编辑、质量处理和重新导出都围绕结构化 segments 进行。
- 长任务通过工件、事件和 checkpoint 增量落盘，进程退出不应抹掉已经确认的阶段结果。

## 3. 系统边界

```text
Flutter Desktop ─┐
CLI / Agent ─────┼─> Python core / task protocol
                 │       ├─ Local Service control plane
                 │       ├─ isolated Worker processes
                 │       ├─ artifacts and events
                 │       └─ provider / ASR adapters
                 └─> result workspace and exporters
```

- Local Service 是桌面应用的控制面，负责配置、凭据引用、任务队列、状态、结果和 Worker 调度。
- Worker 承担 ASR、翻译、质量处理和导出等长任务；UI 进程不执行字幕业务主流程。
- Flutter 负责展示、输入、窗口生命周期和 Windows 系统集成，不持有业务权威状态。
- CLI / Agent 可以直接使用同一任务协议和 core，不通过另一套兼容后端复制能力。
- 磁盘上的任务、事件、配置和凭据文件是可恢复状态；进程内对象只用于连接、调度和展示缓存。

## 4. 数据与外部服务边界

- 本机识别不会上传媒体；用户选择远端识别时，音频会发送到对应服务。
- 翻译 provider 只接收完成任务所需的字幕文本、上下文和术语信息。
- API 凭据与 Provider 配置分离；配置只保存凭据引用和非敏感连接信息。
- 可重建缓存与任务成果使用不同删除边界，卸载应用不等于删除用户工作成果。
- 桌面正式任务与仓库开发工件互不扫描、导入或隐式迁移。

具体存储位置、凭据优先级和远端协议由 [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md) 与 [`APP_RUNTIME.md`](APP_RUNTIME.md) 定义。

## 5. 产品原则

- **本地优先且边界透明**：明确说明什么时候媒体或文本会离开本机。
- **结果可审看**：AI 输出不是不可修改的终点，用户可以检查、编辑和重新导出。
- **长任务可恢复**：阶段结果增量落盘，失败后从已经完成的边界继续。
- **过程可追溯**：识别来源、模型请求、修复、质量判断和输出记录可以定位。
- **失败动作明确**：缺配置、目录不可写、组件缺失和外部服务失败都应给出具体恢复方向。
- **单一业务实现**：桌面、CLI 和 Agent 不分叉 pipeline。
- **格式与业务分离**：renderer 不承担 ASR、翻译、术语或质量逻辑。
- **不静默改变策略**：识别引擎、模型、计算设备和远端服务不能在用户不知情时自动切换。

## 6. 文档职责

| 需要确认的事实 | 权威入口 |
| --- | --- |
| 产品介绍、下载、当前能力、隐私摘要和已知限制 | [`../README.md`](../README.md) |
| Windows 安装、桌面配置、任务操作、结果审看和故障恢复 | [`USER_GUIDE.md`](USER_GUIDE.md) |
| 短期待办、已发布版本边界和后续优先级 | [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md) |
| 普通用户界面公开哪些能力 | [`FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md`](FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md) |
| Python core、CLI、协议和代码所有权 | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| 桌面进程、Local Service、Worker 和生命周期 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| Provider、凭据、网络、翻译和 ASR 配置 | [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md) |
| Windows runtime、安装、升级和卸载 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |
| 本机 Whisper 组件、模型和资源管理 | [`LOCAL_ASR_COMPONENTS.md`](LOCAL_ASR_COMPONENTS.md) |
| 翻译分片、术语记忆、校验和修复 | [`TRANSLATION_DESIGN.md`](TRANSLATION_DESIGN.md) |

完整文档导航和冲突优先级见 [`README.md`](README.md)。
