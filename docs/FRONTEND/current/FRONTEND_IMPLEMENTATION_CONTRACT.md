# Flutter 前端实施契约

本文档只解决一件事：把当前 Flutter spike 收束为正式 MVP 施工边界。

它不是新的设计方向，也不是新的视觉原型。硬规则以 `../rules/FRONTEND_FAILURE_RECOVERY_RULES.md` 为准，剩余交付目标以 `FRONTEND_DELIVERY_GOALS.md` 为准，窗口与交互规格以 `FRONTEND_DESIGN_SPEC.md` 为准。本文只规定实现时哪些东西保留、哪些东西重做、每个窗口先接哪些能力，以及如何验收。

---

## 1. 当前结论

当前 Flutter spike 已经验证：

- Flutter 可以启动 Python Local Service。
- Dart 侧可以通过 stdin/stdout JSON-RPC 调用 `transvortex.app_service`。
- 主窗口和子窗口可以短期复用同一个 Local Service。
- 主流程可以提交任务、刷新事件、取消任务、读取结果。
- 设置窗可以调用 provider / ASR 相关后端入口。

这些是服务接线成果，不是正式 UI 成果。

下一阶段不再做 HTML mock、不再做新的视觉 demo、不再继续在 spike UI 上堆功能。正式 Flutter MVP 直接在产品代码路径中实现，并以真实 Flutter 窗口截图和真实 Local Service 链路验收。

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

### 重做

- 主窗口的正式布局、状态呈现和交互。
- 翻译模型设置窗的正式主从结构。
- 语音识别设置窗的正式三引擎结构。
- `JobLine` 中的 mock 模型和 mock ASR 选择。
- `settings_window.dart` 中临时表单式配置台。
- UI widget 直接拼复杂 provider draft / run payload 的做法。

这些属于 spike UI，不作为正式产品界面基座。

### 先修护栏

在正式 UI 重做前，已接真实副作用的 spike 入口必须满足：

- 保存翻译默认时不得清空已有 fallback routing。
- 保存 ASR 默认方案时必须传递并校验 `pipeline.yaml` 版本。
- 任何看起来可改变本单运行方案的 UI，必须真实影响 `runtime.submitRun` payload；否则禁用或移除。
- 字幕输入在后端未确认支持前只允许 `.srt`，不得把 `.ass` / `.vtt` 伪装成已支持输入。

---

## 3. MVP 窗口范围

### 主窗口

主窗口只承载一次任务：

- 选择片源。
- 显示当前任务方案摘要。
- 开始 / 停止 / 重试 / 再做一个。
- 展示六态。
- 完成后打开结果、打开目录、重新导出。

不承载：

- provider 深配置。
- ASR 深配置。
- 完整任务历史。
- 完整诊断报告。
- 术语管理。
- 结果审看编辑器。

### 翻译模型设置窗

翻译设置窗只承载模型服务准备配置：

- provider 列表。
- provider 详情。
- API key 保存。
- 模型拉取。
- 连接测试。
- 设为默认翻译方案。

不得做成滚动 provider 卡片台，不得把主窗口任务配置混进来。

### 语音识别设置窗

ASR 设置窗只承载识别方案准备配置：

- 本机识别。
- FunASR 本地服务。
- 云端 OpenAI Whisper。
- 每个引擎的最小必要字段。
- 保存默认识别方案。

高级 chunking、静音切分、并发、预处理、字幕轨强制选择等延后。

---

## 4. 主窗口状态契约

| 状态 | UI 来源 | 主要呈现 | 主动作 | 后端动作 |
| --- | --- | --- | --- | --- |
| 空 | 本地 draft | 投递口，无 job 描述 | 放入片源，禁用 | 无 |
| 就绪 | 本地 draft + `desktop.snapshot.config` | 片源封套 + 当前方案摘要 | 开始译制 | `runtime.submitRun` |
| 受阻 | `desktop.snapshot.configReadiness` | 对应词显示需配置 | 去配置翻译 / 识别 | 打开对应设置窗 |
| 制作中 | `runtime.snapshot` + `tasks.events` | 当前阶段文案 + 真实进度 | 停下 | `runtime.cancel` |
| 完成 | task terminal status + result paths | 交付态 + 结果动作 | 再做一个 | `result.open` / `result.reexport` |
| 失败 | task `error_info` + events | 一句话原因 + 修复动作 | 重试 / 去修复 | 视错误映射决定 |

