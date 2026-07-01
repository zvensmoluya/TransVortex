# TransVortex Desktop App Local Service Architecture

## 1. 背景与结论

TransVortex 的桌面端不应被设计成“一个窗口调用一组临时脚本”。即使早期实现仍通过 CLI、Python 模块和 JSON-RPC 逐步拼合能力，长期产品形态也应是一个具备明确生命周期、任务恢复、托盘驻留和窗口解耦能力的本地应用。

本文定义桌面 App 与本地后端的目标架构。它不要求立即重写现有 Python 后端，也不要求继续用 Tauri 作为主体验前端。当前判断是：

- Flutter 更适合作为主体验前端继续推进，不再把“证明 Flutter 是否可用”作为下一阶段主要目标。
- Python 后端可以继续作为本地服务核心，但需要从“可被调用的 sidecar”提升为“由 App 托管的 Local Service”。
- 多窗口通信属于 UI 层协调问题，不应成为业务后端总线。
- 桌面 App 的稳定性和性能关键，不只在 UI 框架本身，而在进程模型、任务隔离、状态落盘、通信协议和生命周期治理。

## 2. 术语

### App Host / Supervisor

桌面应用的宿主与监督者。它负责托盘、窗口管理、本地服务启动与重启、退出策略、应用级日志和资源定位。它可以由 Flutter runner / 原生 host 层 / 未来独立 supervisor 承担，但产品语义上不等同于某一个可见窗口。

### Local Service

TransVortex 的本地后端服务。当前候选实现是 `transvortex.app_service`。它负责配置、凭据、provider 管理、任务队列、任务状态、结果工作区、诊断信息和 worker 调度。Local Service 不应直接承载重计算长任务。

### Worker

实际执行 ASR、翻译、导出等长任务的独立进程。Worker 可以调用现有 `transvortex.cli` / pipeline 能力，向 artifact 和事件流写入进度。Worker 的失败不应拖死 Local Service 或 UI。

### Flutter Windows

主窗口、设置窗口、审看窗口等用户界面。它们是视图和输入端，不是后端所有者。窗口可以打开、关闭、重建；任务和服务生命周期不应因此丢失。

## 3. 目标

### 3.1 产品目标

- 支持普通用户以桌面 App 方式使用 TransVortex，而不是理解 CLI、环境变量和脚本组合。
- 支持长任务：关闭主窗口后，任务可以继续由托盘中的 App 管理。
- 支持任务恢复：App 重启后能识别上次任务状态，明确区分完成、失败、中断、取消和可恢复。
- 支持多窗口：配置、任务详情、字幕审看等窗口可以独立存在，但不各自拥有后端状态。
- 支持 Agent / CLI 场景：现有机器可读 CLI 和 artifact 协议继续保留，避免业务逻辑分叉。

### 3.2 工程目标

- 后端能力只实现一套：CLI、Agent、桌面 App 共享 Python core、artifact、runtime 和 provider 逻辑。
- UI 层不直接拼业务脚本；页面只通过稳定 client 调用服务能力。
- Local Service 与 Worker 分离，控制面稳定，执行面可失败、可取消、可恢复。
- 通信协议结构化、可版本化、可测试，不依赖自由文本日志。
- secret 不进入日志、文档、提交信息或 UI 普通状态流。

## 4. 非目标

- 不把每个 Flutter 窗口设计成独立后端客户端。
- 不在当前阶段重写 Python 后端为 Rust、Go 或 C++。
- 不把完整 Windows Service 作为当前目标。近期目标是托盘驻留 App 后端，而不是系统级服务。
- 不为“双前端”建立长期平台化协议。Tauri 代码可作为参考或维护入口候选，但主体验前端以 Flutter 推进。
- 不在 Local Service 内直接执行重计算 pipeline；长任务必须通过 Worker 隔离。

## 5. 目标进程模型

长期目标进程形态如下：

