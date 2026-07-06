# Flutter 前端实施契约

本文档只解决一件事：把早期 Flutter 验证收束为正式候选前端的施工边界，并约束后续不能再回到临时前端路径。

它不是新的设计方向，也不是新的视觉原型。硬规则以 `../rules/FRONTEND_FAILURE_RECOVERY_RULES.md` 为准，剩余交付目标以 `FRONTEND_DELIVERY_GOALS.md` 为准，窗口与交互规格以 `FRONTEND_DESIGN_SPEC.md` 为准。本文只规定实现时哪些东西保留、哪些东西重做、每个窗口先接哪些能力，以及如何验收。

---

## 1. 当前结论

早期 Flutter 验证已经确认：

- Flutter 可以启动 Python Local Service。
- Dart 侧可以通过 stdin/stdout JSON-RPC 调用 `transvortex.app_service`。
- 主窗口和子窗口可以短期复用同一个 Local Service。
- 主流程可以提交任务、刷新事件、取消任务、读取结果。
- 设置窗可以调用翻译服务 / 语音识别相关后端入口。

这些是服务接线成果，不是正式 UI 成果。

后续不再做 HTML mock、不再做新的视觉 demo、不再继续在临时 UI 上堆功能。正式 Flutter MVP 直接在产品代码路径中实现，并以真实 Flutter 渲染证据、真实可见窗口人工截图和真实 Local Service 链路验收。

---

## 2. 保留与重做

### 保留

- `JsonRpcTransport`
- `LocalServiceSupervisor`
- `LocalServiceController`
- `AppServiceClient`
- Python `transvortex.app_service` JSON-RPC 入口
- `DesktopApi` 中已经存在的桌面控制面方法
- 短期由主 Flutter engine 托管 Local Service，子窗口通过 bridge 转发调用的过渡方案

这些属于通信和服务基础设施，可以继续演进。

### 已从早期验证收束

- 主窗口已抽出 `MainWindowController`，由 view model 承载状态呈现和 `runtime.submitRun` payload。
- 翻译模型设置窗已收束为主从工具窗结构。
- 语音识别设置窗已收束为三引擎结构。
- `JobLine` 的翻译模型和语音识别选项来自 `desktop.snapshot`，不再是 mock 选择。
- 已移除旧验证状态命名和临时探针入口。

这些已进入正式候选前端路径，但仍需真实可见 release 窗口人工验收和系统集成验收。

### 仍需继续补齐

- 更完整的失败修复矩阵和诊断入口。
- 真实可见 release 窗口端到端人工验收；使用 `scripts\accept_flutter_release_manual.ps1` 记录逐步确认、窗口截图和 JSON 报告。
- 其他目标用户环境里的真实外部翻译服务 / 语音识别复跑；本机已用 `smoke_external_services.ps1` 跑通真实 provider、样本翻译、媒体任务和 ASR 产物证据。
- 正式 MSIX / installer 打包分发、托盘和分发路径下的通知中心行为；当前 portable 包脚本已能把 release bundle、Python 源码、提示词、示例 provider 配置、用户级安装脚本和快捷方式辅助脚本打在同一目录，并验证包内 Local Service RPC、用户级脚本安装与可选窗口启动，但它不内置 Python runtime / FFmpeg，也不是安装器；系统通知横幅已由人工确认出现，AppUserModelID 用户级开始菜单快捷方式已有脚本化建立 / 校验入口。
- 跨任务批量筛查、完整结果编辑器、完整历史恢复矩阵和术语管理等后续窗口；任务处理窗已经作为任务历史 / 详情 / 结果编辑的新主入口接入，支持任务片列、按全部 / 制作中 / 待处理 / 已完成筛选任务、按片源 / 任务 ID / 状态 / 失败摘要 / 目录线索搜索任务、选中任务预览、创建 / 更新时间、运行记录、可用操作摘要、失败 / 中断线索、最近事件、按 cursor 加载更多事件和已加载事件本地搜索、完成任务内嵌编辑、任务目录 / 结果目录打开、可恢复任务继续动作和可取消任务取消动作；旧最小结果审看 / 任务历史 / 任务详情独立窗已移除，旧启动 ID 兼容进入任务处理窗。

