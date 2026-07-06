# Flutter 前端当前交付目标

本文档只回答一个问题：**Flutter 前端下一阶段还必须交付什么，做到什么算完成**。

它不是旧 `FRONTEND_DEVELOPMENT_GOALS.md` 的续写，也不是新的设计规格。旧 Goal 已归档为历史推导；当前交付目标以已经成立的 Flutter MVP 接线为起点，聚焦剩余产品闭环、验收纪律和工程清理。

当前文档关系：

- 硬规则：`../rules/FRONTEND_FAILURE_RECOVERY_RULES.md`。
- 界面规格：`FRONTEND_DESIGN_SPEC.md`。
- 实施边界：`FRONTEND_IMPLEMENTATION_CONTRACT.md`。
- 施工清单：`FLUTTER_FRONTEND_IMPLEMENTATION_CHECKLIST.md`。

---

## 1. 已完成基线

截至当前实现，下面这些内容视为 Flutter MVP 接线基线，不再作为新 Goal 重复展开：

- 主窗口可以启动并使用 Python Local Service。
- 主窗口可以读取真实服务状态和真实配置摘要。
- 主窗口“开始译制”已经接到 `runtime.submitRun`。
- 运行态已经接 `runtime.snapshot` / `tasks.events` / `runtime.cancel`。
- 翻译设置窗已经接翻译服务相关入口：`provider.save` / `provider.routing.save` / `provider.test` / `provider.models`。
- 语音识别设置窗已经有 `asr.provider.save` 最小保存链路。
- 完成态已经能读取结果，并优先进入任务处理窗里的内嵌结果审看 / 编辑工作台；旧最小结果审看独立窗已移除，旧 `resultReview` 启动 ID 会兼容进入任务处理窗。结果编辑可保存片段译文、选择输出格式 / 单双语重新导出、打开字幕、打开所在文件夹；打开前会检查结果文件是否仍在原位置，缺失时进入“重新导出”修复态；重新导出时若输出目录不可写，可选择新目录对同一任务重新导出。
- 诊断工具窗已有最小只读入口，可从 `desktop.snapshot.environment` 展示 doctor 检查项，从同一 `desktop.snapshot` 显示活动任务、任务数、队列和中断任务的只读上下文摘要，并可用真实 `tasks.list` 刷新最近任务、对完成任务读取 `result.open` 的结果摘要。
- 任务处理窗已有工作台入口，可通过真实 `tasks.list` 展示任务片列、按全部 / 制作中 / 待处理 / 已完成筛选任务、选中任务预览、最近事件并按 cursor 加载更多事件、完成任务内嵌编辑、失败任务继续动作和运行中任务取消动作，并打开任务目录 / 结果目录；旧任务历史窗和任务详情窗已移除，旧 `taskHistory` / `taskDetail` 启动 ID 会兼容进入任务处理窗。

这些能力仍需在真实桌面窗口里持续回归，但不再证明“Flutter 能不能接后端”。

---

## 2. 当前交付目标

### G1 — 真实窗口验收矩阵

目标：把当前 Flutter MVP 从“功能接线成立”推进到“真实桌面窗口可验收”。

完成标准：

- Windows Flutter release 窗口可以完成一次主流程验收：启动服务、读取配置、选择片源、提交任务、运行中刷新、取消或完成、打开结果。
- 主窗口、翻译模型设置窗、语音识别设置窗都在真实窗口中验收，不以 HTML mock、debug 视觉或文档描述替代。
- 最坏内容下无明显布局碰撞：超长文件名、无翻译配置、无语音识别配置、翻译服务测试失败、语音识别依赖缺失、任务失败、结果缺失。
- 每次前端里程碑都记录实际验证命令和未覆盖风险。

### G2 — 失败修复闭环

目标：失败态不是错误展示页，而是能引导用户恢复的修复对象。

完成标准：