```text
TransVortex App Host / Supervisor
  ├─ Tray and window manager
  ├─ Local Service lifecycle and exit policy
  └─ Local Service supervisor
       └─ python -m transvortex.app_service   (常驻；业务权威状态在磁盘，进程仅持有连接/pump/游标等易失运行态)
            ├─ RPC loop (stdin/stdout)
            └─ task scheduler / pump
                 ├─ python -m transvortex.cli --root ... _worker --task-id ...
                 └─ python -m transvortex.cli --root ... _worker --task-id ...
```

关键原则：

- App Host 的生命周期高于窗口。关闭主窗口不等于退出应用。
- Local Service 的生命周期由 App Host 托管，而不是由某个页面按钮临时启动。
- Local Service 拥有任务队列和调度语义，决定哪个任务应进入执行。
- App Host / Supervisor 拥有用户可见生命周期策略，包括托盘、退出、继续后台、取消和强制终止。
- Worker 拥有执行职责，只负责实际 ASR / 翻译 / 导出，并通过 artifact 记录状态。
- 当前 runtime 通过 `.runtime/active.json` 强制单活动 Worker，任务串行执行；多 Worker 并发是后续演进项，非当前目标。
- UI 窗口随时可以重新连接当前服务状态。

因此长期职责边界固定为：

```text
Local Service owns scheduling.
App Host owns supervision policy.
Worker owns execution.
Flutter Windows own presentation and user input only.
```

Phase 1 推荐由 Local Service pump 调用共享 worker launcher 启动 Worker，目的是复用现有 Python 启动细节并避免 Dart 侧复刻平台逻辑。这是近期实现路线，不改变上面的长期职责边界。

## 6. 当前实现状态

### 6.1 Python 后端

Python 后端已经是一套相对成熟、但按 agent 用途打磨的能力，桌面端可以直接复用，不需要重建：

- `src/transvortex/app_service.py` 提供 JSON-RPC 2.0 的 stdin/stdout 入口，每个响应经 `redact` 处理，handler 异常不会拖崩进程。
- `DesktopApi.dispatch`（`src/transvortex/app/desktop_api.py`）已覆盖约三十个方法：`desktop.snapshot`、`config.get`、`tasks.list`、`tasks.events`、`runtime.snapshot/reconcile/submitRun/submitResume/acquireNext/releaseActive/cancel`、`provider.*`、`auth.*`、`prompt.asr.*`、`result.*`、`memory.exportPreset`、`catalog.*` 等。
- `transvortex.artifacts.runtime.TaskRuntime` 已实现任务队列（catalog + `QUEUED`）、单活动锁 `.runtime/active.json`、Worker 心跳、跨平台 pid 存活检测（含 Windows）、`reconcile` 崩溃恢复、`INTERRUPTED` 分类，以及带宽限期的 `force_cancel`。
- `transvortex.cli` 的 `_spawn_detached_worker` 已能以分离进程方式拉起 Worker，并把日志重定向到 `task_dir/worker/`，长期被 CLI 路径使用。

需要澄清一个容易被误解的点：`DesktopApi` 当前是无状态的——每个请求都现场 `load_app_config` 并新建 `TaskRuntime`，不持有持久的内存权威状态。权威状态全部在磁盘上（见 9.1）。

因此正式 App 服务真正缺的不是「任务 / Worker 模型」，而是以下几项：

- 生命周期与协议方法：`service.info`、`service.health`、`service.shutdown`，以及 protocol version 与 capability 声明。
- 驱动队列的 pump：`app_service` 路径下目前没有任何组件自动 `acquireNext` 并 spawn Worker（只有 CLI 的 `run` 命令自己 spawn）；桌面后台任务需要一个常驻 pump（见 11）。
- 服务端并发 / 非阻塞：当前 `serve` 主循环严格串行，慢 handler 会阻塞整个服务（见 8.2）。
- 与打包后 Python runtime / resource path 的稳定约定。
- Dart 侧正式 client（见 8.3）。

