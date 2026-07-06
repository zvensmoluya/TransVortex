# Flutter 前端实现清单

本文档把 `FRONTEND_DELIVERY_GOALS.md` 的当前交付目标、`FRONTEND_DESIGN_SPEC.md` 的核心三窗口 MVP 与最小诊断入口、`FRONTEND_IMPLEMENTATION_CONTRACT.md` 的实施边界、`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md` 的本地服务模型，收敛成一份可直接施工的实现清单。

它不是新的设计稿，也不是再抽象一层架构图。它只回答四件事：

- Flutter 前端 MVP 现在要做什么。
- 每个界面应该接哪些后端能力。
- 当前后端已经能接什么，哪里还缺口。
- 哪些验证必须做，才算真的接上。

---

## 0. 结论先行

当前阶段的 Flutter 前端 MVP 目标，不是继续修补早期验证界面，而是把主流程接成一条真实链路：

1. 主窗口显示真实服务状态和真实配置摘要。
2. 用户从主窗口选择片源。
3. 用户在主窗口设置本单运行参数。
4. 用户点击开始后，任务进入 `runtime.submitRun`。
5. 运行中状态、任务事件、失败信息从 `runtime.snapshot` / `tasks.events` / `desktop.snapshot` 刷新。
6. 完成后能打开输出、打开任务目录、进入任务处理窗的内嵌结果审看 / 编辑工作台、保存片段编辑，并选择输出格式 / 单双语重新导出。

核心三窗口的 MVP 仍然成立：

- 主窗口
- 翻译模型设置窗
- 语音识别设置窗

其余能力先归入“后续设计轮次”，不要反客为主。

当前另有一个最小只读诊断工具窗：展示 `desktop.snapshot.environment` 的 doctor 报告，从 `desktop.snapshot` 显示活动任务、任务数、队列和中断任务的上下文摘要，队列 / 中断任务可显示短线索并定位到任务处理窗，并可用真实 `tasks.list` / `result.open` 读取最近任务和完成任务结果摘要；不承载完整修复台、完整历史恢复矩阵、完整结果编辑器或队列操作。任务处理窗是任务历史 / 详情 / 结果编辑的新主入口，用真实 `tasks.list` 展示任务片列、按全部 / 制作中 / 待处理 / 已完成筛选任务，并可按片源、任务 ID、状态、失败摘要和目录线索搜索任务；右侧展示选中任务预览、创建 / 更新时间、运行记录、可用操作摘要、失败 / 中断线索、最近事件并按 cursor 加载更多事件，已加载事件可按类型 / 阶段 / 状态 / 消息本地搜索，完成任务内嵌编辑、失败任务继续动作和运行中任务取消动作；旧最小结果审看窗、任务历史窗和任务详情独立窗已移除，旧启动 ID 兼容进入任务处理窗；跨任务批量筛查、完整编辑器、完整历史恢复矩阵和高级导出复核仍属后续。

---

## 1. 现有基础

### 已有的 Flutter 基础

- `desktop_flutter/lib/services/app_service_client.dart` 已有 `JsonRpcTransport`、`LocalServiceSupervisor`、`AppServiceClient`、`ServiceInfo`、`ServiceHealth`、`DesktopSnapshot`。
- `desktop_flutter/lib/services/local_service_controller.dart` 已有启动、刷新、重启、关闭、退出监控。
- `desktop_flutter/lib/main.dart` 已经能在主窗口读取 `desktop.snapshot`，并把配置就绪状态灌进主屏。
- `desktop_flutter/lib/model/main_window_controller.dart` 已接管主窗口状态推导与 `runtime.submitRun` payload；窗口类型 / 跨窗口状态已从旧验证命名收束为正式 `AppWindow*` 命名。
- `desktop_flutter/lib/widgets/job_line.dart`、`primary_action.dart`、`settings_window.dart` 已进入正式候选路径；旧验证视图与未使用的临时后端探针已移出活跃构建范围。

### 已有的后端能力

- `src/transvortex/app_service.py` 已有 `service.info`、`service.health`、`service.shutdown`、`desktop.snapshot`、`runtime.snapshot`、`runtime.reconcile`、`runtime.submitRun`、`runtime.submitResume`、`runtime.acquireNext`、`runtime.releaseActive`、`runtime.cancel`、`tasks.list`、`tasks.events`、`provider.*`、`auth.*`、`prompt.asr.*`、`result.*`、`memory.exportPreset`。
- `src/transvortex/artifacts/runtime.py` 已有任务排队、单活动 worker、reconcile、取消宽限、强制取消。
- `src/transvortex/artifacts/task_store.py` 已有事件页读取，cursor 以行号方式工作。
- `src/transvortex/app/desktop_requests.py` 已有 `RunRequest` / `ResumeRequest` 的 payload 规范，`overrides` 可承载运行时选项。

### 当前明确缺口

- 主窗口已经把“开始译制”接到 `runtime.submitRun`，并能轮询任务状态、读取事件页、取消任务。
- 翻译设置窗已经能读取真实翻译服务 / routing，并调用 `provider.save`、`provider.models`、`provider.test`、`provider.routing.save`。
- 语音识别设置窗已经有 `asr.provider.save` 后端入口，能保存默认识别方案到 `pipeline.yaml`，远端 key 仍写用户级 `auth.json`。
- 完成态已经能读取结果、进入任务处理窗内嵌结果审看 / 编辑工作台、按全部 / 有问题 / 空译文 / 已修改筛查片段、按源文 / 译文 / 问题提示搜索片段、还原单个已修改片段、放弃全部未保存修改、编辑并保存片段译文、选择输出格式 / 单双语、复核将导出的格式 / 单双语与已有输出记录后重新导出，并打开字幕 / 所在文件夹；目标文件缺失时会进入重新导出修复态；重新导出失败且输出目录不可写时可选择新目录对同一任务重新导出；错误修复件深联动、完整历史恢复矩阵、术语管理、跨任务批量筛查和完整结果编辑器仍属后续轮次。
- 最小诊断窗已经能读取 doctor 报告并展示检查项，也能显示任务上下文摘要、队列 / 中断任务短线索、刷新最近任务、读取完成任务结果摘要，并可在最近任务行检查有输出记录任务的结果目录可写性；常见翻译 / 识别检查项可跳转对应设置窗，产物目录检查项可打开 doctor 报告里的目录路径，任务 / runtime / queue / interrupted / resume 类检查项、队列 / 中断任务线索和最近任务行可跳转任务处理窗并定位任务。任务处理窗已经能读取真实 `tasks.list` 并显示任务片列、按全部 / 制作中 / 待处理 / 已完成筛选任务、按片源 / 任务 ID / 状态 / 失败摘要 / 目录线索搜索任务、任务预览、创建 / 更新时间、运行记录、可用操作摘要、失败 / 中断线索和最近事件，最近事件可按 `tasks.events` cursor 继续加载，已加载事件可按类型 / 阶段 / 状态 / 消息本地搜索；完成任务可内嵌编辑，失败任务可调用真实 `runtime.submitResume`，运行中任务可调用真实 `runtime.cancel`，并可打开任务目录 / 结果目录、用户触发检查结果目录可写性；旧任务历史窗和任务详情独立窗已移除；更完整错误修复件深联动、完整历史恢复矩阵、术语管理、高级导出复核仍属后续轮次。