### 先修护栏

已接真实副作用的入口必须持续满足：

- 保存翻译默认时不得清空已有 fallback routing。
- 保存语音识别默认方案时必须传递并校验 `pipeline.yaml` 版本。
- 任何看起来可改变本单运行方案的 UI，必须真实影响 `runtime.submitRun` payload；否则禁用或移除。
- 字幕输入在后端未确认支持前只允许 `.srt`，不得把 `.ass` / `.vtt` 伪装成已支持输入。

---

## 3. MVP 窗口范围

### 主窗口

主窗口只承载一次任务：

- 选择片源。
- 显示当前任务方案摘要。
- 开始 / 停止 / 重试 / 处理新片源。
- 展示六态。
- 完成后打开结果、打开目录、重新导出。

不承载：

- 翻译服务深配置。
- 语音识别深配置。
- 完整历史恢复矩阵。
- 完整诊断报告（最小只读诊断入口在独立工具窗）。
- 术语管理。
- 结果审看完整编辑器、跨任务批量筛查与高级导出复核。

### 翻译模型设置窗

翻译设置窗只承载模型服务准备配置：

- 翻译服务列表。
- 翻译服务详情。
- API key 保存。
- 模型拉取。
- 连接测试。
- 设为默认翻译方案。

不得做成滚动翻译服务卡片台，不得把主窗口任务配置混进来。

### 语音识别设置窗

语音识别设置窗只承载识别方案准备配置：

- 本机识别。
- FunASR 本地服务。
- 云端 OpenAI Whisper。
- 每个引擎的最小必要字段。
- 保存默认识别方案。

高级 chunking、静音切分、并发、预处理、字幕轨强制选择等延后。

### 诊断工具窗

诊断工具窗只承载最小只读 doctor 报告、任务上下文摘要和最近任务 / 结果摘要：

- 读取 `desktop.snapshot.environment`。
- 展示总体 PASS / WARN / FAIL。
- 展示检查项、中文建议、错误码和关键路径。
- 从 `desktop.snapshot` 显示活动任务、任务数、队列和中断任务的只读摘要；队列 / 中断任务只显示短线索，并可定位到任务处理窗。
- 从真实 `tasks.list` 刷新最近任务。
- 对完成任务用 `result.open` 读取片段数、问题数和输出格式摘要。
- 提供真实刷新。

不得在修复动作未接线前放假按钮；当前只允许跳转到已真实接线的翻译模型设置 / 语音识别设置、打开 doctor 报告里的产物目录路径、从诊断窗的队列 / 中断任务线索或最近任务行定位任务处理窗、在任务处理窗查看失败 / 中断任务的只读处理线索、在诊断窗最近任务行和任务处理窗里对单个任务结果目录做用户触发的可写性检查，或对 `can_resume` 任务调用真实 `runtime.submitResume`。完整诊断修复台、运行队列操作、完整历史恢复矩阵、完整结果编辑器和更完整任务详情诊断延后。

---

## 4. 主窗口状态契约

| 状态 | UI 来源 | 主要呈现 | 主动作 | 后端动作 |
| --- | --- | --- | --- | --- |
| 空 | 本地 draft | 投递口，无 job 描述 | 选择片源 | 系统文件对话框 |
| 就绪 | 本地 draft + `desktop.snapshot.config` | 片源封套 + 当前方案摘要 | 开始译制 | `runtime.submitRun` |
| 受阻 | `desktop.snapshot.configReadiness` | 对应词显示需配置 | 去配置翻译 / 识别 | 打开对应设置窗 |
| 制作中 | `runtime.snapshot` + `tasks.events` | 当前阶段文案 + 真实进度 | 停止任务 | `runtime.cancel` |
| 完成 | task terminal status + result paths | 交付态 + 结果动作 | 处理新片源 | `result.open` / `result.reexport` |
| 失败 | task `error_info` + events | 一句话原因 + 修复动作 | 重试 / 去修复 | 视错误映射决定 |

进度只来自真实事件或任务摘要。无真实进度时不得伪造百分比。