### 6.2 Flutter 前端

当前 `desktop_flutter/` 仍是 Phase A spike。它验证了主窗口、设置窗口、跨窗口状态同步、中文输入、sidecar 探针和字幕审看小样等方向。

当前 Flutter sidecar 逻辑仍是探针式：

- 点击按钮时临时 `Process.start('python', ...)`。
- 发起 `desktop.snapshot` 和一个错误方法。
- 关闭 stdin 后等待进程退出。

因此它还不是正式 Local Service client。

### 6.3 Flutter 多窗口

`desktop_multi_window` 的每个窗口是独立 Flutter engine。跨窗口通过 `WindowMethodChannel` 进行方法调用。目前项目中只有一个轻量的 `transvortex.state` 通道，用于 spike 状态同步。

这类跨窗口通信适合 UI 状态协调，不应直接升级为业务后端总线。正式设计必须定义唯一权威状态源，避免多个窗口各自维护服务连接、任务状态和配置副本。

## 7. 组件职责

### 7.1 App Host / Supervisor

职责：

- 创建、显示、隐藏和聚焦 Flutter 窗口。
- 管理托盘入口。
- 启动、监控、重启和关闭 Local Service。
- 维护 App 级运行状态：服务是否可用、最近错误、后台任务数量、退出策略。
- 在 App 退出时执行明确策略：继续后台任务、等待任务结束、请求取消、强制退出或提示用户选择。
- 提供统一日志收集位置。

约束：

- 不能把“主窗口 Dart 对象”视为长期唯一 supervisor。
- 如果短期先由主 Flutter engine 承担协调角色，必须通过 `AppServiceClient` 抽象隔离，以便后续迁移到原生 host 或独立 supervisor。

### 7.2 Local Service

职责：

- 读取和保存非敏感配置。
- 通过统一 credential resolver 读取用户级凭据。
- 提供 provider 管理、连接测试、模型列表等能力。
- 管理任务队列和 runtime 状态。
- 调度 Worker。
- 暴露任务状态、事件、结果工作区和导出能力。
- 提供环境诊断。

约束：

- 不直接在服务进程里跑长时间 ASR / 翻译 pipeline。
- 不把 secret 回传给 UI。
- 不依赖某个窗口存在。
- 所有对外响应必须结构化，错误必须有稳定 code。

### 7.3 Worker

职责：

- 执行具体任务。
- 写入 task artifact、checkpoint、events 和最终输出。
- 响应取消请求。
- 在异常时留下足够诊断信息。

约束：

- Worker 崩溃不应导致 Local Service 崩溃。
- Worker 状态必须能被 Local Service reconcile。
- Worker 不直接和 UI 窗口通信。

### 7.4 Flutter Windows

职责：

- 展示当前服务状态、任务状态、配置状态和结果。
- 收集用户输入。
- 发起用户命令，例如保存配置、测试 provider、提交任务、取消任务、打开结果。
- 订阅或刷新服务状态。

约束：

- 不直接启动 Python sidecar。
- 不直接维护权威任务状态。
- 不跨窗口传递 secret。
- 不依赖另一个设置窗口作为配置真实来源。

## 8. 通信设计

### 8.1 服务协议

近期可以继续使用 stdin/stdout newline JSON-RPC。它有几个优点：

- 不占本地端口。
- 安全面较小。
- 容易调试和测试。
- 与当前 Python `app_service` 实现一致。

但协议必须产品化：

- 每个请求包含 `id`、`method`、`params`。
- 每个响应包含 `result` 或 `error`。
- `error` 至少包含 `code`、`message`、`details`。
- 支持协议版本和能力声明。
- 支持请求超时、服务不可用、服务重启后的可恢复错误。
- 支持 stderr 作为日志流，但 UI 不解析自由文本日志作为业务状态。

建议新增基础方法：