---

## 2. MVP 范围

### 必做

- 主窗口真实启动 Local Service。
- 主窗口读取真实 `desktop.snapshot`。
- 主窗口把“开始译制”接到 `runtime.submitRun`。
- 主窗口在运行中可刷新任务状态与事件页。
- 主窗口完成后能打开结果和任务目录。
- 翻译设置窗能够修改当前默认翻译路由。
- 翻译设置窗能够保存翻译服务、key、routing，并做连接测试 / 模型列表拉取。
- 语音识别设置窗能够展示当前识别方案，并完成最少一条“可选引擎”的配置链路。
- 诊断工具窗能够展示 Local Service doctor 报告，覆盖本机依赖、翻译服务、语音识别和产物目录可写性基础检查，产物目录检查项可打开 doctor 报告里的目录路径，并展示活动任务、任务数、队列和中断任务的只读上下文摘要；队列 / 中断任务可显示短线索并定位到任务处理窗；同窗可用真实 `tasks.list` 刷新最近任务，用 `result.open` 读取完成任务的结果摘要。

### 暂缓

- 任务历史完整页。
- 任务详情完整页。
- 结果审看完整编辑器、跨任务批量筛查和高级导出复核。
- 术语管理完整页。
- 诊断结果到修复动作的完整页。
- 正式 MSIX / installer 打包分发和分发路径下的通知中心最终行为验收；当前已有 portable 包脚本可验证 release bundle + Python 源码布局、包内 Local Service RPC、用户级脚本安装和可选窗口启动，但它不内置 Python runtime / FFmpeg，也不是正式安装器；系统通知真实横幅已由人工确认出现，Windows 通知设置 key 已由 release smoke 校验，AppUserModelID 用户级开始菜单快捷方式可由脚本创建并校验。
- 高级打包 / 托盘。

---

## 3. 窗口实现清单

### 3.1 主窗口

#### 要接的能力

- `service.info`
- `service.health`
- `desktop.snapshot`
- `runtime.submitRun`
- `runtime.submitResume`
- `runtime.snapshot`
- `runtime.cancel`
- `tasks.events`
- `result.open`
- `result.reexport`

#### UI 任务

- 空态显示“放入视频或字幕文件”。
- 文件选择走系统文件对话框。
- 拖放文件走当前桌面运行时的原生拖放路径。
- `JobLine` 变成真实运行参数摘要，而不是临时演示态。
- 主 CTA 依据真实状态切换：
  - 空态：选择片源
  - 就绪：开始译制
  - 受阻：去配置翻译 / 识别
  - 运行中：停止任务
  - 完成：处理新片源
  - 失败：重试

#### 具体字段

- 输入文件路径
- 源语言
- 目标语言
- 双语开关
- 输出格式
- 翻译默认方案
- 语音识别默认方案
- 术语记忆相关运行时选项
- 字幕整形相关运行时选项

可见 UI 不直接暴露原始协议字段：路径在主界面只显示文件名和短位置提示，完整路径走显式复制 / 打开目录；语言码显示为自然语言名；`task_id`、任务阶段和事件消息先映射为短编号 / 中文阶段 / 中文事件文案。

#### 当前实现方式

- 主窗口由 `MainWindowController` 生成 view model，来源是 Local Service snapshot + 当前任务草稿。
- “开始译制”当前走 `runtime.submitRun`；默认把片源所在目录写入顶层 `output_dir`，保证默认输出位置符合“片源同目录”的产品语义。
- 失败恢复中断任务时可走继续任务动作；首次运行的输出目录不可写时可选择新目录，并用新的 `output_dir` 重试；重新导出失败时可选择新目录，并把 `output_dir` 传给同一任务的 `result.reexport`。
- 运行参数优先走 `overrides`，主窗口只保留本单必要设置。

### 3.2 翻译模型设置窗

#### 已有后端能力

- `provider.save`
- `provider.delete`
- `provider.models`
- `provider.test`
- `provider.routing.save`
- `auth.set`
- `auth.list`

#### UI 任务

- 左侧翻译服务列表，右侧详情面板。
- 当前默认翻译方案要能从 routing 中读写。
- 保存翻译服务时，API key 不进 YAML，只写用户级认证文件。
- 拉模型列表、测试连接、设为默认模型都要可用。
- 保存后主窗口的翻译默认标签要即时更新。

#### MVP 重点字段

- 翻译服务名称
- api_type / compat_mode
- base_url
- credential_id / env_key
- model 列表
- endpoint
- request / response mapping
- routing primary / fallback

#### 当前注意点

- 现有 Flutter UI 已经接上翻译服务保存、模型拉取、连接测试和默认路由写入。
- 需要把“当前默认翻译”与“可编辑翻译服务列表”分开，不要回到表格台。
- 当前表单只覆盖 MVP 字段；request / response mapping、fallback routing、高级参数仍应留在后续偏好窗细化。

