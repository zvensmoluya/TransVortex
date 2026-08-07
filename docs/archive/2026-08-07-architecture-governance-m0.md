# M0 架构治理执行契约

- 状态：完成（已归档）
- 建立日期：2026-08-07
- 完成日期：2026-08-07
- 代码基线：`9a6c85d`（`Define the 0.2.0 workbench direction`）

本文是 `0.2.0` M0 的已完成执行记录。它不定义新的公开产品能力，也不替代 [`ARCHITECTURE.md`](../ARCHITECTURE.md)、[`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](../DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) 或 [`FRONTEND_PRODUCT_SURFACES.md`](../FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md)。

稳定的所有权和依赖结论已回写对应专题文档；本记录只保留实施过程和验证上下文，不长期承担现状说明。

## 1. 目标与时间盒

M0 只解决已经阻碍 `0.2.0` 工作台开发的高频结构问题：

- 固定作品、术语记忆、字幕编辑和交付之间的产品所有权。
- 为 Flutter 高频窗口、Local Service typed client 和测试建立清楚的修改接缝。
- 保留 Python pipeline 公开入口，把 ASR 与后续 pipeline 阶段从单体 orchestrator 中逐步提取。
- 让每批调整都能独立验证、独立回退，不等待一次全仓重构完成。

M0 以一个短迭代为上限。完成标准是高频职责有明确落点并且主线测试保持通过，不以统一文件行数、消除全部依赖环或拆完所有大文件为目标。

## 2. 产品所有权冻结

以下结论用于指导代码拆分，但不在 M0 新建完整业务 schema：

| 产品概念 | 当前事实 | M0 所有权结论 | M1 扩展边界 |
| --- | --- | --- | --- |
| 作品 / 系列 | 当前稳定执行单位仍是 task，尚无公开的作品实体 | 作品是 task 之上的组织与记忆归属，不替换 task、task id 或现有工件目录 | 新增作品聚合、系列关系和至少两个关联任务的工作流 |
| 术语记忆 | Python `memory/` 与任务工件已经承载建议、选择、合并和一致性能力，普通 UI 尚未公开维护生命周期 | Python 保持记忆业务真实来源；Flutter 只通过 typed RPC 展示和提交用户动作；M0 不把内部 `bootstrap`、`inject`、`patch` 等字段公开成产品概念 | 建立项目作用域、建议证据、确认、锁定、拒绝、冲突和受控回流 |
| 字幕工作台 | 结构化 segments 和任务结果工件是权威状态，Flutter 编辑草稿在保存前只是窗口内状态 | `result.*` 契约继续负责打开、保存和重新导出；M0 不改变 segment、质量报告或 dirty guard 语义 | 补齐媒体定位、撤销 / 重做、查找替换和问题导航 |
| 交付工作室 | Python `formats/presentation.py` 与 exporter 负责格式和交付检查，任务保存最近一次交付选择 | 内容布局与视觉样式继续由 Python 交付边界负责；Flutter 负责选择、预览和反馈；M0 不新增样式系统 | 建立样式预设、任务快照、预览和可恢复的重新导出 |

任何命名或 UI 文案如果让用户误以为“作品”等于 task、“自动生成术语建议”等于完整项目记忆，必须在进入 M1 前先修正文档和产品语义，不能用代码字段掩盖差异。

## 3. 不可变化的行为护栏

纯结构调整期间必须保持：

- Flutter 仍是唯一桌面产品前端，不引入第二套桌面前端或新的全局状态管理框架。
- Flutter / Python 的职责边界不变；Flutter 不直接启动 Worker，也不成为任务、checkpoint 或结果的权威来源。
- newline JSON-RPC 的 method、protocol version、请求字段、响应字段、错误结构和 secret redaction 语义不变。
- task、checkpoint、events、Cache、结果工件和输出文件的路径与恢复语义不变。
- 九阶段 pipeline、进度含义、取消、恢复、质量检查和重新导出的产品行为不变。
- CLI / Agent 的命令、机器可读 stdout、稳定安装入口和能力契约不变。
- 配置优先级与统一 credential resolver 不变；Provider YAML 不写入 secret。
- `--no-pump` 只保持打包、安装和健康检查中的隔离探针语义。
- 不借结构调整实现作品库、术语工作台、样式系统、App Host / Supervisor 或多 Worker。

如果一次拆分必须改变上述任一行为，应停止该批次，把行为变化单独写入 M1 设计或当前 backlog，再决定是否实施。

## 4. 当前热点基线

以下数据来自基线 commit 的文件规模和最近 100 次提交的修改频次。行数与频次只用于定位风险，不是拆分后的 KPI。

| 文件 | 基线行数 | 最近 100 次提交修改次数 | 当前混合职责 |
| --- | ---: | ---: | --- |
| `desktop_flutter/test/widget_test.dart` | 8358 | 57 | 多个窗口、产品表面、Fake 和 fixture |
| `desktop_flutter/lib/widgets/settings_window.dart` | 5653 | 28 | ASR 草稿与操作、诊断、窗口状态和展示组件 |
| `src/transvortex/core/orchestrator.py` | 4391 | 19 | ASR 规划与重试、checkpoint、pipeline 阶段和完成/失败收口 |
| `desktop_flutter/lib/main.dart` | 3569 | 24 | 启动、多窗口、托盘、release smoke 和主工作面 |
| `desktop_flutter/lib/services/app_service_client.dart` | 3196 | 30 | transport、进程监督、typed client 和所有 DTO |
| `desktop_flutter/lib/widgets/task_processing_window.dart` | 3100 | 13 | 任务轮询、筛选、动作、诊断和结果审看编排 |
| `desktop_flutter/lib/widgets/result_review_workspace.dart` | 2846 | 13 | 编辑草稿、校时、质量导航、保存和交付选择 |
| `desktop_flutter/test/app_service_client_test.dart` | 2620 | 27 | transport、supervisor、RPC mapping 和 DTO parsing |

`src/transvortex/protocol/agent_setup.py` 和 `src/transvortex/cli/entry.py` 规模也较大，但当前领域相对隔离、修改频次较低，不自动进入 M0。只有它们阻塞本清单中的稳定接缝时才单独决策。

当前 Python 实际包图还包含 `memory/`、`prompts/`、`experiments/`、`asr_domain.py`、`openrouter.py`、`openrouter_asr.py` 和 `http.py`；现行架构文档没有完整列出这些所有权。`app`、`core`、`artifacts`、`memory`、`providers` 之间也存在既有双向依赖。M0 先补齐真实地图并禁止新拆出的模块扩大依赖环，不进行全仓 package 迁移。

## 5. 增量依赖规则

新拆出的代码遵守以下规则；既有代码只在当前批次触及时收口：

### Flutter

- `widgets/` 可以依赖 controller、model 和 service；controller、model、service 不反向依赖具体 widget。
- JSON-RPC transport 不解析业务 DTO；typed client 不持有进程生命周期；Supervisor 不承载 provider、ASR、task 或 result 业务映射。
- DTO 按稳定 RPC 领域组织，避免所有窗口都依赖一个包含全部模型的实现文件。
- StatefulWidget 只保留窗口生命周期和短期交互状态；可测试的加载、轮询、保存与动作编排进入 controller 或 service。
- release smoke 驱动与正常产品布局分开，但 smoke 仍调用真实产品入口，不复制一套业务实现。

### Python

- `cli`、`app_service` 等入口可以调用 owning package；新拆出的 core stage 不依赖 CLI、Flutter 或 RPC handler。
- `core/orchestrator.py` 保留公开 pipeline 入口和阶段顺序，不继续承载可独立测试的 ASR 规划、ASR 执行或交付实现。
- checkpoint、event 和 artifact 的写入仍通过现有 `TaskStore` 与工件边界完成，不新增旁路状态。
- 新模块使用 owning package 的直接 import，不新增根级兼容 shim。
- 不为了消除表面 import 环而复制 DTO、配置解析、credential 解析或错误分类逻辑。

可以增加轻量架构测试保护上述新边界，但不得先用一组会让大量未触及旧代码失败的全仓规则阻塞 M0。

## 6. 执行批次

状态使用：`未开始`、`进行中`、`完成`、`延后`。同一时间只推进一个生产代码批次。

| 批次 | 状态 | 完成边界 |
| --- | --- | --- |
| G0：契约与验证基线 | 完成 | 本文建立；首发 release 已完成充分验证，经项目负责人决定不重复运行未改代码的基线测试 |
| G1：Flutter 测试接缝 | 完成 | 101 个测试按产品表面拆分，共享支持代码独立；默认仍由单一 widget suite 聚合以保持原有调度特征 |
| G2：App Service typed client | 完成 | transport、Supervisor、typed client 与分域 DTO 已分离；稳定 import facade 和 RPC 行为保持不变 |
| G3：主窗口与设置窗口 | 完成 | 主窗口生命周期 / smoke / 展示，以及 ASR operation controller / 设置表面 / 诊断表面已分离 |
| G4：任务处理与结果审看 | 完成 | 分离 task/event 加载与动作、关闭保护、编辑草稿、交付操作和纯展示，为 M1 工作台留下稳定接缝 |
| G5：Python pipeline orchestrator | 完成 | ASR 规划 / 执行、source / translation / delivery helper 与六段 stage controller 已提取，公开入口与工件语义保留 |
| G6：收口与回写 | 完成 | 按项目负责人确认的轻量口径汇总静态检查与定向回归，回写专题文档并归档本文；不重复全仓测试或 Release 构建 |

### G0：契约与验证基线

- [x] 盘点代码规模和近期修改热点。
- [x] 盘点实际 Python package 与主要双向依赖。
- [x] 固定产品所有权、行为护栏、非目标和批次顺序。
- [x] 项目负责人确认不重复运行未修改代码的 Python / Flutter 基线；`0.1.0` release 前后的既有验证作为本轮起点。

基线验证结果：2026-08-07 决定省略重复基线。后续每个结构批次只在改动完成后运行与该批次相称的回归，不采用额外的测试先行门槛。

### G1：Flutter 测试接缝

计划拆分：

- 主窗口与桌面生命周期测试。
- 应用设置测试。
- 翻译设置测试。
- ASR 设置与内部诊断测试。
- 任务处理测试。
- 结果审看测试。
- `test/support/` 下的共享 fake transport、service handle、path opener、directory probe 和 fixture builders。

验收：

- [x] 测试断言、输入 payload 和覆盖场景不因移动而减少。
- [x] 产品表面测试模块可以单独调用；默认由 `widget_test.dart` 聚合，保持原有文件级并发特征。
- [x] `flutter analyze --fatal-infos` 通过。
- [x] `flutter test` 通过。
- [x] 生产代码未发生行为改动。

实际结果（2026-08-07）：

- `widget_test.dart` 从 8358 行收窄为窗口壳入口与产品表面聚合器。
- 主窗口、应用设置、翻译设置、ASR 设置、诊断、结果审看和任务处理分别进入 `test/surfaces/`。
- 共享 transport、service handle、payload builder、path opener 和 directory probe 进入 `test/support/widget_test_support.dart`。
- 首次把各表面都作为独立 `*_test.dart` 运行时，新增的文件级并发使既有真实 Worker 测试触发 10 秒 RPC 超时；该测试单独运行通过。最终改为可单独调用但默认不自动发现的 `*_tests.dart` 模块，由原 `widget_test.dart` 聚合，恢复原调度后全量 271 项测试通过。

### G2：App Service typed client

候选落点可根据实际 import 调整，但职责必须分离为：

- transport、异常和 pending request。
- Local Service 进程启动、session 与 shutdown。
- typed RPC client facade。
- service / config、provider / ASR、task / runtime、result 等领域 DTO。

验收：

- [x] 现有 RPC method、参数和 timeout 不变。
- [x] DTO 对缺失字段、未知字段和 fallback 的现有行为不变。
- [x] 携带凭据的请求仍不进入诊断输出。
- [x] transport、Supervisor、typed method mapping 和 DTO parsing 可以分别测试。
- [x] `app_service_client.dart` 保留为受支持的稳定 import facade；至少在 `0.2.0` 周期内不要求调用方迁移，也不再承载实现。
- [x] `flutter analyze --fatal-infos` 与 App Service client 全部 46 项测试通过。

实际结果（2026-08-07）：

- 原 3196 行 `app_service_client.dart` 收窄为 6 行稳定导出面。
- JSON-RPC transport、Local Service Supervisor/session 和 typed client 分别进入 `services/app_service/transport.dart`、`supervisor.dart` 与 `client.dart`。
- DTO 使用一个共享解析 library，并按 service、config、ASR、task 和 result 分成五个 part 文件；没有复制字段 fallback 或数值清洗规则。
- 原 2620 行测试入口收窄为聚合器，46 个场景按 transport、model、client、Supervisor 和 bridge 分组，公共真实进程 fixture 独立。
- 全量 Flutter 并发回归曾出现一次既有取消时序波动：task 已为 `CANCELLED`，紧随其后的 event page 尚未出现 `cancelled`。失败单项和 App Service 整组复核均通过；本批次未修改业务代码或放宽断言，后续在真实行为改动或发布验收时继续观察。

### G3：主窗口与设置窗口

主窗口优先拆分：

- 应用启动与 window routing。
- 托盘、多工具窗和退出保护等桌面生命周期协调。
- release smoke 驱动。
- 主工作面的纯展示组件；已有 `MainWindowController` 继续拥有任务草稿和主流程编排。

设置窗口优先拆分：

- ASR 设置 controller / view state。
- ASR 空闲摘要、草稿编辑、资源准备和外部模型流程。
- 内部诊断面板。
- 窗口 shell 与 translation settings 接入。

验收：

- [x] UI 文案、窗口尺寸、菜单入口和动作可用性不变。
- [x] 关闭到托盘、未保存字幕保护和明确退出行为不变。
- [x] ASR 操作关闭窗口后继续、托盘接管和重开接回行为不变。
- [x] release smoke 继续走真实 controller 和 Local Service 接口。
- [x] `flutter analyze --fatal-infos` 与 G3 相关的 48 项窗口测试通过；按约定不重复全量回归。

实际结果（2026-08-07）：

- `main.dart` 从 3569 行收窄为 1586 行启动、State 生命周期入口和主工作面交互；托盘 / 工具窗 / 退出保护、release smoke、纯展示组件分别进入 `main/` 下三个同库模块。拆分只移动原方法，smoke 仍调用原 `MainWindowController`、typed client 和窗口入口。
- `settings_window.dart` 从 5653 行收窄为约 1000 行窗口 shell、共享配置加载与 translation settings 接入；ASR 表面、诊断表面及两组私有展示组件分别进入 `widgets/settings_window/`。
- 新增无 Widget / window plugin 依赖的 `AsrOperationController`，集中持有 resource operation、500ms 轮询、终态回调和 2.2 秒完成态收起。Local Service 仍是 operation 权威来源，设置窗口重开后仍从 snapshot 接回活动 operation。
- 为保持私有组件和 helper 的现有调用图，窗口内部模块使用 Dart `part`；这只作为紧耦合 UI composition 的边界，不作为跨层公开 API。
- 定向运行主窗口 22 项、ASR 设置 22 项和诊断 4 项测试，全部通过；没有重复运行与本批次无关的全量测试。

### G4：任务处理与结果审看

优先拆分：

- task list/events 加载、cursor 和筛选状态；盘点确认现有窗口没有周期轮询，M0 不凭空新增轮询行为。
- resume、cancel、目录恢复和 re-export 等任务动作。
- segment draft、dirty state、时间码校验和问题导航。
- 任务详情、诊断、编辑器和交付区的纯展示组件。

验收：

- [x] task 状态决定动作的现有矩阵不变。
- [x] 保存 segments 与重新导出仍是两个独立动作。
- [x] 合法重叠允许保存、非法时间阻止保存的规则不变。
- [x] 窗口 dirty guard 与跨窗口关闭协调不变。
- [x] `flutter analyze --fatal-infos` 与 G4 相关的 8 项窗口测试通过；按约定不重复全量回归。

实际结果（2026-08-07）：

- `task_processing_window.dart` 从 3100 行收窄为 305 行窗口 shell 和 build wiring；task/event 数据加载与 cursor、结果编辑器关闭保护、resume / retranslate / cancel / output recovery 动作、smoke 以及展示组件分别进入 `widgets/task_processing_window/`。
- 盘点确认该窗口当前由显式刷新和动作后重载驱动，并不存在周期性任务轮询；因此本批次修正文档用词，没有引入新的后台请求时序。
- `result_review_workspace.dart` 从 2846 行收窄为约 220 行窗口生命周期与 build wiring；结果加载 / 保存 / re-export、片段导航与时间码编辑、草稿类型和展示组件分别进入 `widgets/result_review_workspace/`。
- `_ResultDraftController` 集中持有 segment 文本 / 时间码 controller、权威 snapshot 同步、modified 判断、放弃全部修改和还原单段；焦点与滚动仍属于窗口，`result.segments.save` 与 `result.reexport` 仍是两条独立 RPC 路径。
- 定向运行任务处理 4 项和结果审看 4 项测试，覆盖 dirty close guard、保存 / 导出分离、非法时间阻断、合法时间保存和动作失败恢复，全部通过。

### G5：Python pipeline orchestrator

按依赖由内向外逐步提取：

1. ASR plan、manifest 校验和 retry plan。
2. ASR serial / concurrent execution、split retry 和 usage 收口。
3. ingest、memory、translation、quality 与 delivery stage controller。
4. `_execute_task` 只保留阶段编排、统一取消与异常收口；如果重复参数已经妨碍拆分，再引入小型 execution context，不预先设计通用框架。

验收：

- [x] `run_pipeline`、`resume_pipeline`、`queue_resume_task`、`execute_pipeline_task` 和 `task_status_json` 的行为不变。
- [x] stage 名称、checkpoint 字段、event 顺序、artifact 路径和进度含义不变。
- [x] resume、split retry、并发窗口顺序、usage 汇总和成功后 Cache 清理保持现有测试覆盖。
- [x] `test_orchestrator_worker.py` 的场景与 monkeypatch seam 保持可按节点 / `-k` 独立运行；本批次没有为了形式拆文件而复制大型 fixture。
- [x] 相关 pytest 定向通过；按项目负责人确认的口径不补跑全量 `pytest -q`。

实际结果（2026-08-07）：

- `orchestrator.py` 从 4391 行收窄为 1199 行公开 task / run / resume 入口、兼容测试 seam、状态映射和统一异常 / Cache 收口；`_execute_task` 本体从约 925 行收窄为 109 行。
- `asr_planning.py` 独立持有 policy 冻结、portable manifest、plan id、artifact 引用校验、能力上限和 persisted plan 恢复；`asr_execution.py` 持有 preprocess、usage、retry decision / child plan、serial / concurrent、adaptive concurrency 和 split retry。
- engine 构造、音频预处理和切分通过 `AsrExecutionDependencies` 从入口注入；新模块不反向 import `orchestrator`，原测试与实验 monkeypatch seam 仍由薄 wrapper 提供。
- source segment 工件 / 清洗、translation chunk / validation 账本和 delivery 路径分别进入 `source_pipeline.py`、`translation_pipeline.py` 与 `delivery_planning.py`；取消与文件有效性 helper 进入 `pipeline_runtime.py`。
- `pipeline_stages.py` 以显式 `PipelineExecutionContext` 和 `PipelineStageDependencies` 承载 PRECHECK、INGEST / ASR、MEMORY、SEGMENT / TRANSLATE、ALIGN / QUALITY 与 EXPORT；`_execute_task` 只固定阶段顺序，并统一处理取消、失败和成功后的 Cache cleanup。
- 结构检查确认原 orchestrator 的全部顶层声明仍在 facade 或 owning module 中可找到，所有新 core module 均不 import orchestrator。
- 定向验证通过：ASR planning 12 项、ASR execution 相关 21 项、代表性 pipeline / resume / segments / embedded subtitle / split retry 6 项、SRT / reflow / memory 3 项、chunk / route helper 21 项。

### G6：收口与回写

- [x] Python compile / import、Dart format、Flutter analyze 和 diff hygiene 通过。
- [x] 汇总 G1-G5 已完成的定向测试；不重复运行全量 `pytest -q`、`flutter test` 或 Windows Release build。
- [x] 记录未做真实 Windows Release 窗口回归的原因与剩余风险。
- [x] 将最终 package 所有权回写 `ARCHITECTURE.md`。
- [x] 将桌面生命周期与 client 结论回写 `DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`。
- [x] 将稳定产品表面结论回写前端专题文档。
- [x] 从 `CURRENT_BACKLOG.md` 移除完成项并归档本文；M1 保持待实现，未擅自推进产品阶段。

实际结果（2026-08-07）：

- `python -m compileall -q src/transvortex` 与 orchestrator、新 ASR / stage / source / translation / delivery 模块导入通过。
- `dart format --output=none --set-exit-if-changed lib test` 检查 95 个文件，无格式变化；`flutter analyze --fatal-infos` 零问题；`git diff --check` 通过。
- G1 曾完成 271 项 Flutter 全量回归；后续各批次按改动面完成 App Service 46 项、主窗口 / ASR 设置 / 诊断 48 项、任务处理 / 结果审看 8 项，以及 ASR planning / execution、pipeline / resume / segments、SRT / reflow / memory、chunk / route 等 Python 定向回归。
- 按项目负责人确认的发布后治理口径，本批次没有重复运行全量 `pytest -q`、最终全量 `flutter test` 或 `flutter build windows`，也没有重新做真实 Windows Release 多窗口人工回归。剩余风险集中在只会由完整并发套件或真实窗口生命周期暴露的时序问题；下一次相关行为改动或发布候选验收应重新覆盖这些场景。
- Python package 所有权、Flutter Local Service / 窗口职责和前端产品概念与实现字段的区别已分别回写三份当前专题文档。

## 7. 执行纪律

- 每个批次保持一个可审查的独立 diff；用户未明确要求时不提交。
- 先移动并保持测试，再移动生产职责；业务重写另开批次。
- 不以“文件已经变小”判断完成，以依赖方向、职责所有权和可独立验证判断完成。
- 发现既有缺陷时先记录复现；除非它阻止当前结构调整，否则不混入同一批次修复。
- 发现 secret、凭据解析分叉或协议行为漂移时立即停止普通拆分，优先按安全和兼容边界处理。
- 每完成一个批次，更新本文件的状态、实际验证和与原计划不同的取舍。