```text
service.info
service.health
service.shutdown
desktop.snapshot
runtime.snapshot
runtime.submitRun
runtime.submitResume
runtime.cancel
tasks.list
tasks.events
provider.*
auth.*
result.*
```

`service.info` 应至少返回：

```json
{
  "service": "transvortex.app_service",
  "protocol_version": 1,
  "app_version": "v1.x-dev",
  "capabilities": ["desktop_snapshot", "runtime", "provider_admin", "result_workspace"]
}
```

### 8.2 服务端并发与非阻塞约束

目标是让控制通道（尤其 `service.health`）不被慢请求卡死，而不是让服务全面并发。当前 stdin/stdout 主循环严格串行（`serve` 逐行读、dispatch、逐行写），慢 handler（`provider.test` / `provider.models` 走网络、`runtime.cancel` 宽限等待 `sleep` 轮询）会连 `service.health` 一起卡死。在串行阻塞的服务上做「超时即重启」会误杀正在进行的操作。

但放开并发有硬前提：当前文件 I/O 原语不支持随意并发。`write_json`（`src/transvortex/utils.py`）是 `write_text`、非原子写；TaskStore / TaskRuntime 的 task、runtime、events 文件没有跨进程锁，而 Worker、Local Service、CLI 可能同时写同一批文件。在这个前提下引入写操作线程池只会放大跨进程竞态和「读到半写 JSON」的风险——只加「进程内锁」不够。

因此并发必须分级、有前提：

- 请求默认串行处理；仅对只读请求（`*.snapshot`、`config.get`、`tasks.list`、`tasks.events`、`service.info/health`）放开有限并发。
- 写操作（`runtime.*`、`provider.save`、`auth.set`、`result.*` 等）在获得**原子写（temp + `os.replace`）或跨进程锁**之前保持串行，不进线程池。
- 慢的网络类操作（`provider.test` / `provider.models`）不要放进共享线程池和文件写抢资源，优先改为短命子进程或「提交即返回 + 客户端轮询」的操作模式。
- `runtime.cancel` 的宽限→强杀升级移出 handler，交给 pump 线程或客户端轮询，handler 立即返回。
- 独立 pump 线程驱动队列（acquire → spawn → reconcile），本身也受同一套写串行 / 原子写约束。

先决工程项（放开写并发之前完成）：给 `write_json` 加原子写、给 runtime 写操作加跨进程锁（如文件锁）。

由于只读请求可能乱序返回，Dart client 必须按 `id` 匹配响应（见 8.3）。

### 8.3 Dart 侧 client

Flutter 不应让页面直接调用 `Process.start`。需要一个正式 client 层：

```text
AppServiceClient
  ├─ LocalServiceSupervisor
  ├─ JsonRpcTransport
  ├─ ServiceErrorMapper
  └─ ServiceStateStore
```

职责：

- 查找或启动 Local Service。
- 维护一个服务进程实例。
- 分配 request id。
- 请求排队或按 id 匹配响应。
- 处理超时、EOF、管道错误、进程退出。
- 对只读请求执行有限重启重试。
- 收集 stderr 日志。
- 暴露 typed Dart API 给页面和状态 store。

请求必须按 response id 匹配，不能使用“读下一行就是当前请求响应”的假设；服务端允许乱序返回（见 8.2）。

重启判据必须以管道 EOF / 进程退出为准，不以请求超时为准。请求超时只表示服务忙；仅当连续多次超时且管道断开或进程退出时，才判定服务不可用并重启。据请求超时自动重启会误杀正在进行的长操作。

client 不得回显携带 secret 的请求内容：`provider.save` / `auth.set` 会通过 stdin 传入 API key，任何调试日志都不能打印这些请求行原文。

### 8.4 多窗口通信

多窗口通信只服务 UI 协调。推荐模式：

- 所有窗口依赖同一个 `AppServiceClient` 抽象。
- 短期如果只有主 engine 能持有 Local Service，则子窗口通过 `Window Gateway` 调主 engine。
- 长期若 App Host / 原生层托管 Local Service，则各窗口通过统一 platform channel 连接同一个 host，而不是互相代理业务请求。