### 3.3 语音识别设置窗

#### 已有后端能力

- `desktop.snapshot` 里的 `asr_providers`
- `config.get`
- `doctor` 里对语音识别配置的检查逻辑
- `asr.provider.save`
- `prompt.asr.save`
- `prompt.asr.delete`

#### 现状判断

语音识别设置窗现在能展示现有配置，并能通过 `asr.provider.save` 保存一个默认识别方案。
MVP 先控制在两层：

1. 展示当前引擎和基础配置状态。
2. 保存本机 / FunASR / 云端 OpenAI Whisper 的最小配置链路。

#### UI 任务

- 三个引擎的选择要可见：
  - 本机识别
  - FunASR
  - 云端 OpenAI Whisper
- 选中引擎后，右侧显示该引擎的最小必要字段。
- 云端引擎需要 key / base_url / model / endpoint。
- 本地引擎需要 model_size / device / compute_type。
- FunASR 需要本地服务地址和可测试入口。

#### 现实约束

- `asr.provider.save` 已能写入 `pipeline.yaml` 的 `asr.provider` / `asr_providers`。
- FunASR 连通性和本机 faster-whisper 依赖检查仍主要依赖 doctor；设置窗只做最小配置保存，不上传音频做真实识别测试。
- 语音识别的高级 chunking、静音切分、并发、预处理参数仍属后续详细设置。

### 3.4 诊断工具窗

#### 已有后端能力

- `desktop.snapshot.environment`
- `doctor_report`

#### UI 任务

- 从 `desktop.snapshot.environment` 读取 doctor 报告。
- 展示总体 PASS / WARN / FAIL 和检查项列表。
- 展示选中问题的中文建议、错误码和关键路径。
- 从 `desktop.snapshot` 展示活动任务、任务数、队列和中断任务的只读上下文摘要；等待 / 中断任务可用短线索定位到任务处理窗。
- 提供真实刷新动作。

#### 当前边界

- 诊断窗是只读工具窗，不做主窗口常驻状态墙。
- 诊断窗只接已真实存在的修复入口：常见翻译服务 / routing / credential 问题可跳转翻译模型设置，语音识别 / faster-whisper / FunASR 问题可跳转语音识别设置，产物目录可打开 doctor 报告里的路径；诊断窗队列 / 中断任务短线索和最近任务行可定位任务处理窗，任务处理窗可展示失败 / 中断任务的只读处理线索，诊断窗最近任务行和任务处理窗可对单个任务的结果目录做用户触发的可写性检查。自动修复、任务队列操作和更完整任务详情诊断留给后续 G6。

---

## 4. 数据流清单

### 启动

1. `LocalServiceSupervisor.start()`
2. `service.info`
3. `service.health`
4. `desktop.snapshot`
5. 初始化主窗口状态

### 运行

1. 用户选片源
2. 读取当前 draft
3. 组装 `runtime.submitRun` 的 request
4. 返回 `task_id`
5. 轮询 `runtime.snapshot`
6. 按需拉 `tasks.events`

### 完成

1. `runtime.snapshot` 进入终态
2. `desktop.snapshot` 刷新任务列表
3. `result.open`
4. `result.reexport`

### 失败

1. 读取 `task.error_info`
2. 读取 `tasks.events`
3. 根据 `code` / `hint_zh` 组织修复动作
4. 必要时导向翻译设置窗 / 语音识别设置窗 / 结果修复动作

---

## 5. 主窗口运行参数映射

### 现在可以直接映射的

- `output_format`
- `subtitle_bilingual_order`
- `subtitle_prefer_single_line`
- `subtitle_quality_mode`
- 主窗口生成术语建议：`allowSystemSuggestions`、`memory_bootstrap_enabled`、`memory_patch_enabled`；打开生成时可补 `memory_enabled=true`，关闭生成时不写 `memory_enabled=false`
- 后续术语使用 / 维护窗口再映射：`memory_enabled`、`memory_inject_enabled`、`memory_intensity`、`memory_patch_window_chunks`

### 仍需谨慎的

- `memory_presets`
- 翻译服务级 overrides
- 语音识别专属 overrides

这些可以先作为高级项保留在 draft 里，不必在第一屏全暴露。

---

## 6. 设计对齐清单

主窗口必须继续满足这些设计要求：

- 单主体，不做 dashboard。
- 不做路由页。
- 不做左栏导航。
- 不做卡片墙。
- 不把设置窗做成网页 modal。
- 不把失败做成错误海报。
- 不把状态只压在颜色上。

翻译窗和语音识别窗必须满足：

- 真正的独立工具窗。
- 主从结构清楚。
- 左侧是选择，右侧是详情。
- 选择变化后主窗口同步更新。

---

## 7. 验证清单

### Python 侧

- `pytest tests/test_app_service.py`
- `pytest tests/test_task_runtime.py`
- `pytest tests/test_task_store.py`
- `pytest tests/test_utils.py`

### Flutter 侧