进度只来自真实事件或任务摘要。无真实进度时不得伪造百分比。

---

## 5. 用户动作到 RPC

| 用户动作 | RPC | 状态刷新 |
| --- | --- | --- |
| App 启动 | `service.info` / `service.health` / `desktop.snapshot` | 初始化服务状态、配置摘要和任务摘要 |
| 选择片源 | 无 | 更新本地 draft |
| 开始译制 | `runtime.submitRun` | 保存 `task_id`，开始轮询 |
| 停下 | `runtime.cancel` | 刷新 runtime 和任务事件 |
| 运行中刷新 | `runtime.snapshot` / `tasks.events` | 更新阶段文案、进度、失败信息 |
| 打开字幕 | `result.open` | 读取 result paths 后交给系统打开 |
| 打开目录 | `result.open` | 读取 result paths 后交给系统打开 |
| 重新导出 | `result.reexport` | 刷新 result paths 和任务事件 |
| 保存 provider | `provider.save` | 刷新 `config.get` 或 `desktop.snapshot` |
| 拉模型 | `provider.models` | 更新当前详情 draft |
| 测试 provider | `provider.test` | 显示测试结果 |
| 设默认翻译 | `provider.routing.save` | 刷新配置并通知主窗口 |
| 保存 ASR 默认 | `asr.provider.save` | 刷新配置并通知主窗口 |

UI 不直接调用 `runtime.acquireNext` 或 `runtime.releaseActive`。这两个方法属于 pump / worker 控制面。

---

## 6. 状态与数据所有权

正式 UI 必须区分三类状态：

- 本地 draft：用户还没提交任务的片源、输出格式、双语、术语生成等。
- 服务 snapshot：配置就绪、默认 provider、默认 ASR、任务列表、runtime 状态。
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

验收以真实 Flutter 窗口截图为准，不以 HTML 页面或静态 mock 为准。

---

## 8. 错误恢复

失败态不得直接显示原始异常字符串作为主要信息。

正式 UI 至少要识别这些恢复方向：

| 错误来源 | 用户可理解问题 | 恢复动作 |
| --- | --- | --- |
| 缺 provider key | 翻译服务还没配置 key | 打开翻译设置窗 |
| provider test fail | 翻译服务连不上 | 打开翻译设置窗并定位当前 provider |
| 缺 ASR key | 云端识别还没配置 key | 打开识别设置窗 |
| 本机 ASR 依赖缺失 | 本机识别环境不完整 | 打开诊断 / 切换识别方案 |
| 输入文件不存在 | 片源找不到 | 重新选择片源 |
| 输出目录不可写 | 无法写入字幕文件 | 选择可写目录，后续设计 |
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
- 最长文件名 / 最长 provider id / 最长错误文案压力场景。

每个里程碑至少验证：

- `flutter analyze`
- `flutter test`
- Windows release 运行或等效真实桌面窗口验证
- 涉及 Python 后端时，运行相关 `pytest`

如果某项无法验证，必须在回复或提交说明里明确写出原因和风险。

---

## 10. 禁止继续发生的事

- 不再用 HTML mock 作为下一阶段主要产物。
- 不再新增一个临时前端 spike。
- 不在未定稿 UI 上继续增加真实落盘能力。
- 不把 CLI 命令一比一搬进桌面 UI。
- 不把跨窗口 bridge 当长期业务后端总线。
- 不在 widget 内直接堆所有 RPC、draft 拼装和错误恢复逻辑。
- 不为了“先能点”引入会误导用户的假选择器。

---

## 11. 下一步顺序

1. 补齐 spike 真实副作用护栏。
2. 抽出或新增主窗口 controller / view model。
3. 重做主窗口正式六态。
4. 接主窗口真实 `runtime.submitRun`、事件轮询、取消、完成态结果动作。
5. 重做翻译模型设置窗。
6. 重做语音识别设置窗。
7. 再进入任务历史、诊断、术语管理、结果审看等后续窗口。