---

## 5. 用户动作到 RPC

| 用户动作 | RPC | 状态刷新 |
| --- | --- | --- |
| App 启动 | `service.info` / `service.health` / `desktop.snapshot` | 初始化服务状态、配置摘要和任务摘要 |
| 选择片源 | 系统文件对话框 | 更新本地 draft |
| 开始译制 | `runtime.submitRun` | 保存 `task_id`，开始轮询 |
| 停止任务 | `runtime.cancel` | 刷新 runtime 和任务事件 |
| 运行中刷新 | `runtime.snapshot` / `tasks.events` | 更新阶段文案、进度、失败信息 |
| 审看结果 | `result.open` / `result.segments.save` / `result.reexport` | 优先打开任务处理窗并定位任务，在右侧内嵌结果审看 / 编辑工作台读取任务摘要、字幕片段、输出格式和问题提示；允许按全部 / 有问题 / 空译文 / 已修改筛查片段，并按源文 / 译文 / 问题提示搜索片段；允许还原单个已修改片段、放弃全部未保存修改、编辑并保存片段译文；重新导出前显示将导出的格式 / 单双语和已有输出记录，再按用户选择调用真实重新导出；旧 `resultReview` 启动 ID 兼容进入任务处理窗 |
| 打开字幕 | `result.open` | 读取 result paths，确认文件仍存在后交给系统打开；缺失则进入重新导出修复态 |
| 打开目录 | `result.open` | 读取 result paths，确认文件仍存在后交给系统打开；缺失则进入重新导出修复态 |
| 重新导出 | `result.reexport` | 刷新 result paths 和任务事件；默认沿用原输出目录，任务处理窗右侧的结果审看 / 编辑工作台可选择 SRT / ASS / SRT+ASS / VTT 和单双语；若重新导出失败且指向输出目录不可写，失败修复件可让用户选择新目录，并把 `output_dir` 传给同一任务的 `result.reexport` |
| 保存翻译服务 | `provider.save` | 刷新 `config.get` 或 `desktop.snapshot` |
| 拉模型 | `provider.models` | 更新当前详情 draft |
| 测试翻译服务 | `provider.test` | 显示测试结果 |
| 设默认翻译 | `provider.routing.save` | 刷新配置并通知主窗口 |
| 保存语音识别默认 | `asr.provider.save` | 刷新配置并通知主窗口 |

UI 不直接调用 `runtime.acquireNext` 或 `runtime.releaseActive`。这两个方法属于 pump / worker 控制面。

---

## 6. 状态与数据所有权

正式 UI 必须区分三类状态：

- 本地 draft：用户还没提交任务的片源、输出格式、双语、术语生成等。
- 服务 snapshot：配置就绪、默认翻译服务、默认语音识别、任务列表、runtime 状态。
- 任务事件：当前任务的阶段、进度、错误上下文。

Flutter widget 不应把这些状态散落在多个组件里直接互相覆盖。正式实现应引入主窗口 controller / view model，负责：

- 从服务状态生成展示态。
- 从本地 draft 生成 `runtime.submitRun` request。
- 处理任务事件 cursor。
- 把错误映射成用户可理解的修复动作。

---

## 7. 美术实施边界

本轮不再先做完整参考图、HTML 原型或独立视觉 demo。

MVP 美术执行采用文字契约 + 真实 Flutter 窗口验收：

- 先用统一线条、平涂色块、克制阴影和设计 token 做可控视觉语言。
- 不把 UI 成败押在一批 PNG 资产或 AI 生成图上。
- 图片资产可以后置；若使用，必须服务于 `FRONTEND_DESIGN_SPEC.md` 的单一世界对象。
- 控件不得退回默认 Material 气质；按钮、输入、选择行、菜单必须使用项目 token。
- 不使用渐变背景、玻璃拟态、卡片墙、装饰噪声和通用 Web 管理台结构。

验收以真实 Flutter 渲染证据和真实可见窗口人工截图为准，不以 HTML 页面或静态 mock 为准。

---

## 8. 错误恢复

失败态不得直接显示原始异常字符串作为主要信息。