禁止模式：

- 每个窗口各自启动一个 `transvortex.app_service`。
- 每个窗口各自维护 runtime / task store 的权威状态。
- 设置窗口保存配置后只改本地内存，不通知服务或权威状态源。

## 9. 状态与数据所有权

### 9.1 权威状态

权威状态只位于磁盘：

- 配置文件和用户级凭据文件（`~/.transvortex/auth.json`、provider YAML）。
- task artifact 与 events。
- runtime 状态文件（`.runtime/active.json`、每任务 `worker.json` 与 `runtime_request.json`）。

Local Service 的 handler 当前不持有业务权威状态：`DesktopApi` 每个请求都现场 `load_app_config` 并新建 `TaskRuntime`，恢复只依赖磁盘 reconcile。需要精确表述——引入 pump、连接、请求表、worker 启动节流、日志游标后，进程会持有易失运行态，并非完全无状态；准确说法是「不持有必须依赖进程存活才能恢复的业务权威状态」。因此不要把「内存视图」当作权威来源，也不要在服务内引入必须常驻才能保证正确性的业务可变状态。常驻进程的价值在于持有连接、进程句柄和事件流，而不在于持有权威状态。

Flutter state store 只是缓存和展示层。窗口重新打开时必须能从 Local Service（即从磁盘）获取当前真实状态。

### 9.2 Snapshot 与增量

`desktop.snapshot` 适合作为启动水合入口，但不应成为所有交互后的唯一刷新方式。

推荐拆分：

- `desktop.snapshot`：首屏和重连时获取配置、任务、runtime、environment。
- `config.get` / `provider.*`：配置和 provider 专用刷新。
- `runtime.snapshot`：任务运行态刷新。
- `tasks.events`：单任务事件读取，应支持增量读取（`since_seq` / offset / cursor）。注意当前事件（`TaskStore.append_event`）没有稳定的 `seq` 字段，只有 JSONL 行序；需先补事件游标设计——加单调递增 `seq`，或以行偏移作为 cursor——不能假设 `seq` 已存在。events 是 append-only JSONL，全量读会随任务变长而变慢。
- 后续可加事件订阅或轻量轮询，不急于引入复杂 event bus。

### 9.3 Secret

secret 的长期规则：

- 用户级 `~/.transvortex/auth.json` 是默认凭据来源。
- Provider YAML 只能保存 `env_key`、`credential_id`、endpoint、model 等非敏感配置。
- UI 可以接收用户输入的 key，但保存后不再显示原文。
- service 响应、日志、artifact、错误详情必须经过 redaction。

## 10. 生命周期设计

### 10.1 App 启动

推荐流程：

1. App Host 启动。
2. 初始化日志、资源路径和用户目录。
3. 启动或懒启动 Local Service。
4. 调用 `service.info` / `service.health`。
5. 打开主窗口。
6. 主窗口通过 `desktop.snapshot` 水合。

### 10.2 关闭窗口

关闭主窗口不应默认退出应用。推荐语义：

- 主窗口关闭：隐藏窗口，托盘仍存在。
- 有任务运行：托盘显示运行状态，任务继续。
- 无任务运行：应用可继续驻留或按用户设置退出。

### 10.3 退出应用

退出必须是明确动作，例如托盘菜单“退出 TransVortex”。退出时需要根据任务状态选择策略：

- 无任务运行：请求 `service.shutdown`，关闭 App。
- 有任务运行：提示用户继续后台、取消任务后退出、等待完成或强制退出。
- 如果 Local Service 无响应：记录错误，并按安全策略处理 Worker。

### 10.4 崩溃恢复

