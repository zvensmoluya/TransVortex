# TransVortex 当前待办

更新时间：2026-07-28

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
| ASR 组件公开下载与可见 APP 验收 | 待验收 | 单一设置任务、取消/恢复、托盘反馈、首次下载前独立资源目录、目标盘空间判断和 760×560 界面已实现并通过自动验证；仍需用已发布 runtime 完成可见 Flutter 真实点击下载、取消/续传、关窗重开、`small + CPU` 真实媒体任务和干净系统首启；NVIDIA 加速另行开放 | [`ASR_RELEASE_RECAP_2026-07-21.md`](ASR_RELEASE_RECAP_2026-07-21.md) |
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
| 已有 ASR 资源跨盘迁移 | 待实现 | 在不重新下载的前提下复制运行组件、模型和安全断点，提供真实进度、逐文件校验、取消、原位置保留与失败回滚；完成前只允许首次下载前选择资源位置 | [`LOCAL_ASR_COMPONENTS.md`](LOCAL_ASR_COMPONENTS.md) |
| Agent 准备环境与资源接入契约 | 待验收 | v2 已拆分 provider mode 与 runtime / 模型 / GPU 加速来源，提供托管 apply、Agent 本机侦查与准备、外部资源 probe/register、activate 和 strict verify；Flutter 交接按侦查、模型、GPU 加速、已有资源接入和完整准备区分范围，并已支持复制或通过隔离工作区直接发送给用户环境中的 Codex CLI。剩余工作是随公开组件发布完成真实下载、NVIDIA 环境准备与干净机器验收 | [`../agent/README.md`](../agent/README.md)、[`../agent/workflows/ASR_ENVIRONMENT_SETUP.md`](../agent/workflows/ASR_ENVIRONMENT_SETUP.md) |
| 术语能力归位 | 待决策 | 区分生成术语建议、使用术语和维护术语，并明确回流与优先级语义 | [`FRONTEND_TASK_CONFIGURATION_SEMANTICS.md`](FRONTEND/current/FRONTEND_TASK_CONFIGURATION_SEMANTICS.md) |
| 高级翻译与识别设置 | 进行中 | ASR 已完成 Engine + Capabilities + Policy + ResolvedPlan 的 schema v2 收口：配置拒绝未知/旧字段，凭据按 Endpoint binding 隔离，任务冻结并校验实际分窗与持久化细分重试；旧 `AsrProviderConfig` 只保留为执行链单向投影。剩余工作是逐步删除该适配层、翻译 fallback/mapping 和更多诊断修复联动 | [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md)、[`FRONTEND_DESIGN_SPEC.md`](FRONTEND/current/FRONTEND_DESIGN_SPEC.md) |
| OpenRouter 云 ASR 真实服务验收 | 待验收 | 2026-07-28 已确认 Whisper segment 与 Grok `verbose_json + word` 时间戳链路；两个 profile 现均使用 300 秒窗口和 3 秒 overlap，Whisper 复用 segment 去重，Grok 先合并词时间轴再生成字幕段，正常窗口与细分重试均有诊断。平台错误/重试、中断不丢失的任务级 usage 汇总、普通 key 用量/限额查询和 Flutter 完整/部分用量区分已具备，剩余真实长音频、多语言、切句质量与窗口阈值人工验收 | [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) |

## P2：体验深化

以下事项来自第一阶段真实 APP E2E，不阻断已经通过的主流程功能验收：

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 全应用视觉动效与 CG 场景深化 | 探索中 | 以展示性和品牌记忆点为明确目标，探索启动、导入、运行阶段、完成、失败恢复、窗口切换和退出的全窗口 Shader、粒子、角色、音效与 2D / 2.5D CG 演出；真实业务状态、可读结果、减少动态效果版本和 Windows Release 性能验收仍为底线 | [`FRONTEND_VISUAL_INTERACTION_SPEC.md`](FRONTEND/current/FRONTEND_VISUAL_INTERACTION_SPEC.md) |
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