可见 UI 同样不得直接把协议字段当用户文案：任务状态 / 阶段要映射成中文动作语义，语言码要映射成自然语言名，`task_id` 只作为短辅助编号或兜底摘要，完整本地路径只在诊断定位或显式复制 / 打开目录动作中出现。

正式 UI 至少要识别这些恢复方向：

| 错误来源 | 用户可理解问题 | 恢复动作 |
| --- | --- | --- |
| 缺翻译服务密钥 | 翻译服务还没配置密钥 | 打开翻译设置窗 |
| 翻译服务测试失败 | 翻译服务连不上 | 打开翻译设置窗并定位当前翻译服务 |
| 缺语音识别密钥 | 云端识别还没配置密钥 | 打开识别设置窗 |
| 本机语音识别依赖缺失 | 本机识别环境不完整 | 打开诊断 / 切换识别方案 |
| 输入文件不存在 | 片源找不到 | 重新选择片源 |
| 输出目录不可写 | 无法写入字幕文件 | 首次运行 / 预检失败时选择可写目录并重试；重新导出失败时选择可写目录并对同一任务重新导出 |
| worker interrupted | 任务中断 | 继续任务 / 重试 |

后端 `code`、`hint_zh`、`details` 是错误映射来源。没有映射时可以显示兜底文案，但仍要保留可操作恢复动作。

---

## 9. 验收标准

每个正式 UI 里程碑至少保留以下截图或记录：

- 主窗口空态。
- 主窗口就绪态。
- 主窗口受阻态。
- 主窗口制作中。
- 主窗口完成态。
- 主窗口失败态。
- 翻译模型设置窗。
- 语音识别设置窗。
- 诊断工具窗。
- 最长文件名 / 最长翻译服务 id / 最长错误文案压力场景。

每个里程碑至少验证：

- `flutter analyze`
- `flutter test`
- Windows release 运行或等效真实桌面窗口验证
- portable release 包变更时，跑 `scripts\package_flutter_release.ps1 -OutputRoot <dir> -LaunchCheck`，确认包内 Local Service 能响应 `service.info` / `service.health` / `service.shutdown`，并确认包目录内 `TransVortex.exe` 能启动；再跑 `scripts\install_flutter_portable_release.ps1 -SourceRoot <portable-package> -InstallRoot <dir> -ShortcutPath <lnk> -Force`，确认用户级安装目录里的 Local Service RPC 和 AUMID 快捷方式
- 涉及 Python 后端时，运行相关 `pytest`

如果某项无法验证，必须在回复或提交说明里明确写出原因和风险。

---

## 10. 禁止继续发生的事

- 不再用 HTML mock 作为下一阶段主要产物。
- 不再新增一个临时前端验证分支。
- 不在未定稿 UI 上继续增加真实落盘能力。
- 不把 CLI 命令一比一搬进桌面 UI。
- 不把跨窗口 bridge 当长期业务后端总线。
- 不在 widget 内直接堆所有 RPC、draft 拼装和错误恢复逻辑。
- 不为了“先能点”引入会误导用户的假选择器。

---

## 11. 下一步顺序