- `flutter test`
- `flutter build windows`
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1` 可运行单次 release smoke；成功 JSON 会写入 `frontend_design_mvp_complete=false`、自动化覆盖范围和仍需人工验收清单，避免把单次 smoke 绿灯误读成“前端设计 MVP 完成”；使用 `-KeepTemp` 时，保留在临时目录里的 `report.json` 也会写入同一组验收边界字段
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -ScreenshotPath <png>` 可在完成态报告写出前由 release 进程导出 Flutter 渲染树截图，并做尺寸 / 非空像素 / Flutter overflow 警告条检查
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release_matrix.ps1` 可一次性导出 release 主流程完成态、完成态通知检查、主窗口六态、4 个非主窗口基础 case、`taskProcessing` 编辑 / 恢复 / 取消三个追加 case 和长模型名设置窗的 Flutter 渲染树截图，并保存每个 case 的 JSON 报告与矩阵 summary；summary 会记录渲染尺寸、非背景采样、Flutter overflow 警告条采样、任务处理窗选中状态、编辑 / 重新导出 / 恢复 / 取消结果、诊断窗 / 任务处理窗结果目录可写性和通知调用 / registry 结果，用于复查截图里暴露过的布局 / overflow、任务处理窗主流程和通知接线；summary 也会写入 `frontend_design_mvp_complete=false`、自动化覆盖范围和仍需人工验收清单，防止把自动 smoke 绿灯误读成“前端设计 MVP 完成”
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -MainPhase empty|ready|blockedTranslation|blockedAsr|running|failed -ScreenshotPath <png>` 可在 release 主窗口中渲染指定主状态，覆盖空态、就绪态、翻译受阻、识别受阻、运行态和失败态的 Flutter 渲染树截图与 overflow 警告条检查
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -WindowType translationSettings -ScreenshotPath <png>` 可启动 release 翻译设置窗，读取临时翻译服务配置并导出 Flutter 渲染树截图，同时检查 Flutter overflow 警告条
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -WindowType asrSettings -ScreenshotPath <png>` 可启动 release 语音识别设置窗，读取临时语音识别配置并导出 Flutter 渲染树截图，同时检查 Flutter overflow 警告条
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -WindowType diagnostics -ScreenshotPath <png>` 可启动 release 诊断工具窗，读取临时 Local Service 的 doctor 报告和任务上下文摘要，验证最近任务结果目录可写性，并导出 Flutter 渲染树截图，同时检查 Flutter overflow 警告条
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -WindowType taskProcessing -TaskProcessingScenario browse|edit|failure|resume|cancel -ScreenshotPath <png>` 可启动 release 任务处理窗；`browse` 校验读取并选中 DONE 任务片，`edit` 在右侧内嵌结果编辑器保存片段译文、选择 ASS / 单语重新导出并确认导出字幕包含编辑文本，`failure` 停在失败任务并导出失败 / 中断线索截图，`resume` 选中失败任务并触发真实 `runtime.submitResume` 重新排队，`cancel` 选中运行中任务并触发真实 `runtime.cancel` 到 `CANCEL_REQUESTED`；传入截图路径时同时导出 Flutter 渲染树截图并检查 Flutter overflow 警告条
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -CheckNotifications` 可在主流程任务从运行态进入完成态时，通过主窗口通知 observer 执行一次真实 Windows toast 插件初始化 / show 调用，并校验 AUMID / GUID registry 注册
- `powershell -ExecutionPolicy Bypass -File scripts\install_flutter_desktop_shortcut.ps1` 可为当前用户创建 / 校验开始菜单 `TransVortex.lnk`，写入与通知一致的 `TransVortex.Desktop` AUMID；`scripts\smoke_flutter_release.ps1 -CheckNotifications -CheckAppIdentity` 会同时校验通知 AUMID、Windows 通知设置 key 和快捷方式 AUMID 一致，成功后 `manual_acceptance_required` 仍会保留真实可见窗口完整人工端到端和正式 MSIX/MSI/NSIS/Inno 安装器验收，避免把自动 smoke 误读成完整完成。
- `powershell -ExecutionPolicy Bypass -File scripts\package_flutter_release.ps1 -OutputRoot <dir> -LaunchCheck` 可生成 portable release 包，默认从包根启动 `python -m transvortex.app_service --no-pump` 验证 `service.info` / `service.health` / `service.shutdown`，并在 `-LaunchCheck` 时从包目录启动 `TransVortex.exe` 验证 release 窗口；manifest 明确 `installer=false`、`python_runtime_included=false`、`ffmpeg_included=false`、`frontend_design_mvp_complete=false` 和 `local_service_check.ok=true`，避免把 portable 包误认成正式安装器。
- `powershell -ExecutionPolicy Bypass -File scripts\install_flutter_portable_release.ps1 -SourceRoot <portable-package> -InstallRoot <dir> -ShortcutPath <lnk> -Force` 可把 portable 包复制到用户级安装目录，创建 / 校验指向安装目录 `TransVortex.exe` 的 AUMID 快捷方式，并在安装目录复跑 Local Service RPC；包根 `Install-TransVortex.ps1` 是同一能力的解压后入口。报告会写入 `installer=false`、`formal_installer=false`，不能替代正式 MSIX/MSI/NSIS/Inno 验收。
- `powershell -ExecutionPolicy Bypass -File scripts\accept_flutter_release_manual.ps1 -LaunchCheck` 可只验证真实 release 窗口能启动并写出初始窗口截图，不算人工端到端通过；本机已通过该 launch-check，报告写入 `ok=true`、`launch_visible_ok=true`、`manual_visible_e2e_ok=false`。`powershell -ExecutionPolicy Bypass -File scripts\accept_flutter_release_manual.ps1 -InputPath <video>` 可启动真实 release 窗口，按“可见 release 窗口、人工选择片源、人工开始、观察运行、完成、打开结果、打开结果审看”七个检查点记录人工确认、窗口截图和 `manual_release_acceptance.json`。该脚本完整通过时只能证明真实可见窗口人工端到端已完成，仍需与自动 smoke、外部服务、通知和 AUMID 证据合并后再判断整体完成。
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_flutter_release.ps1 -CheckDesktopComposite` 可额外用 ffmpeg `ddagrab` 抓 Windows 桌面合成层窗口区域，作为真实可见窗口诊断；抓取前会前置 release 窗口，并用浅色工作区采样校验避免误抓背后的桌面内容；`smoke_flutter_release_matrix.ps1 -CheckDesktopComposite` 当前矩阵覆盖 16 个 release case，本机已通过带桌面合成层采样的 16 case release matrix，16/16 个 case 写出有效桌面合成层截图，Flutter 渲染树与桌面合成层 overflow 警告条采样均为 0。该项仍只证明窗口区域被桌面合成层捕获，不替代人工完整操作验收。
- `powershell -ExecutionPolicy Bypass -File scripts\smoke_external_services.ps1 -ProvidersFile .\providers.local.yaml` 可在有真实凭据的机器上运行外部翻译服务验收：先跑 `probe-provider --strict`，再用 `samples\asr_segments_sample.jsonl` 跑真实 `translate --json`；传入 `-InputPath <video>` 会额外跑真实媒体任务，并在发现 `source/asr` 产物或 ASR 事件时写入 `external_asr_evidence=asr_artifacts_present`；传入 `-PlanOnly` 只输出计划，不作为验收通过。