Worker 以分离进程方式拉起，父进程退出后通常不会被连带终止；但当前只用了 `CREATE_NO_WINDOW`，没有 job object、进程树清理，也没有明确的退出保留 / 终止策略。因此「崩溃不影响运行中 Worker」是默认行为、不是已验证的设计——极端情况下若宿主本身处于带 kill-on-close 的 job object，子进程反而可能被连带杀掉。正式 App 需补齐这套进程生命周期（见 12、16）。Supervisor 判定 Local Service 已死必须以管道 EOF / 进程退出为准，不以单个请求超时为准（见 8.3）。

App 或 Local Service 重启后：

- Local Service 调用 runtime reconcile（对照 `active.json` 与各 `worker.json` 的 pid 存活）。
- 检查已有 task artifact 和 runtime 状态。
- 对已结束 Worker 标记 DONE / FAILED / INTERRUPTED。
- 对不确定状态给出可恢复或需人工处理的解释。

## 11. 任务执行模型

任务流保持控制面和执行面分离。队列由 Local Service 内的 pump 线程驱动：

```text
UI -> AppServiceClient -> Local Service -> runtime.submitRun   （写入 QUEUED + runtime_request.json）
Local Service pump 线程 -> runtime.acquireNext -> 取得 launch payload
Local Service pump 线程 -> spawn 分离 Worker（复用 transvortex.cli 的 _spawn_detached_worker）
Worker -> register_worker / heartbeat / 写 events、artifacts
UI -> Local Service -> tasks.events(since_seq) / runtime.snapshot
```

Worker spawn 的**近期推荐实现**是 Local Service 的 pump 线程（不是 UI 页面）：`transvortex.cli` 的 `_spawn_detached_worker` 已处理分离进程、`CREATE_NO_WINDOW`、UTF-8 环境和日志重定向，Phase 1 可直接复用，避免在 Dart 侧复刻平台细节。但这**不是「最终 worker lifecycle 所有者」的定论**：托盘、退出策略、服务重启，以及「退出但继续任务 / 取消任务」等语义与 App Host / Supervisor 的最终归属绑定（见 13、16），需在 Supervisor 阶段一并确定。当前只承诺两点：spawn 属于轻量控制动作、不违反「Local Service 不跑重计算」；UI 页面绝不直接 spawn。Worker 以分离进程拉起、父进程退出通常不连带终止它，reconcile 依据磁盘上的 `worker.json` 恢复状态；但完整的进程树 / job object 生命周期仍需设计（见 10.4、12）。

取消流程必须非阻塞：`runtime.cancel` 请求取消后立即返回，不在 handler 内 `sleep` 等待宽限期（当前实现会阻塞，属于待修正项）。宽限→强杀的升级由 pump 线程执行：

```text
UI -> runtime.cancel(task_id)              立即返回，仅置 cancel 请求
Local Service -> 在 task store 标记 cancel 请求
Worker -> 观察到取消并退出
Local Service pump 线程 -> 宽限期后仍未终止则 force cancel（终止 pid）
```

## 12. 打包与分发影响

正式 App 不能依赖开发机上的仓库结构、`python` 命令和 `PYTHONPATH`。

需要明确：

- Python runtime 如何随包分发，或如何检测并引导安装。
- `transvortex` Python 包如何定位。
- FFmpeg 如何提供或检测。
- artifact、日志、配置、凭据目录如何定位。
- Windows 托盘、通知、快捷方式和 AppUserModelID 如何建立。

这些问题不属于“UI 细节”，而是 App Host / Local Service 架构的一部分。

## 13. 技术选项与当前取舍

### 13.1 主 Flutter engine 作为短期 Coordinator

优点：

- 最少改动。
- 能快速把当前 Flutter spike 接入真实 Local Service。
- 适合验证完整产品流。

缺点：

- 主窗口或主 engine 容易成为事实单点。
- 与“关闭窗口后继续任务”的长期目标存在张力。
- `WindowMethodChannel` 不适合作为长期后端总线。

结论：可作为过渡实现，但必须通过 `AppServiceClient` 抽象隔离。