- 翻译服务未配置、密钥无效、语音识别不可用、输出目录不可写、任务运行失败都有明确恢复动作。
- 主窗口失败态只呈现与恢复相关的信息，不铺完整诊断面板。
- 深诊断进入独立诊断窗口或后续工具窗，不在主窗口常驻。
- “重试 / 去配置 / 选择目录 / 打开诊断”这类动作真实接线，不做假按钮。

### G3 — 结果审看与导出复核

目标：完成态不止能打开文件，还要能进入结果审看和导出复核。

完成标准：

- 完成态可以进入结果审看入口。
- 当前已有任务处理窗内嵌的结果审看 / 编辑工作台，可通过真实 `result.open` 展示任务摘要、片段、输出格式和问题提示，可按全部 / 有问题 / 空译文 / 已修改筛查片段，并可按源文 / 译文 / 问题提示搜索片段；允许放弃未保存修改，通过 `result.segments.save` 保存片段译文；可在重新导出前复核将导出的格式 / 单双语和已有输出记录，并通过 `result.reexport` 按用户选择重新导出当前结果；旧 `resultReview` 独立窗已移除，后续再补跨任务批量筛查、完整编辑器和高级导出复核。
- 重新导出能明确使用当前结果和用户选择的输出格式。
- 结果缺失、导出失败、目标文件被移动时有可理解的恢复路径；当前已覆盖目标文件缺失 / 被移动时的重新导出修复动作，以及重新导出失败时选择新输出目录并对同一任务重新导出的恢复动作，跨任务批量筛查、完整结果编辑器与高级导出复核仍属后续。

### G4 — 任务历史与任务详情

目标：历史任务、运行事件和任务详情有明确归属，不再只是后端能力。

完成标准：

- 任务历史入口现在优先打开任务处理窗，不抢占主窗口主视角。
- 当前任务处理窗使用真实 `tasks.list` 展示任务状态、片源、输出格式和失败摘要；完成任务可在右侧进入内嵌结果编辑，失败任务可在同窗查看摘要、最近事件并通过 `tasks.events` cursor 继续加载更多事件，也可调用真实 `runtime.submitResume` 继续任务、打开任务目录 / 结果目录。
- 旧最小任务历史窗和任务详情窗已移除；任务历史、任务详情、任务目录 / 结果目录打开、失败任务继续动作和运行中任务取消动作由任务处理窗承载。
- 历史任务能查看状态和事件，事件列表已支持按后端 cursor 加载更多；可恢复任务已有最小继续动作，可取消任务已有最小取消动作；任务目录和结果目录已有最小打开动作。任务处理窗的完整恢复矩阵仍属后续。
- 任务历史和详情使用真实 `tasks.*` / runtime 数据，不使用 mock 状态。

### G5 — 术语能力归位

目标：把“术语生成”“使用术语”“术语维护”拆清楚，避免主窗口开关语义混乱。

完成标准：

- 主窗口里的术语建议开关只表达本单是否允许系统生成术语建议，驱动 `allowSystemSuggestions`、`memory_bootstrap_enabled`、`memory_patch_enabled`；打开生成时可补 `memory_enabled=true`，关闭生成时不得写 `memory_enabled=false`，避免误伤后续“使用术语 / 预设术语表”。
- 使用术语 / 术语维护 / 预设术语表进入独立后续窗口或工具面，不塞进主窗口。
- 明确“生成的术语如何回流到翻译使用”的产品语义，再进入 UI 实现。
- 人工术语、受保护条目、运行时术语库的优先级在界面文案里不含糊。

### G6 — 诊断与通知

目标：诊断和通知服务于恢复，不变成常驻状态墙。

完成标准：

