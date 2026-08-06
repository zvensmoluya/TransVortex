# TransVortex 当前待办

更新时间：2026-08-06

本文件是仓库级短期待办入口，并保留 `0.1.0` 的首版发布边界。当前主开发面向 `0.2.0` 译制工作间；版本事实已经沉淀到 Release Notes，具体产品语义、架构方案和验证步骤以链接的专题文档为准。

状态含义：

- `待验收`：实现基本具备，仍缺真实环境或人工证据。
- `待实现`：方向已经明确，可以进入设计或代码实施。
- `待决策`：产品语义或技术归属尚未确定，不应直接开工。
- `外部条件`：需要证书、发布资源或目标环境。
- `低优先级验证`：保存真实观察，但不承诺近期实现。

## 当前主线：`0.2.0` 译制工作间

下一阶段把已经存在但尚未形成产品表面的术语记忆、字幕编辑和交付能力组织成完整工作流，并以极致视觉表现放大产品特色。阶段关系、稳定边界和旗舰验收场景见 [`WORKBENCH_0_2_PLAN.md`](WORKBENCH_0_2_PLAN.md)。

| 阶段 | 状态 | 完成边界 |
| --- | --- | --- |
| M0：产品表面定稿与简单架构治理 | 待实现 | 明确作品、术语、字幕工作台和交付工作室的关系；限时拆分 Flutter / Python 高频热点，保持现有协议、工件和产品行为不变 |
| M1：`0.2.0` 工作台闭环 | 待实现 | 建立作品与项目记忆、术语审看维护、成熟字幕编辑、成品样式预览和重新导出的端到端闭环 |
| M2：质量复利与极致视觉 | 待实现 | 人工修改可受控回流项目记忆，跨任务一致性可审看；关键流程具备基于真实状态的 Shader、粒子、角色、音效或 CG 演出 |
| M3：Android 伴侣端预研 | 待决策 | 先验证任务进度、通知、字幕审看、术语确认和轻量修改；完整独立 Android runtime 另行决策 |

`0.1.x` 只处理阻塞缺陷、安全问题和确有必要的发布修正。下列既有 P1 / P2 事项继续保留重要性与完成边界，但未进入上述阶段的事项不自动抢在 M0 / M1 前实施。

## `0.1.0` 首版发布事实

以下内容是 README、Release Notes 和专题文档描述首版时的统一事实来源：

- 首个公开版本是 [`v0.1.0`](https://github.com/zvensmoluya/TransVortex/releases/tag/v0.1.0)，桌面交付物是 Windows x64 用户级 NSIS 安装器。安装包包含 Flutter 应用、固定 Embedded Python 主 runtime 和固定 FFmpeg runtime；终端用户不需要另行安装 Python、FFmpeg 或 PowerShell。
- `0.1.0` 接受未签名安装包。Windows 显示“未知发布者”或 SmartScreen 提示是必须在下载页明确披露的已知限制，不是发布阻塞项。
- 冻结安装包 `TransVortex-0.1.0-windows-x64-setup.exe` 对应 commit `aace461e86f789492f7aa46709971b5e104f3cae`，SHA-256 为 `5f2d0f77cbbefb68ff1866d2362dc571745c50908de8e4fb3f93388cc307dcc8`；最终候选发布验收已于 2026-08-06 完成。
- 首轮公开的受管本机识别路径只保证 CPU；Whisper runtime 和模型按需下载，不进入基础安装包。产品还支持用户提供的 FunASR 服务、OpenAI Transcriptions，以及具有显式模型 profile 的 OpenRouter 语音识别。
- 翻译使用用户配置的远端 provider。选择远端 ASR 时音频会上传到对应服务；本机 Whisper 不上传媒体，翻译 provider 只接收任务所需的文本和上下文。
- `0.1.0` 的桌面界面和用户文档仅提供简体中文；字幕源语言和目标语言不受界面语言限制。英文用户文档后续逐步补充，界面国际化不属于首版发布范围。
- macOS / Linux 正式交付、受管 NVIDIA 安装入口、独立于 Flutter engine 的 App Host / Supervisor、应用崩溃恢复和已有 ASR 资源自动迁移不属于 `0.1.0` 发布承诺。

## P1：发布工程化

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 完整发布物的可复现 CI 构建 | 待实现 | 当前 CI 已运行 Python / Flutter 质量检查，并可在 tag 或手动触发时编译 Flutter Windows Release；后续让干净构建执行器继续生成固定 Python / FFmpeg runtime、安装包、manifest 和验收报告。`0.1.0` 使用已审查的本地发布脚本生成并验收，本项属于发布后的工程化工作 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) |

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
| Agent 准备环境与资源接入契约 | 待验收 | v2 已拆分 provider mode 与 runtime / 模型 / GPU 加速来源，scope 已进入机器契约并分别报告范围完成与完整 ASR 就绪；当前配置只作为侦查基线，模型、CPU/CUDA 与 managed/external 路径由 Agent 结合主机选择；磁盘容量跟随实际 ASR `storage_root`。契约提供托管 apply、外部资源 probe/register、activate 和 full strict verify，Flutter 已可按五种范围直接交接给用户环境中的 Codex CLI。剩余工作是随公开组件发布完成真实下载、NVIDIA 环境准备与干净机器验收 | [`../agent/README.md`](../agent/README.md)、[`../agent/workflows/ASR_ENVIRONMENT_SETUP.md`](../agent/workflows/ASR_ENVIRONMENT_SETUP.md) |
| 作品与术语记忆工作台 | 待实现 | 区分分析建议、使用项目记忆和人工维护，支持确认、锁定、拒绝、冲突、跨任务复用和受控修改回流 | [`WORKBENCH_0_2_PLAN.md`](WORKBENCH_0_2_PLAN.md)、[`FRONTEND_TASK_CONFIGURATION_SEMANTICS.md`](FRONTEND/current/FRONTEND_TASK_CONFIGURATION_SEMANTICS.md) |
| 字幕成品样式系统 | 待实现 | 区分字幕内容布局与 ASS 等格式承载的视觉样式，提供预设、预览、任务快照和重新导出 | [`WORKBENCH_0_2_PLAN.md`](WORKBENCH_0_2_PLAN.md) |
| 高级翻译与识别设置 | 进行中 | ASR 已完成 Engine + Capabilities + Policy + ResolvedPlan 的 schema v2 收口：配置拒绝未知/旧字段，凭据按 Endpoint binding 隔离，任务冻结并校验实际分窗与持久化细分重试；旧 `AsrProviderConfig` 只保留为执行链单向投影。剩余工作是逐步删除该适配层、翻译 fallback/mapping 和更多诊断修复联动 | [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md)、[`FRONTEND_DESIGN_SPEC.md`](FRONTEND/current/FRONTEND_DESIGN_SPEC.md) |
| OpenRouter 云 ASR 真实服务验收 | 待验收 | 2026-07-28 已确认 Whisper segment 与 Grok `verbose_json + word` 时间戳链路；两个 profile 现均使用 300 秒窗口和 3 秒 overlap，Whisper 复用 segment 去重，Grok 先合并词时间轴再生成字幕段，正常窗口与细分重试均有诊断。平台错误/重试、中断不丢失的任务级 usage 汇总、普通 key 用量/限额查询和 Flutter 完整/部分用量区分已具备，剩余真实长音频、多语言、切句质量与窗口阈值人工验收 | [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) |