### 自动证据与人工边界

自动 smoke、截图矩阵、portable 包检查和用户级脚本安装检查可以证明“链路接通、渲染非空、没有 Flutter overflow 警告条、release 包目录能定位 Python 源码、包内 Local Service 能响应基础 RPC、安装目录快捷方式身份正确”，也可以在本机校验 AppUserModelID 用户级开始菜单快捷方式；但不能替代人工直接观察真实 release 窗口，也不能替代每个用户环境里的外部凭据、语音识别依赖、Python runtime / FFmpeg 安装和正式分发包验收。下面每条若已被自动化覆盖，应继续保留对应命令；若依赖用户环境或外部凭据，必须标明仍需在对应环境复跑。

- 主窗口能启动 Local Service。
- 主窗口能读取真实配置摘要。
- release exe 已有隔离 smoke：`scripts/smoke_flutter_release.ps1` 会用临时 service root 启动 release 主窗口，确认真实 Local Service 可连接、能读取 `desktop.snapshot` 配置摘要，并通过主窗口 controller 的正常 `runtime.submitRun` 路径提交内嵌字幕视频；脚本同时启动临时本地 OpenAI-compatible 翻译服务，让默认 `video_asr_translate` 跑到真实 worker `DONE`，再校验 SRT / ASS 输出文件包含预期翻译文本；随后执行一次完成态 `result.open` 和 `result.reexport`，校验打开结果沿用原输出目录、reexport 事件并确认重新导出沿用原输出目录；传入 `-ScreenshotPath` 时会让 release 进程导出 Flutter 渲染树截图，校验窗口内容尺寸、非空像素和 Flutter overflow 警告条；传入 `-MainPhase empty|ready|blockedTranslation|blockedAsr|running|failed -ScreenshotPath` 时会渲染主窗口对应状态矩阵，覆盖等待片源、就绪主动作、翻译受阻、识别受阻、制作中和失败修复件的 release 渲染树截图；传入 `-WindowType translationSettings` / `-WindowType asrSettings` / `-WindowType diagnostics` / `-WindowType taskProcessing` 时会分别启动 release 非主窗口，读取临时翻译服务 / 语音识别配置、doctor 诊断报告、诊断窗最近任务结果目录检查或任务处理窗任务片并导出对应渲染树截图，同样检查非空像素和 Flutter overflow 警告条；其中 `taskProcessing` smoke 默认校验读取并选中 DONE 任务和结果目录可写性，`-TaskProcessingScenario edit` 会在右侧内嵌结果编辑器保存片段译文、选择 ASS / 单语重新导出，确认导出字幕包含编辑文本并校验 `result.reexport` 参数和结果目录可写性，`-TaskProcessingScenario failure` 会停在失败任务并导出失败 / 中断线索截图，`-TaskProcessingScenario resume` 会对失败任务触发真实 `runtime.submitResume` 并确认重新排队，`-TaskProcessingScenario cancel` 会对运行中任务触发真实 `runtime.cancel` 并确认进入 `CANCEL_REQUESTED`。旧 `resultReview` / `taskHistory` / `taskDetail` 独立窗口和 release smoke case 已移除，旧启动 ID 兼容进入任务处理窗。单次 smoke 成功报告会写入 `frontend_design_mvp_complete=false`、自动化覆盖范围和仍需人工验收清单。该 smoke 是自动化 release 进程链路、controller 提交路径、完成态结果打开 / 重新导出路径、诊断窗结果目录检查、任务处理窗浏览 / 编辑 / 失败线索 / 恢复 / 取消动作、任务处理窗结果目录检查、主窗口状态矩阵、非主窗口 release 渲染树与完成态渲染树证据，不代表真实可见窗口人工验收完成，也不替代真实外部翻译服务验收。
- 真实外部服务已有固定验收入口：`scripts\smoke_external_services.ps1` 默认用真实配置和凭据跑 `probe-provider --strict` + `translate --json`，证明外部翻译服务能完成样本字幕翻译；传入 `-InputPath <video>` 会额外跑真实媒体任务，并检查 `source/asr` 产物或 ASR 事件。当前本机已用 `providers.local.yaml` / 用户级凭据跑通 `google_vertex_gemini · gemini-3.5-flash`，`external_provider_probe_ok=true`、`external_translation_ok=true`、`external_media_task_ok=true`、`external_asr_evidence=asr_artifacts_present`。该脚本不会写入密钥，失败时输出 `ok=false` JSON。
- 真实可见窗口诊断：`scripts\smoke_flutter_release_matrix.ps1 -CheckDesktopComposite` 当前矩阵覆盖 16 个 release case，包含主流程完成态、完成态通知、主窗口六态、4 个非主窗口基础 case、`taskProcessing` edit / resume / cancel 和长模型名设置窗；本机已通过带桌面合成层采样的 16 case release matrix，16/16 个 case 写出有效桌面合成层截图，Flutter 渲染树与桌面合成层 overflow 警告条采样均为 0，通知 show、结果编辑重导出、失败任务恢复和运行中任务取消动作仍为通过；脚本会前置窗口并校验桌面截图像 TransVortex 浅色工作区，避免误抓背后窗口。这补了一层真实窗口区域证据，但还没有覆盖用户手动选择片源 / 提交 / 观察运行 / 完成 / 打开结果 / 审看结果的完整人工路径；该人工路径现在由 `scripts\accept_flutter_release_manual.ps1` 固化为可记录的 JSON 验收流程。
- 主窗口能把一次任务提交到后端；Dart 侧已有真实 Python Local Service 子进程 smoke 覆盖 `runtime.submitRun` / `runtime.cancel` / `tasks.events`，内嵌字幕 `video_asr` smoke 覆盖 Local Service pump → 真实 worker → `DONE` 输出，慢语音识别 smoke 覆盖真实 worker 取消后落到 `CANCELLED`，release exe smoke 已覆盖主窗口 controller 提交 `video_asr_translate`、真实 worker 到 `DONE`、SRT / ASS 输出和翻译文本校验。
- 主窗口能从 `desktop.snapshot.tasks` 恢复运行 / 失败任务摘要，长文件名和长失败提示不得溢出。
- 翻译 / 语音识别缺凭据时，主窗口进入受阻态，不调用 `runtime.submitRun`。
- 主窗口能把运行中任务的停止任务动作打到 `runtime.cancel`；可恢复失败任务的继续动作打到 `runtime.submitResume`；后端已补 `video_asr` 完成前取消标记检查，避免已请求取消的任务被最后一步覆盖成 `DONE`，并有真实 worker cancel → `CANCELLED` smoke 覆盖。
- 主窗口在任务从运行态进入完成 / 失败时会发系统通知；当前接入 Windows Toast 插件，release 包内已包含通知 DLL；Windows runner 已设置进程级 AUMID；`-CheckNotifications` release smoke 已覆盖完成态状态转移经通知 observer 触发 native 初始化 / show 调用 / AUMID registry 注册和 Windows Notifications Settings key；`-CheckAppIdentity` 已覆盖当前用户开始菜单快捷方式目标路径和 AUMID；用户已人工确认系统横幅出现。
- 翻译设置窗改默认方案后，主窗口即时更新。
- 翻译设置窗在无翻译配置 / 翻译服务测试失败时显示可理解中文，不泄露原始通道异常或上游英文连接错误。
- 语音识别设置窗至少能反映当前引擎和基础配置状态。
- 语音识别设置窗在无已保存方案时显示本机识别草稿和保存入口。
- 完成态能打开结果。
- 真实可见 release 窗口端到端完成前，只能宣称“Flutter MVP 接线成立”，不得宣称“前端设计 MVP 完成”；人工验收脚本 `-LaunchCheck` 已确认本机 release 窗口可启动并可写初始截图，但完整 G1 仍需人工操作通过；系统通知横幅已由人工确认出现，Windows 通知设置 key 和 AppUserModelID 用户级开始菜单快捷方式已由 release smoke 校验，portable 包内 Local Service RPC、用户级脚本安装和包目录启动检查已通过，真实外部翻译 / 语音识别已在本机跑通，但其他用户环境仍需用同一脚本复跑；正式 MSIX / installer 分发包、内置 Python runtime 和 FFmpeg 分发仍属后续打包工作。