- 诊断入口当前已覆盖本地服务返回的 doctor 报告、翻译服务、语音识别、产物目录可写性检查、最小任务上下文摘要、真实 `tasks.list` 最近任务刷新和完成任务 `result.open` 结果摘要；常见配置问题可跳转对应设置窗，产物目录检查项可打开 doctor 报告里的目录路径，任务 / runtime / queue / interrupted / resume 类诊断和最近任务行可回到任务处理窗并定位任务；诊断窗最近任务行和任务处理窗都已提供用户触发的结果目录可写性检查；后续还要补完整运行队列和任务详情诊断。
- 系统通知使用真实桌面通知方案，不以网页 toast 或窗内轻提示替代；当前 Flutter 已接 Windows Toast 插件、前台抑制和点击聚焦回调，release smoke 已覆盖完成态状态转移经主窗口通知 observer 触发 native 初始化 / show 调用 / AUMID registry 注册和 Windows Notifications Settings key；Windows runner 已设置进程级 AUMID，`scripts\install_flutter_desktop_shortcut.ps1` 可创建并校验带同一 AUMID 的用户级开始菜单快捷方式，`-CheckAppIdentity` release smoke 已验证通知 AUMID 与快捷方式 AUMID 一致；用户已人工确认系统通知横幅出现；`scripts\package_flutter_release.ps1` 可生成包含该快捷方式辅助脚本和用户级安装脚本的 portable 包，并从包根验证 Local Service RPC、用户级安装快捷方式和可选窗口启动；后续必须补正式 MSIX / installer 分发路径下的通知中心行为。
- 通知只用于完成、失败、需要用户处理等关键事件，不制造噪音。
- 诊断结果能回到具体修复动作，而不是只展示检查列表。

### G7 — 工程结构卫生

目标：前端实现树清晰，当前 Flutter 主体验不被历史实现和无关前端路径干扰。

完成标准：

- 当前交付只以 `desktop_flutter/` 为主体验前端；其他前端实现不作为设计、验收或兼容基线。
- 仅历史路径使用的页面、布局、组件和视觉库依赖应物理隔离或移出活跃构建范围。
- Flutter 侧 UI、服务、状态模型职责清楚，复杂 payload 组装不散落在 widget 里。
- 相关构建和最小测试命令通过；未跑的验证必须说明原因。

---

## 3. 非目标

下一阶段不要把下面内容伪装成当前交付：

- 重新写大而全产品方向文档。
- 再做一轮 HTML mock 或静态视觉 demo。
- 把任务历史、诊断、术语、结果审看全塞进主窗口。
- 用卡片、表格、翻译服务面板墙快速堆完配置和诊断。
- 为历史前端实现保留新的 UI 兼容约束。

---

## 4. 验收纪律

