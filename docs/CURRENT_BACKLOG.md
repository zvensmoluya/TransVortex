# TransVortex 当前待办

更新时间：2026-07-18

本文件是仓库级待办入口，只维护未闭环事项的状态和优先级。具体产品语义、架构方案和验证步骤以链接的专题文档为准。

状态含义：

- `待验收`：实现基本具备，仍缺真实环境或人工证据。
- `待实现`：方向已经明确，可以进入设计或代码实施。
- `待决策`：产品语义或技术归属尚未确定，不应直接开工。
- `外部条件`：需要证书、发布资源或目标环境。
- `低优先级验证`：保存真实观察，但不承诺近期实现。

## P0：发布闭环

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| ASR 组件内部发布与下载闭环 | 外部条件 | 发布固定版本资产并写入大小、SHA-256 和 `published` 清单，在全新 APP 数据目录完成下载、校验、安装和真实任务 | [`LOCAL_ASR_COMPONENTS.md`](LOCAL_ASR_COMPONENTS.md) |
| 干净 Windows 首启与媒体任务 | 待验收 | 在未配置开发环境的干净系统完成安装、首启、配置和真实任务 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 已安装路径通知行为 | 待验收 | 通知中心归属正确，点击通知能够聚焦应用 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |
| Authenticode 签名 | 外部条件 | 正式安装包和主可执行文件完成签名、时间戳和 Windows 验证 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |
| FFmpeg 对应源码托管 | 外部条件 | 公开分发提供与内置 LGPL shared runtime 对应的完整源码地址 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |
| 可复现的 CI 构建 | 待实现 | 在干净构建执行器生成 runtime、安装包、manifest 和验收结果 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |

当前已经成立的边界：NSIS 内部安装包已通过本机全新安装、升级、运行中保护、固定 runtime、AUMID 快捷方式、卸载和用户数据保留验收。2026-07-17 开发态可见 Flutter Release 完成第一阶段人工 E2E，真实媒体经 external `local_worker` 完成识别、翻译、结果审看和重新导出，详见 [`2026-07-17-flutter-app-e2e-first-stage.md`](archive/e2e-reports/2026-07-17-flutter-app-e2e-first-stage.md)。2026-07-18 又完成受管 Whisper runtime、NVIDIA 组件和 `large-v3` 模型的隔离校验安装，并从正式安装目录启动可见 APP，在不依赖工作区 Python 的情况下完成 `managed + stdio_jsonl + cuda + int8_float16` 真实媒体任务、SRT / ASS 审看、重新导出和卸载清理，详见 [`2026-07-18-managed-asr-installed-app-e2e.md`](archive/e2e-reports/2026-07-18-managed-asr-installed-app-e2e.md)。不要把这些已完成基础重新列为待办；它们仍不等于公开组件下载、干净系统发布就绪或通知验收。

## P1：桌面生命周期与数据安全

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 窗口无关的 App Host / Supervisor | 待决策 | 当前托盘由主 Flutter engine 持有；继续明确应用崩溃重启、唯一 Local Service 宿主和 Worker 进程树归属 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 完整 AppPaths | 待实现 | 将 `logs`、`temp` 纳入用户目录规划，并让 Cache 清理失败可观察 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 配置和资源版本迁移 | 待实现 | 首次初始化和升级迁移具备 schema、备份、幂等执行与失败回滚 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 前后端兼容握手 | 待实现 | Flutter 启动时校验 protocol、capability 和可接受的 App/backend 版本组合 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 启动与崩溃日志 | 待实现 | Local Service 启动前错误和应用崩溃可被持久记录并用于恢复提示 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |
| 凭据长期安全边界 | 待决策 | 明确 `auth.json` 的 Windows ACL 加固或 Credential Manager 演进策略 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |

当前已经成立的边界：正常关闭主窗口会收起产品窗口并驻留托盘，Local Service 与当前任务继续运行；托盘可恢复窗口，明确退出会在活动任务存在时先要求确认；任务处理窗有未保存字幕时会阻止主窗口收起或应用退出，并前置编辑窗口等待用户决定。该能力不覆盖应用自身崩溃后的恢复。

## P1：产品与界面闭环

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 失败恢复矩阵 | 待验收 | 配置、凭据、识别、目录和任务失败都有真实可执行的恢复动作 | [`FRONTEND_PRODUCT_SURFACES.md`](FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md) |
| Flutter Agent 环境接力入口 | 待实现 | 在 Flutter 识别设置中提供复制通用 Prompt / 导出 Agent-native Skill 的入口，并让原生向导与 `transvortex.agent_setup` verify 结果保持一致 | [`../AGENT_USAGE.md`](../AGENT_USAGE.md)、[`../AGENT_BOOTSTRAP.md`](../AGENT_BOOTSTRAP.md) |
| 术语能力归位 | 待决策 | 区分生成术语建议、使用术语和维护术语，并明确回流与优先级语义 | [`FRONTEND_TASK_CONFIGURATION_SEMANTICS.md`](FRONTEND/current/FRONTEND_TASK_CONFIGURATION_SEMANTICS.md) |
| 高级翻译与识别设置 | 待实现 | 补齐 fallback routing、mapping、识别高级参数和诊断修复联动 | [`FRONTEND_DESIGN_SPEC.md`](FRONTEND/current/FRONTEND_DESIGN_SPEC.md) |
| 安装器视觉定制 | 待决策 | 最终图标确定后，再决定 NSIS 欢迎图、顶部图、文案和品牌化程度；不改变现有安全安装逻辑 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |
| 卸载时清理用户数据 | 待决策 | 决定是否提供明确的可选清理入口；默认仍应保留配置、任务、模型和凭据 | [`APP_RUNTIME.md`](APP_RUNTIME.md) |

## P2：体验深化

以下事项来自第一阶段真实 APP E2E，不阻断已经通过的主流程功能验收：

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 任务运行态反馈与视觉动效深化 | 待决策 | 在不制造伪进度或视觉噪音的前提下，让长时间识别、翻译和恢复阶段具有更清楚的状态变化、交互反馈和更鲜明的美术风格 | [`FRONTEND_VISUAL_INTERACTION_SPEC.md`](FRONTEND/current/FRONTEND_VISUAL_INTERACTION_SPEC.md) |
| 结果工作区字幕轴易用性 | 待决策 | 先明确首版字幕轴需要承担的定位、选择、浏览和校时范围，再用真实长字幕编辑任务验收；不以专业 NLE 的极致能力作为首阶段目标 | [`FRONTEND_PRODUCT_SURFACES.md`](FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md) |

## P2：低优先级验证

以下事项统一由 [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) 维护实验条件和否定边界：

- 本机 Whisper 局部重复后的短时漏听。
- ASMR profile 与专用人声检测。
- FunASR / `SenseVoice-Small` 本地服务路线对照。

## 后续技术决策池

这些问题与当前架构有关，但不应抢在 P0/P1 前实施：

- Worker 生命周期最终由 Flutter runner、Windows native host 还是独立 supervisor 持有。
- 是否以及何时支持多 Worker 并发；在此之前需先完成原子写和跨进程锁前提。
- 是否升级为 named pipe、local socket 或 localhost HTTP；只有窗口全关后继续运行或多客户端成为真实需求时再评估。
- macOS / Linux 的目标顺序；当前仍以 Windows 为主。