---

## 8. 建议的实现顺序

> 下面「已完成」指当前 Flutter MVP 活跃路径已经具备对应能力。它仍**不等于**通过 G1 真实窗口验收；真实可见 release 窗口人工截图、极端内容和人工验收仍是完成证明。

1. 接线已完成：把主窗口的“开始译制”接到 `runtime.submitRun`。
2. 接线已完成：把主窗口状态改成真实任务状态源，并接 `tasks.events` / `runtime.cancel` / `runtime.submitResume`。
3. 接线已完成：把翻译设置窗接到 `provider.save` / `provider.routing.save` / `provider.test` / `provider.models`。
4. 接线已完成：补 `asr.provider.save` 并接语音识别设置窗最小保存链路。
5. 接线已完成：接完成态结果读取、打开字幕、打开所在文件夹、选择输出格式 / 单双语重新导出；目标文件缺失时进入重新导出修复态；重新导出失败且输出目录不可写时可选择新目录对同一任务重新导出。
6. UI 已从早期验证基座收束：主窗口 controller、六态主体、两个设置工具窗、正式窗口状态命名已经进入活跃构建。
7. 部分 G1/G6/G3/G4 证据已补：release 主窗口菜单能打开翻译 / 语音识别设置窗、诊断工具窗和任务处理窗并读取服务数据；release exe 隔离 smoke 已覆盖主窗口 controller 提交 `video_asr_translate`、临时本地 OpenAI-compatible 翻译服务翻译、真实 worker 到 `DONE`、SRT / ASS 输出、翻译文本校验、完成态 `result.open` 打开结果沿用原输出目录、`result.reexport` 事件和重新导出沿用原输出目录；带 `-ScreenshotPath` 的 release smoke 已覆盖 Flutter 渲染树截图、非空像素检查和 Flutter overflow 警告条检查；`smoke_flutter_release_matrix.ps1` 已把 release 主流程完成态、完成态通知检查、主窗口六态、4 个非主窗口基础 case、`taskProcessing` 编辑 / 恢复 / 取消三个追加 case 和长模型名设置窗固化为单命令，并在 summary 中记录任务处理窗选中、编辑保存、重新导出、失败恢复、运行中取消、结果目录可写性、通知 show 调用和 registry 结果；`taskProcessing` release smoke 已覆盖浏览 DONE 任务片、结果目录可写性、内嵌结果编辑保存、ASS / 单语重新导出、失败任务继续重新排队和运行中任务取消请求；旧 `resultReview` / `taskHistory` / `taskDetail` 独立窗口和 release smoke case 已移除；主窗口运行态 / 失败态长文本已有 widget 防溢出回归；无配置阻塞、翻译服务测试失败内容、诊断窗读取 doctor 报告和任务上下文摘要、诊断窗队列 / 中断任务线索定位、诊断窗最近任务结果目录检查、任务处理窗读取真实 `tasks.list`、任务片列状态筛选和搜索、任务失败 / 中断线索、任务事件 cursor 加载、任务事件搜索、内嵌结果审看 / 编辑工作台读取真实 `result.open` payload、按全部 / 有问题 / 空译文 / 已修改筛查片段、按源文 / 译文 / 问题提示搜索片段、还原单个已修改片段、放弃全部未保存修改、保存片段编辑、导出复核摘要、选择导出格式 / 单双语和重新导出、任务目录 / 结果目录打开、任务详情预览、创建 / 更新时间、运行记录、可用操作摘要、继续任务和取消任务动作已有自动化覆盖；取消、继续任务和结果文件缺失转重新导出修复态已有 controller / widget 防回归覆盖；Dart 侧已有真实 Python Local Service 子进程 submit/cancel/events smoke，内嵌字幕 `video_asr` 已覆盖真实 worker 完成到 `DONE`，慢语音识别已覆盖真实 worker 取消到 `CANCELLED`；Windows Toast 通知已接入并确认 release 包含 `flutter_local_notifications_windows.dll`，`-CheckNotifications` release smoke 已覆盖完成态状态转移经通知 observer 触发 native 初始化 / show 调用 / AUMID registry 注册，点击回调、前台抑制、同片源多任务通知重置和通知 payload 不泄露本地路径已有单测覆盖。
   - `taskProcessing -TaskProcessingScenario edit` release smoke 当前使用空译文片段触发后端 `result.open` 的真实问题计数，内嵌结果编辑器应显示问题数和“译文为空”提示。