- 每个 Goal 都必须在真实 Flutter 桌面窗口里验收。
- Python / Local Service 契约改动优先跑相关 pytest。
- Flutter UI 或 worker protocol 改动至少跑 `flutter build windows`，必要时补人工截图验收。
- 翻译服务、语音识别、凭据、任务运行、结果导出相关改动必须验证真实调用或说明无法验证的外部条件。
- 当前已有 Dart 到真实 Python Local Service 的 submit/cancel/events smoke，内嵌字幕 `video_asr` 的 Local Service pump → 真实 worker → `DONE` smoke，以及慢语音识别的真实 worker cancel → `CANCELLED` smoke；这些是自动化证据，不替代 G1 的真实 release 窗口人工验收。
- 当前已有 `scripts\smoke_flutter_release.ps1` 覆盖 release exe 启动 Local Service、读取配置摘要、通过主窗口 controller 正常提交 `video_asr_translate`、经临时本地 OpenAI-compatible 翻译服务翻译、等待真实 worker 到 `DONE`，校验 SRT / ASS 输出与翻译文本，并执行一次完成态 `result.open` 和 `result.reexport`，校验打开结果沿用原输出目录、reexport 事件和重新导出沿用原输出目录；传入 `-ScreenshotPath` 时会由 release 进程导出主窗口 Flutter 渲染树截图，校验非空像素和 Flutter overflow 警告条；传入 `-MainPhase empty|ready|blockedTranslation|blockedAsr|running|failed -ScreenshotPath` 时会导出 release 主窗口等待片源、就绪、翻译受阻、识别受阻、制作中和失败态状态矩阵截图；传入 `-WindowType translationSettings` / `-WindowType asrSettings` / `-WindowType diagnostics` / `-WindowType taskProcessing` 时会启动对应非主窗口，读取临时翻译服务 / 语音识别配置、doctor 诊断报告、诊断窗最近任务结果目录检查或任务处理窗任务片，并导出对应渲染树截图，同样检查非空像素和 Flutter overflow 警告条；其中 `taskProcessing` 默认校验读取并选中 DONE 任务并验证结果目录可写，`-TaskProcessingScenario edit` 会在右侧内嵌结果编辑器保存片段译文、选择 ASS / 单语重新导出，确认导出字幕包含编辑文本并校验 `result.reexport` 参数和结果目录可写性，`-TaskProcessingScenario resume` 会对失败任务触发真实 `runtime.submitResume` 并确认重新排队，`-TaskProcessingScenario cancel` 会对运行中任务触发真实 `runtime.cancel` 并确认进入 `CANCEL_REQUESTED`；旧 `resultReview` / `taskHistory` / `taskDetail` 独立窗口和 release smoke case 已移除，旧启动 ID 兼容进入任务处理窗。传入 `-CheckNotifications` 时会让任务从运行态进入完成态，通过主窗口通知 observer 触发一次真实 Windows toast 插件初始化 / show 调用，并校验 AUMID / GUID registry 注册和 Windows Notifications Settings key；传入 `-CheckAppIdentity` 时会创建 / 校验当前用户开始菜单 `TransVortex.lnk`，确认快捷方式目标指向 release exe 且 AUMID 与通知 AUMID 一致。单次 smoke 成功报告会写入 `frontend_design_mvp_complete=false`、自动化覆盖范围和仍需人工验收清单。该 smoke 证明 release 进程链路、主窗口 controller 提交路径、完成态结果打开 / 重新导出路径、诊断窗结果目录检查、任务处理窗浏览 / 编辑 / 恢复 / 取消动作、任务处理窗结果目录检查、主窗口状态矩阵、非主窗口 release 渲染树、native 通知调用路径、用户级 AUMID 快捷方式身份和完成态渲染树；真实系统通知横幅已由人工确认出现，但它仍不替代真实可见窗口完整人工端到端验收和正式 MSIX / installer 分发路径验收。
- `scripts\smoke_flutter_release_matrix.ps1` 已把 release 主流程完成态、完成态通知检查、主窗口六态、4 个非主窗口基础 case、`taskProcessing` 编辑 / 恢复 / 取消三个追加 case 和长模型名设置窗固化为单命令，并保存每个 case 的截图、报告和矩阵 summary；summary 记录渲染尺寸、非背景采样、Flutter overflow 警告条采样、任务处理窗选中状态、编辑 / 重导出 / 恢复 / 取消结果、诊断窗 / 任务处理窗结果目录可写性、通知 show 调用和 registry 结果，传入 `-CheckDesktopComposite` 时还会记录桌面合成层截图采样，专门用于回归截图里暴露过的布局 / overflow 问题和通知接线；summary 也写入 `frontend_design_mvp_complete=false`、自动化覆盖范围和仍需人工验收清单，作为防止误报完成的机器边界。
- `scripts\package_flutter_release.ps1` 是当前 portable release 包入口：它把 Flutter release bundle、`src/`、`prompts/`、`pipeline.yaml`、由 `providers.example.yaml` 复制出的 `providers.yaml`、`README_PORTABLE.txt`、用户级安装脚本和开始菜单快捷方式辅助脚本打包到同一目录，并排除 `.env`、`providers.local.yaml`、`auth.json` 等本地凭据文件；脚本默认从包根启动 `python -m transvortex.app_service --no-pump`，验证 `service.info` / `service.health` / `service.shutdown`，再清理检查产生的 `__pycache__` 和包根 `artifacts`；`-LaunchCheck` 额外从包目录启动 `TransVortex.exe`，验证 release 窗口。`scripts\install_flutter_portable_release.ps1` 和包根 `Install-TransVortex.ps1` 可把包复制到用户级安装目录、创建 AUMID 快捷方式并在安装目录复跑 Local Service RPC。它输出的 manifest 同样写入 `frontend_design_mvp_complete=false`，并明确 `installer=false`、`formal_installer=false`、`python_runtime_included=false`、`ffmpeg_included=false`；该包不是正式 MSIX/MSI/NSIS/Inno 安装器。
- `scripts\smoke_external_services.ps1` 是真实外部服务验收入口：默认用 `providers.local.yaml` 和用户级凭据跑 `probe-provider --strict` + 样本 `translate --json`，证明真实翻译服务可用；传入 `-InputPath <video>` 时额外跑媒体任务，并检查 `source/asr` 产物或 ASR 事件来补真实语音识别 / 端到端证据；`-PlanOnly` 只输出计划，不算验收。本机已用 `google_vertex_gemini · gemini-3.5-flash` 跑通真实 provider probe、样本翻译、`DemoTest/英文视频.mp4` 媒体任务和 ASR 产物证据。
- `taskProcessing -TaskProcessingScenario edit` release smoke 的临时结果包含空译文片段，会通过真实 `result.open` 产生问题计数，为最小片段筛查 / 搜索提供数据来源，并覆盖保存编辑和重新导出。
- 当前 `scripts\smoke_flutter_release_matrix.ps1 -CheckDesktopComposite` 已用 ffmpeg `ddagrab` 记录 Windows 桌面合成层窗口区域；脚本会前置 release 窗口并用浅色工作区采样校验避免误抓背后的桌面内容；完整矩阵覆盖 16 个 release case，包含主流程完成态、完成态通知、主窗口六态、4 个非主窗口基础 case、`taskProcessing` edit / resume / cancel 和长模型名设置窗；本机已通过带桌面合成层采样的 16 case release matrix，16/16 个 case 写出有效桌面合成层截图，Flutter 渲染树与桌面合成层 overflow 警告条采样均为 0，通知 show、结果编辑重导出、失败任务恢复和运行中任务取消动作仍为通过。该项补充真实窗口区域证据，但不替代 G1 的人工选择片源 / 提交 / 观察运行 / 完成或取消 / 打开结果 / 审看结果。
- `scripts\accept_flutter_release_manual.ps1 -InputPath <video>` 是 G1 真实可见 release 窗口人工验收入口：它启动真实 release exe，要求人工逐项确认可见 release 窗口、人工选择片源、人工开始、观察运行、完成、打开结果和打开结果审看，并保存窗口截图与 `manual_release_acceptance.json`。本机已通过 `-LaunchCheck`，确认脚本能拉起 release 窗口、写出初始窗口截图和报告，但报告仍写入 `manual_visible_e2e_ok=false`；该检查不替代完整人工端到端。完整人工报告通过后仍要与自动 smoke、外部服务、通知和 AUMID 证据一起判断，不单独宣布“前端设计 MVP 完成”。
- 如果某项验收被暂缓，必须写清楚暂缓原因和下次恢复入口。

证据分层：

- **自动已覆盖**：Python / Dart 单测、真实 Local Service smoke、release 主流程 smoke、release 窗口截图矩阵（16 case 桌面合成层采样）、人工验收脚本 launch-check、portable 包内 Local Service RPC 检查、用户级脚本安装检查和包目录启动检查、结果审看问题片段、通知 native 调用和注册表路径；本机真实外部服务 smoke 已输出 `external_translation_ok=true`、`external_media_task_ok=true`、`external_asr_evidence=asr_artifacts_present`。其他用户环境仍需用 `scripts\smoke_external_services.ps1` 复跑，只有实际输出对应字段为 true 才能算该环境的证据。
- **仍需人工或外部环境确认**：通过 `scripts\accept_flutter_release_manual.ps1` 完成真实可见 release 窗口端到端操作、其他用户环境的真实外部翻译 / 语音识别、正式 MSIX / installer 分发路径下的通知中心行为；portable 包不包含 Python runtime、FFmpeg 或安装器注册逻辑，不能替代正式分发验收。
- **禁止结论**：在第二层完成前，不得把“Flutter MVP 接线成立”写成“前端设计 MVP 完成”。