## P2：体验深化

以下事项来自第一阶段真实 APP E2E，不阻断已经通过的主流程功能验收：

| 事项 | 状态 | 完成边界 | 关联文档 |
| --- | --- | --- | --- |
| 全应用视觉动效与 CG 场景深化 | 探索中 | 以展示性和品牌记忆点为明确目标，探索启动、导入、运行阶段、完成、失败恢复、窗口切换和退出的全窗口 Shader、粒子、角色、音效与 2D / 2.5D CG 演出；真实业务状态、可读结果、减少动态效果版本和 Windows Release 性能验收仍为底线 | [`FRONTEND_VISUAL_INTERACTION_SPEC.md`](FRONTEND/current/FRONTEND_VISUAL_INTERACTION_SPEC.md) |
| 结果工作区编辑闭环 | 待实现 | 支持媒体定位、字幕文本与时间码编辑、撤销 / 重做、查找替换和质量 / 一致性问题导航，并用真实长字幕任务验收；不以专业 NLE 的全部能力作为当前目标 | [`WORKBENCH_0_2_PLAN.md`](WORKBENCH_0_2_PLAN.md)、[`FRONTEND_PRODUCT_SURFACES.md`](FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md) |
| 英文用户文档 | 待实现 | 在中文用户文档和产品术语稳定后，为 README 与核心用户指南提供同步英文版本；在具备可持续维护方式前不复制全部内部设计文档 | [`../README.md`](../README.md)、[`USER_GUIDE.md`](USER_GUIDE.md) |

## P2：低优先级验证

以下事项统一由 [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) 维护实验条件和否定边界：

- 本机 Whisper 局部重复后的短时漏听。
- ASMR profile 与专用人声检测。
- FunASR / `SenseVoice-Small` 本地服务路线对照。

## 后续技术决策池

这些问题与当前架构有关，但不应抢在当前 P1 事项前实施：

- Worker 生命周期最终由 Flutter runner、Windows native host 还是独立 supervisor 持有。
- 是否以及何时支持多 Worker 并发；在此之前需先完成原子写和跨进程锁前提。
- 是否升级为 named pipe、local socket 或 localhost HTTP；只有窗口全关后继续运行或多客户端成为真实需求时再评估。
- macOS / Linux 的目标顺序；当前仍以 Windows 为主。
- 完整独立 Android 客户端的 runtime 与产品边界；当前只把伴侣端场景纳入后续预研。