### 13.2 原生 host 层作为 Supervisor

优点：

- 更符合多窗口桌面 App 的长期模型。
- 不依赖某个可见 Flutter 窗口。
- 能统一托盘、通知、进程和窗口生命周期。

缺点：

- 需要 Windows runner / 插件层开发。
- 跨平台时需要分别处理 macOS / Linux。

结论：这是中长期更正统的桌面 App 方向，建议作为正式 App 化阶段的候选目标。

### 13.3 独立 Local Service 进程

优点：

- 边界最清楚。
- 可被 App、CLI、Agent 或未来其他入口复用。
- 更适合真正后台队列和托盘驻留。

缺点：

- 需要服务发现、权限、版本兼容和安全边界设计。
- named pipe / local socket / localhost HTTP 都会引入额外工程。

结论：如果未来需要窗口全部关闭后仍继续运行、或多个客户端同时连接，应升级评估。当前可以先保持 App Host 托管的子进程模型。

## 13.4 暂不决策但不阻塞开发

以下事项不应阻塞 Phase 1 / Phase 2 开发，但必须被封装在抽象边界后面，不能泄漏到页面和业务流程：

- App Host 最终放在主 Flutter engine、Windows native runner，还是独立 supervisor 进程。
- Worker 是否使用 Windows job object，以及如何实现进程树清理。
- 事件增量读取使用 `seq`、byte offset，还是 opaque cursor。
- 文件锁使用哪种库或平台机制。
- Windows 安装包使用 MSIX、Inno、NSIS 或其他方案。
- 未来是否从 stdin/stdout JSON-RPC 升级为 named pipe / local socket / localhost HTTP。

这些事项之所以不阻塞当前开发，是因为当前必须先固定的是职责边界：

- 页面不能直接启动 Python、Local Service 或 Worker。
- Flutter 窗口不能各自拥有后端。
- 业务权威状态必须位于 artifact、配置和凭据文件。
- Local Service 不直接执行重任务，只调度 Worker。
- V1 先保持单活动 Worker。
- 服务协议必须有 request id、结构化错误和 redaction。

只要这些边界成立，平台细节可以在后续 Supervisor、打包和发布阶段逐步替换。

## 14. 分阶段路线

### Phase 1：定义 Local Service 契约并做非阻塞改造

- 为 `transvortex.app_service` 增加 `service.info`、`service.health`、`service.shutdown`，并声明 protocol version 与 capability。
- 让控制通道不被慢请求卡死：默认串行处理，仅对只读请求放开有限并发，`service.health` 必须快速返回；写操作暂不进线程池（见 8.2）。
- 前置工程：给 `write_json` 加原子写、给 runtime 写操作加跨进程锁，作为放开写并发的前提。
- 增加驱动队列的 pump 线程（acquire → spawn → reconcile）；Phase 1 推荐复用 `transvortex.cli` 的 `_spawn_detached_worker`（最终 worker lifecycle 归属见 16 待决策）。
- 将 `runtime.cancel` 的宽限→强杀移出 handler。
- 补事件游标（`seq` 或行 offset），`tasks.events` 支持增量读取。
- 梳理现有 desktop API 的 request / response 文档，统一错误结构和 redaction 边界。
- 补充相关 Python tests。

### Phase 2：实现 Dart AppServiceClient

- 新增 `LocalServiceSupervisor` 和 `JsonRpcTransport`。
- 替换当前 sidecar probe 的临时 `Process.start`。
- 支持启动、健康检查、请求调用、超时、stderr 收集和关闭。
- 请求按 id 匹配响应；重启判据以管道 EOF / 进程退出为准，不以请求超时为准。
- 不回显携带 secret 的请求内容。
- 页面只依赖 typed client，不直接碰进程。

### Phase 3：接入真实主流程