8. 待验收：运行 `scripts\accept_flutter_release_manual.ps1` 完成真实可见 release 窗口完整任务端到端人工验收、正式 MSIX / installer 分发路径；portable 包脚本已补到“可移动 release 目录 + 包内 Local Service RPC + 用户级脚本安装”层级，但不包含正式安装器、Python runtime 或 FFmpeg；系统通知真实横幅已由人工确认出现，Windows 通知设置 key 和 AppUserModelID 用户级开始菜单快捷方式已由 release smoke 校验；真实外部翻译 / 语音识别场景已在本机用 `smoke_external_services.ps1` 跑通，但需在目标用户环境复跑。
9. 后续：做完整历史恢复矩阵、完整诊断修复台、术语、跨任务批量结果筛查、完整结果编辑器、高级导出复核、托盘 / 打包分发和更完整的人工验收矩阵。

---

## 9. 当前缺口总表

| 项目 | 现状 | 处理建议 |
| --- | --- | --- |
| 主窗口启动与健康检查 | 已接真实服务；release exe 隔离 smoke 已覆盖启动 Local Service、读取配置摘要、主窗口 controller 提交 `video_asr_translate` 到 `DONE` 并校验 SRT / ASS 输出；带 `-ScreenshotPath` 时可由 release 进程导出 Flutter 渲染树截图并校验尺寸 / 非空像素 / Flutter overflow 警告条；本机真实外部服务 smoke 已覆盖真实 provider、翻译、媒体任务和 ASR 产物证据 | 持续保留诊断入口；后续补真实可见窗口人工验收，其他用户环境需复跑外部服务 smoke |
| 主窗口提交任务 | 已接 `runtime.submitRun`；默认 `output_dir` 指向片源同目录，输出目录不可写时可选择新目录并重试；翻译 / 语音识别未配置时会阻塞提交，并有 controller 防回归覆盖；真实 Python Local Service 子进程 smoke 已覆盖 submit；release exe smoke 已覆盖主窗口 controller 提交路径，使用临时本地翻译服务完成 `video_asr_translate` 到 `DONE`；本机外部服务 smoke 已用真实 provider 完成 `DemoTest/英文视频.mp4` 到 `DONE` | 后续补更完整失败修复矩阵和真实可见窗口人工验收 |
| 主窗口运行态 | 已接 `runtime.snapshot` / `tasks.events`，可从 `desktop.snapshot.tasks` 恢复现有任务；取消和继续任务有 controller 防回归覆盖；真实 Python Local Service 子进程 smoke 已覆盖 cancel/events；后端已补 `video_asr` 完成前取消竞态回归；慢语音识别 smoke 已覆盖真实 worker 取消到 `CANCELLED`；release exe smoke 已覆盖任务完成后刷新到 `task_count: 1` / `status: ready` / controller `completed`；任务详情窗已能读取真实事件并对可恢复任务调用 `runtime.submitResume` | 后续补完整历史恢复矩阵和真实可见 release 窗口人工验收 |
| 系统通知 | 已接 `flutter_local_notifications` Windows Toast；仅在任务从运行态进入完成 / 失败且窗口不在前台时触发，有 observer / widget 防回归覆盖，点击回调聚焦主窗口，release 包已包含通知 DLL；Windows runner 已设置进程级 AUMID；`-CheckNotifications` release smoke 已覆盖完成态状态转移经通知 observer 触发 native 初始化 / show 调用 / AUMID registry 注册和 Windows Notifications Settings key；`scripts\install_flutter_desktop_shortcut.ps1` 和 `-CheckAppIdentity` 已覆盖当前用户开始菜单快捷方式目标路径和 AUMID，且通知 AUMID 与快捷方式 AUMID 一致；用户已人工确认系统横幅出现；payload 使用 task id / 本地 hash，不携带完整源文件路径 | 后续补正式 MSIX / installer 分发路径下的通知中心行为；非 MSIX 下插件文档说明通知历史和取消能力不可用 |
| 翻译设置保存 | 已接翻译服务保存、模型拉取、连接测试、默认路由；release 主菜单路径已验证能打开设置窗并读服务数据；`-WindowType translationSettings` release smoke 已覆盖 release 窗口读取翻译服务配置、Flutter 渲染树截图和 Flutter overflow 警告条检查；无翻译配置和连接测试失败有 widget 防回归覆盖；本机已用真实 `google_vertex_gemini` 跑通 provider probe 和样本翻译 | 后续补 fallback routing、高级 mapping；其他用户环境需复跑外部服务 smoke |
| 语音识别设置保存 | 已补 `asr.provider.save` 并接 UI；release 主菜单路径已验证能打开设置窗并读服务数据；`-WindowType asrSettings` release smoke 已覆盖 release 窗口读取语音识别配置、Flutter 渲染树截图和 Flutter overflow 警告条检查；无已保存方案时回落到本机识别草稿并有 widget 覆盖；本机外部服务 smoke 已在媒体任务中发现 ASR 产物和 ASR 事件 | 后续补与诊断结果的定位 / 修复联动和高级参数；其他用户环境需复跑外部服务 smoke |
| 完成态结果动作 | 已接 `result.open` / `result.segments.save` / `result.reexport` / 系统打开，并有 controller 防回归覆盖打开字幕、打开目录、重新导出和结果审看入口；打开前会确认目标文件仍存在，缺失时进入重新导出修复态且有 widget 防回归；重新导出失败时可选择新目录并对同一任务重新导出，后端会在成功后把任务修回 `DONE`；完成态优先打开任务处理窗并定位任务，右侧可内嵌结果审看 / 编辑工作台；release exe smoke 已覆盖完成态 `result.open` 和 `result.reexport` 真实 RPC、打开结果沿用原输出目录、reexport 事件并确认重新导出沿用原输出目录；`taskProcessing -TaskProcessingScenario edit` 可读取真实 `result.open` 工作区，按全部 / 有问题 / 空译文 / 已修改筛查片段，按源文 / 译文 / 问题提示搜索片段，还原单个已修改片段，放弃全部未保存修改，保存片段编辑，显示导出复核摘要，选择 ASS / 单语重新导出，并确认导出字幕包含编辑文本 | 后续补跨任务批量筛查、完整结果编辑器、高级导出复核和真实人工点击路径 |
| 诊断工具窗 | 最小入口已接 `desktop.snapshot.environment`，可展示 doctor 总体状态、检查项、中文建议、错误码和关键路径；同窗显示活动任务、任务数、队列和中断任务的只读上下文摘要，队列 / 中断任务可用短线索定位任务处理窗；可调用真实 `tasks.list` 刷新最近任务，并对完成任务调用 `result.open` 显示片段数、问题数和输出格式；常见翻译 / 语音识别检查项可跳转到已接线的设置窗，任务 / runtime / queue / interrupted / resume 类检查项和最近任务行可跳转任务处理窗并定位任务；最近任务行可对有输出记录的任务检查结果目录可写性；`-WindowType diagnostics` release smoke 已覆盖读取临时 doctor 报告、最近任务结果目录可写性、Flutter 渲染树截图和 overflow 检查 | 后续补完整自动修复台、运行队列操作 / 更完整任务详情诊断 |
| 任务历史 / 术语 | 任务处理窗已成为任务历史 / 详情 / 结果编辑的新主入口，使用真实 `tasks.list` 展示任务片列、按全部 / 制作中 / 待处理 / 已完成筛选任务、按片源 / 任务 ID / 状态 / 失败摘要 / 目录线索搜索任务、选中任务预览、创建 / 更新时间、运行记录、可用操作摘要、最近事件并可按 cursor 加载更多事件、已加载事件本地搜索、完成任务内嵌编辑、失败任务继续动作和运行中任务取消动作，并可打开任务目录 / 结果目录；旧任务历史窗和任务详情独立窗已移除，旧启动 ID 兼容进入任务处理窗；术语未纳入 MVP | 后续补任务处理窗完整恢复矩阵和术语管理 |

