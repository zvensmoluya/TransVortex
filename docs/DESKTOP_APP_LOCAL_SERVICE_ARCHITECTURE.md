# TransVortex Desktop App Local Service Architecture

本文描述当前桌面进程模型和下一步必须保持的边界。发布待办统一见 [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md)。

## 1. 当前进程模型

```text
Flutter App
  ├─ main window
  ├─ translation / ASR settings windows
  ├─ internal diagnostics window
  ├─ task processing window
  └─ LocalServiceController / AppServiceClient
       └─ packaged python -m transvortex.app_service
            ├─ newline JSON-RPC control loop
            ├─ task scheduler / pump
            └─ detached Worker process
                 └─ ASR / translation / quality / export
```

当前由主 Flutter engine 启动和监督一个 Local Service。子窗口通过窗口 bridge 使用同一服务抽象；bridge 不可用时仍存在过渡性自行启动路径，需要在 Supervisor 阶段收口。

Local Service 的 pump 驱动单活动 Worker 队列。当前任务串行执行，多 Worker 并发不是近期目标。

## 2. 职责

### Flutter App

- 管理窗口、系统对话框、通知和用户输入。
- 通过 typed client 调用 Local Service。
- 展示 snapshot、任务事件和结果，不持有业务权威状态。
- 不直接启动 Worker，不拼接 pipeline 脚本。

### Local Service

- 提供 `service.*`、`desktop.snapshot`、`runtime.*`、`tasks.*`、`provider.*`、`auth.*`、`result.*` 等控制面方法。
- 读取配置和统一凭据解析结果。
- 管理任务队列、reconcile、取消和 Worker 调度。
- 不在 RPC handler 内执行长时间 ASR 或翻译。
- 所有响应结构化并经过 secret redaction。

### Worker

- 执行 ASR、翻译、质量处理和导出。
- 增量写入 task、checkpoint、events 和结果工件。
- 响应取消请求并维护心跳。
- 崩溃不能拖死 Local Service；重启后可由磁盘状态 reconcile。

## 3. 通信

近期协议是 stdin/stdout newline JSON-RPC：

- 每个请求包含 `id`、`method` 和 `params`。
- 每个响应包含 `result` 或结构化 `error`。
- Dart transport 按 response id 匹配结果，不能假设下一行属于当前请求。
- stderr 只用于日志，UI 不解析自由文本日志作为业务状态。
- 请求超时不等于进程死亡；重启以 EOF 或进程退出为主要判据。
- 携带凭据的请求不能写入调试日志。

只有窗口全部关闭后仍需多客户端连接等真实需求出现时，才评估 named pipe、local socket 或 localhost HTTP。

## 4. 状态与数据所有权

可恢复的权威状态位于磁盘：

- 配置和用户级凭据。
- task、checkpoint、events 和结果工件。
- runtime 的 active、worker 和请求状态。

Local Service 可以持有连接、pump、请求表和进程句柄等易失运行态，但正确性不能依赖进程一直存活。Flutter state 只是展示缓存，窗口重建后必须能从 Local Service 恢复。

`desktop.snapshot` 用于启动和重连；运行中优先使用 `runtime.snapshot` 和带 cursor 的 `tasks.events`，避免反复读取全量状态。

## 5. 用户目录

Windows 正式应用默认使用：

```text
%LOCALAPPDATA%\TransVortex\
  Config\
  Workspace\Tasks\
  Workspace\Cache\
  Components\
  Models\
  Downloads\ASR\
```

任务和 Cache 已与安装目录分离。当前仍需补齐 `logs`、`temp`、Cache 清理失败的可观察性，以及配置和资源的版本迁移。

## 6. 安装态运行时

安装目录包含固定资源：

```text
TransVortex.exe
runtime/python/python.exe
runtime/app_runtime.json
tools/ffmpeg/bin/
tools/ffmpeg/ffmpeg_runtime.json
```

安装态不依赖系统 Python、`PYTHONPATH` 或系统 FFmpeg。Flutter 只启动包内解释器，并把固定媒体工具目录显式传给 Local Service。开发态没有固定 runtime 时仍可使用仓库 Python 环境。

本机 Whisper runtime、模型和 CUDA 不进入基础包，由用户按需下载到用户目录。

## 7. 生命周期现状与目标

当前已经具备：

- Local Service 启动、健康检查、shutdown 和异常退出监控。
- 任务 pump、单活动 Worker、取消和 reconcile。
- 多窗口 typed client 边界。
- Windows Toast、AUMID 快捷方式和 NSIS 安装拓扑。
- 主 Flutter engine 持有系统托盘；关闭主窗口时收起产品窗口，保留 engine、Local Service 和当前任务。
- 托盘或再次启动应用可恢复已有主窗口，不创建第二套 Local Service；明确退出时，运行中先确认并请求取消活动与排队任务，再关闭服务和进程。

尚未具备完整产品闭环：

- 窗口无关的 App Host / Supervisor。
- Local Service 崩溃后的用户可见重启策略。
- 持久化启动日志和崩溃日志。
- Worker 进程树 / Job Object 的最终生命周期策略。

当前可以保证正常关闭主窗口后任务由托盘继续；该保证仍依赖主 Flutter engine 和应用进程存活，不等于已经具备独立宿主、应用崩溃恢复或进程树守护能力。

## 8. 兼容与升级

- `service.info` 已返回 protocol 和 app version，Flutter 仍需校验可接受组合。
- 配置初始化目前主要是缺失时复制，尚无 schema migration、备份和失败回滚。
- prompts、默认配置和用户覆盖需要版本化初始化策略。
- frozen Tauri 不是兼容目标；唯一护栏是其 sidecar 继续以 `--no-pump` 启动，避免与 Python pump 竞争任务。

## 9. 当前发布边界

NSIS 安装器已经自动验证全新安装、升级、运行中保护、固定 Python / FFmpeg、AUMID 快捷方式、卸载和用户数据保留。

Release Candidate 仍需：

- 已安装路径真实任务和通知点击验证。
- 干净 Windows 首启与真实媒体任务。
- Authenticode 签名。
- FFmpeg 完整对应源码托管。
- 可复现 CI 构建。

这些事项的状态和优先级只在 [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md) 维护。