1. 持续守住真实副作用护栏。
2. 以主窗口 controller / view model 为主状态来源。
3. 对主窗口正式六态做真实窗口验收。
4. 回归主窗口真实 `runtime.submitRun`、事件轮询、真实取消结果、继续任务和完成态结果动作；取消 / 继续任务当前已有 controller 防回归，结果文件缺失时会进入重新导出修复态并有 controller / widget 防回归，release exe 隔离 smoke 已覆盖启动 Local Service、读取配置摘要、通过主窗口 controller 正常提交 `video_asr_translate`、经临时本地 OpenAI-compatible 翻译服务翻译到真实 worker `DONE` 并校验 SRT / ASS 输出文本，随后执行 `result.open` 和 `result.reexport`，校验打开结果沿用原输出目录、reexport 事件并确认重新导出沿用原输出目录；任务处理窗可通过 `-WindowType taskProcessing` release smoke 单独拉起，默认浏览态读取并选中 DONE 任务片、验证结果目录可写性，`-TaskProcessingScenario edit` 会在右侧内嵌结果编辑器保存片段译文、选择 ASS / 单语重新导出并确认导出字幕包含编辑文本，同时验证结果目录可写性，`-TaskProcessingScenario failure` 会停在失败任务并导出失败 / 中断线索截图，`-TaskProcessingScenario resume` 会选中失败任务并触发真实 `runtime.submitResume` 重新排队，`-TaskProcessingScenario cancel` 会选中运行中任务并触发真实 `runtime.cancel` 到 `CANCEL_REQUESTED`；旧 `resultReview` / `taskHistory` / `taskDetail` 独立窗口类型和 release smoke case 已移除，旧启动 ID 兼容进入任务处理窗；带 `-ScreenshotPath` 时会由 release 进程导出 Flutter 渲染树截图并校验尺寸 / 非空像素 / Flutter overflow 警告条，Dart 到真实 Python Local Service 的 submit/cancel/events smoke 已通过，内嵌字幕 `video_asr` 已覆盖 Local Service pump → 真实 worker → `DONE` 输出，慢语音识别已覆盖真实 worker cancel → `CANCELLED`。
   - `taskProcessing -TaskProcessingScenario edit` release smoke 使用空译文片段触发后端 `result.open` 真实问题计数，覆盖结果审看问题提示、最小片段筛查和片段搜索的数据来源。
   - `scripts\smoke_flutter_release_matrix.ps1` 已把 release 主流程完成态、完成态通知检查、主窗口六态、4 个非主窗口基础 case、`taskProcessing` 编辑 / 失败线索 / 恢复 / 取消四个追加 case 和长模型名设置窗固化为单命令，用于回归布局、Flutter overflow、任务处理窗编辑 / 失败线索 / 恢复 / 取消动作和通知接线问题。
5. 回归系统通知真实桌面路径；当前已接 Windows Toast 插件、完成 / 失败触发、前台抑制和点击聚焦回调，release smoke 已覆盖完成态状态转移经主窗口通知 observer 触发 native 初始化 / show 调用 / AUMID registry 注册和 Windows Notifications Settings key，Windows runner 已设置进程级 AUMID，用户级开始菜单快捷方式可由 `scripts\install_flutter_desktop_shortcut.ps1` 创建并校验，`-CheckAppIdentity` release smoke 已验证通知 AUMID 与快捷方式 AUMID 一致，用户已人工确认真实横幅出现；portable 包脚本已验证包含通知 DLL、快捷方式辅助脚本、用户级安装脚本和 Python 源码布局的包内 Local Service RPC、用户级脚本安装与包目录启动；后续补正式 MSIX / installer 分发路径下的通知中心行为。
6. 持续覆盖翻译模型设置窗长模型名 / 无 key / 测试失败场景；当前已有 widget 防回归，release smoke 已覆盖 release 翻译设置窗读取临时翻译服务配置、Flutter 渲染树截图和 Flutter overflow 警告条检查。
7. 持续覆盖语音识别设置窗三引擎 / 无依赖 / 云端缺 key 场景；当前已覆盖空保存方案、本机草稿回落，以及 release 语音识别设置窗读取临时语音识别配置、Flutter 渲染树截图和 Flutter overflow 警告条检查；诊断窗可从语音识别 / faster-whisper / FunASR 检查项跳转到语音识别设置。
8. 持续覆盖诊断工具窗读取 doctor 报告；当前 release smoke 已覆盖 `-WindowType diagnostics`、最近任务结果目录可写性、Flutter 渲染树截图和 Flutter overflow 警告条检查，常见翻译 / 语音识别检查项已有设置窗跳转入口，widget 已覆盖任务上下文摘要、队列 / 中断任务线索定位到任务处理窗、真实 `tasks.list` 最近任务刷新、完成任务 `result.open` 结果摘要和最近任务结果目录检查；任务处理窗已覆盖失败 / 中断任务的只读处理线索；完整自动修复台、运行队列操作和更完整任务详情诊断后续补。
9. 再进入完整历史恢复矩阵、术语管理、跨任务批量筛查、完整结果编辑器和高级导出复核等后续窗口。