---

## 10. 结语

这份清单的定位很简单：它把 Flutter 前端 MVP 从“看起来像在做”变成“知道下一步该接哪根线”。

截至当前实现，主窗口真实任务流、翻译设置工具窗、语音识别设置工具窗、诊断工具窗和任务处理窗的 **MVP 接线**已经成立，活跃 Flutter 代码也已从早期验证命名和调试入口收束到正式窗口模型；旧兼容结果审看 / 任务历史 / 任务详情独立窗已移除，旧启动 ID 兼容进入任务处理窗。当前已补一部分 G1/G6/G3/G4 证据：release 主菜单路径可打开设置窗、诊断窗和任务处理窗，release exe 隔离 smoke 可启动 Local Service、读取配置摘要、通过主窗口 controller 正常提交 `video_asr_translate`、经临时本地 OpenAI-compatible 翻译服务翻译、等待真实 worker 到 `DONE`，校验 SRT / ASS 输出文件和翻译文本，并执行完成态 `result.reexport`、校验 reexport 事件且确认重新导出沿用原输出目录；任务处理窗 release smoke 已覆盖读取并选中 DONE 任务、结果目录可写性、内嵌结果编辑保存、ASS / 单语重新导出、导出字幕包含编辑文本、失败任务线索停留态、失败任务继续重新排队和运行中任务取消请求；当前 16 case release matrix 已通过桌面合成层采样，16/16 个 case 写出有效桌面合成层截图，Flutter 渲染树与桌面合成层 overflow 警告条采样均为 0，`taskProcessing` cancel case 也确认 `task_processing_cancel_ok=true`；人工验收脚本 `-LaunchCheck` 已确认本机 release 窗口可启动并可写初始截图，但 `manual_visible_e2e_ok=false` 仍保留完整人工路径边界；`-CheckNotifications` release smoke 已覆盖完成态状态转移经主窗口通知 observer 触发真实 Windows toast 插件初始化 / show 调用、AUMID / GUID registry 注册和 Windows 通知设置 key，`-CheckAppIdentity` 已覆盖用户级开始菜单快捷方式目标路径和 AUMID，用户也已人工确认系统横幅出现；主窗口运行 / 失败长文本有自动化防溢出测试，完成态打开结果 / 打开目录 / 重新导出 / 任务处理窗入口和目标文件缺失转重新导出修复态有防回归覆盖，无配置阻塞、翻译服务测试失败内容、诊断窗读取 doctor 报告和任务上下文摘要、诊断窗队列 / 中断任务线索定位、诊断窗最近任务结果目录检查、任务处理窗读取真实 `tasks.list`、任务片列状态筛选和搜索、任务事件搜索、结果审看读取真实 `result.open`、已修改片段筛查、还原单个已修改片段、放弃全部未保存修改、保存片段编辑、导出复核摘要、选择导出格式 / 单双语和重新导出、任务详情预览、创建 / 更新时间、运行记录、可用操作摘要、继续任务与取消任务动作、Windows Toast 通知触发也已有自动化覆盖；Dart 到真实 Python Local Service 的 submit/cancel/events smoke 已通过，内嵌字幕 `video_asr` 已覆盖真实 worker 完成到 `DONE` 输出，慢语音识别已覆盖真实 worker 取消到 `CANCELLED`；本机真实外部服务 smoke 已跑通 provider probe、样本翻译、媒体任务和 ASR 产物证据。剩余关键证明是完整真实可见 release 窗口任务链路和系统集成：人工选择片源 / 提交 / 观察运行 / 完成或取消 / 打开结果 / 审看结果，其他用户环境外部服务复跑，以及正式 MSIX / installer 分发路径。通过完整 G1 前，不应宣称“前端设计 MVP 已完成”。