- 主窗口从 `desktop.snapshot` 水合真实配置和任务。
- 配置窗口保存 provider / 凭据时调用 Local Service。
- 主窗口提交任务、取消任务、读取任务状态和事件。
- 现有假进度和 spike 状态逐步退出。

### Phase 4：Supervisor 与托盘

- 建立窗口无关的 App Host / Supervisor。
- 支持关闭主窗口后托盘驻留。
- 支持运行中任务的退出确认。
- 支持 Local Service 崩溃重启和任务 reconcile。

### Phase 5：打包与发布验证

- 验证 release 构建能定位 Python runtime、资源、配置和 artifact。
- 建立 Windows 安装包、快捷方式、AUMID、托盘和通知。
- 验证新机器安装后首启、配置、运行、关闭窗口继续任务、退出策略。

## 15. 验收标准

### Local Service

- `service.info` 能返回协议版本、服务名和能力列表。
- `service.health` 能区分 healthy / degraded / unavailable。
- 所有错误有稳定 `code`。
- 响应和日志不泄露 secret。
- Local Service 异常不会直接导致 Worker 状态丢失。

### Flutter Client

- 页面不再直接 `Process.start`。
- 同一 App 会话中只有一个受托管 Local Service。
- 请求超时、服务退出、stderr 错误能映射成可展示状态。
- 子窗口不会各自连接或启动后端。

### 任务生命周期

- 提交任务后可读取状态和事件。
- 取消任务能进入明确状态。
- Worker 崩溃后 App 能展示结构化失败。
- App 重启后能 reconcile 上次任务。

### App 生命周期

- 关闭主窗口不丢任务。
- 托盘可恢复主窗口。
- 退出 App 时对运行中任务有明确策略。

## 16. 决策状态

已决策（本文档已采纳，见对应章节）：

- 权威状态只在磁盘；Local Service 不持有必须依赖进程存活才能恢复的业务权威状态（见 9.1）。
- 控制通道必须非阻塞：默认串行 / 只读有限并发，只读响应按 id 匹配，重启判据以管道 EOF / 进程退出为准（见 8.2、8.3）。
- 近期通信继续 stdin/stdout newline JSON-RPC（见 8.1）。

待决策：

- Worker spawn 与 lifecycle 的最终所有者：Phase 1 推荐由 Local Service pump spawn 并复用 `_spawn_detached_worker`，但最终归属与 App Host / Supervisor 决策、退出策略绑定（见 11、13）。
- 放开服务端写并发的前提工程：`write_json` 原子写、runtime 写操作跨进程锁（见 8.2）。
- Worker 进程生命周期：job object、进程树清理、退出时保留 / 终止 Worker 的策略（见 10.4、12）。
- 事件游标设计：事件加单调递增 `seq` 或以行 offset 作为 cursor，以支持增量读取（见 9.2）。
- App Host / Supervisor 最终放在主 Flutter engine、Windows native runner，还是独立 supervisor 进程（见 13）。
- 通信是否在未来升级为 named pipe / local socket / localhost HTTP（仅当需要窗口全关后仍运行或多客户端并发时再评估）。
- 任务并发模型：当前 `active.json` 强制单活动 Worker、任务串行；是否支持多 Worker 并发是后续产品决策。
- release 包是否内置 Python runtime、FFmpeg，以及如何管理体积和升级。
- macOS / Linux 是否作为早期目标，还是 Windows 优先。

## 17. 当前建议

下一阶段不再以“继续验证 Flutter 可行性”为主要目标。建议把里程碑定义为：

```text
Local Service Integration Milestone
```

优先顺序：

1. 先定型 Python Local Service 协议和生命周期方法。
2. 再实现 Dart `AppServiceClient` / `LocalServiceSupervisor`。
3. 然后让 Flutter 主流程接真实服务数据。
4. 最后推进托盘、Supervisor 和打包验证。

这样可以避免在 UI spike 中继续消耗团队精力，同时把真正决定稳定性和性能的核心层收拢到可审核、可测试、可演进的架构边界上。
