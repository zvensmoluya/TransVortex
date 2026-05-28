# TransVortex 前端开发架构

> 归档说明：本文档属于 2026-05 产品方向与架构治理过载阶段。它可作为已有代码分层参考，但不再是当前有效规范。后续前端重建优先遵守 `../../rules/FRONTEND_FAILURE_RECOVERY_RULES.md`。

本文档定义 TransVortex 前端实现架构。它服务于 `核心方向.md` 和 `../rules/FRONTEND_FAILURE_RECOVERY_RULES.md`，不重新定义产品方向，也不规定视觉结构。

当前 desktop 已经验证了 Tauri 可以调用 Python worker、接收 JSONL 事件、管理 provider、打开任务结果并重新导出。但当前实现主要是实验性工作台。它的后端对接有参考价值，视觉和页面骨架没有参考价值。

后续前端重设计不应继续扩大旧页面，也不应让 React 表单字段直接绑定 CLI/worker 参数。更重要的是，不能把旧实现中的左栏、顶栏、面板墙和卡片式布局当作可延续基础。

本架构的目标是：

- 让前端围绕任务、字幕行、术语、服务连接和环境诊断组织。
- 隔离 UI 领域模型和 worker/CLI 参数。
- 让 worker 事件流成为 UI 状态来源，而不是只作为日志。
- 保证结果检查、保存、重新导出、恢复任务这些核心流程可维护。
- 让 provider、凭据、ASR、术语和工件访问通过统一 service/adapter 管理。

## 1. 架构原则

### 1.0 架构服务设计意向

本文件只定义代码边界，不定义界面长相。

`domain/`、`services/`、`adapters/`、`state/`、`pages/` 和 `components/` 都是工程组织方式，不是视觉系统。任何工程抽象都必须服从已经成立的设计意向。

禁止从代码架构反推页面结构，例如：

- 有 `pages/` 就必须做 Web 多页面。
- 有 `components/layout/` 就必须做通用面板。
- 有 `state/` 就必须做 dashboard 状态块。
- 有 `ServiceConnection` 就必须做服务配置卡片。

视觉和交互开发必须先遵守 `../rules/FRONTEND_FAILURE_RECOVERY_RULES.md`。

### 1.1 UI 不直接绑定 CLI 参数

普通页面不应直接使用 `source_mode`、`memory_bootstrap_enabled`、`request_mapping` 这类内部字段作为主要状态。

前端应该先建立自己的领域模型，例如“字幕来源”“术语使用”“翻译服务”“语音识别服务”，再由 adapter 转成 Tauri command 或 worker 所需 payload。

### 1.2 页面围绕领域对象组织

页面和 store 应围绕这些领域对象组织：

- `TaskDraft`：新建任务草稿。
- `Task`：任务摘要和任务详情。
- `TaskRun`：正在运行的任务状态。
- `Segment`：结构化字幕行。
- `SubtitleIssue`：质量问题。
- `TermEntry`：术语条目。
- `ServiceConnection`：翻译服务或 ASR 服务连接。
- `EnvironmentCheck`：环境诊断项。
- `ExportJob`：重新导出状态。

不要让页面围绕 Tauri command、CLI flag 或 artifact 文件名组织。

### 1.3 Tauri command 只属于基础设施层

React 组件不应散落调用 `invoke(...)`。所有 Tauri command 应集中在 service 层，再由 adapter 做 payload 转换。

推荐调用链：

```text
Page / Component
  -> Store / Hook
  -> Service
  -> Adapter
  -> Tauri command
  -> Python worker / artifact
```

这样后续更换 command 名、拆分 worker payload 或迁移到 agent/自动化入口时，不会影响大量 UI 组件。

### 1.4 事件流先规范化，再进入 UI

worker JSONL event 不应直接渲染成页面状态。

事件流处理顺序应该是：

```text
raw WorkerEvent
  -> parse
  -> normalize
  -> append timeline
  -> update TaskRun state
  -> render UI
```

UI 最终消费的是当前阶段、当前动作、进度、错误摘要、可恢复性和输出状态，而不是原始 event 字段。

### 1.5 保存和重新导出是两个状态机

结果检查中必须分清：

- 保存：把当前 `Segment` 修改写回结果工作区。
- 重新导出：根据已保存的 `Segment` 生成 SRT、ASS、VTT。

这两个动作可以连续发生，但不能在状态模型里混成一个动作。

### 1.6 凭据和 provider 配置分离

Provider YAML 只能保存非敏感配置。API key、token、密码等 secret 只能通过统一 credential resolver 保存到用户级凭据文件。

前端必须把“服务连接配置”和“凭据保存状态”分开建模。

## 2. 推荐目录结构

推荐把 `desktop/src` 拆成以下结构：

```text
desktop/src/
  app/
    App.tsx
    router.tsx
    layout/
      AppShell.tsx
      MainNavigation.tsx
      TopTaskStatus.tsx

  domain/
    task.ts
    taskRun.ts
    segment.ts
    subtitleIssue.ts
    term.ts
    serviceConnection.ts
    environment.ts
    export.ts
    error.ts

  services/
    taskService.ts
    taskRunService.ts
    resultWorkspaceService.ts
    providerService.ts
    credentialService.ts
    environmentService.ts
    exportService.ts
    fileService.ts

  adapters/
    taskDraftAdapter.ts
    taskRecordAdapter.ts
    workerEventAdapter.ts
    resultWorkspaceAdapter.ts
    providerAdapter.ts
    environmentAdapter.ts
    errorAdapter.ts

  state/
    taskStore.ts
    taskRunStore.ts
    resultWorkspaceStore.ts
    providerStore.ts
    termStore.ts
    environmentStore.ts
    uiStore.ts

  pages/
    NewTaskPage/
    TaskHistoryPage/
    TaskDetailPage/
    ResultReviewPage/
    TermsPage/
    ModelCredentialsPage/
    EnvironmentDiagnosticsPage/
    SettingsPage/

  components/
    layout/
    task/
    subtitle/
    terms/
    provider/
    diagnostics/
    export/
    feedback/

  styles/
    tokens.css
    theme.css
    layout.css
```

这不是强制目录名，但分层边界应保持稳定：

- `domain/`：前端领域类型和纯函数，不调用 Tauri。
- `services/`：封装 Tauri command、文件打开、worker 调用。
- `adapters/`：worker/CLI payload 与前端领域模型互转。
- `state/`：页面共享状态、异步流程和状态机。
- `pages/`：页面组合，不直接拼接底层 payload。
- `components/`：可复用 UI，不知道 worker 细节。

## 3. 页面路由和职责

以下路由是逻辑入口，不是视觉骨架。它们可以映射成主工作面、浮层、抽屉、命令面板或任务级 modal，不要求做成常驻左栏导航下的 Web 页面。

逻辑入口：

```text
/new-task
/tasks
/tasks/:taskId
/tasks/:taskId/review
/terms
/services
/diagnostics
/settings
```

职责：

- `NewTaskPage`：创建任务草稿，完成启动前摘要和阻塞检查。
- `TaskHistoryPage`：展示历史任务，支持继续检查、恢复、打开输出。
- `TaskDetailPage`：展示任务进度、事件时间线、失败解释、输出和工件入口。
- `ResultReviewPage`：围绕字幕行完成检查、编辑、保存和重新导出。
- `TermsPage`：管理项目术语表、系统建议、已确认和强制固定术语。
- `ModelCredentialsPage`：管理翻译服务和 ASR 服务连接。
- `EnvironmentDiagnosticsPage`：展示阻塞问题、质量风险和可选增强。
- `SettingsPage`：承载不属于任务主流程的全局设置。

结果检查归属任务，但可以有快捷入口。快捷入口不应被理解为必须放入常驻导航栏；它可以是最近任务切换、命令面板、任务打开器或其他桌面应用交互。

## 4. 领域模型

### 4.1 TaskDraft

`TaskDraft` 是新建任务页面的核心状态，不等于 worker 的 `StartTaskRequest`。

```ts
export type TaskDraft = {
  input: TaskInput;
  languages: LanguageSettings;
  subtitleSource: SubtitleSourceChoice;
  translation: TranslationSettings;
  speechRecognition: SpeechRecognitionSettings;
  terms: TermUsageSettings;
  output: ExportSettings;
  advanced: AdvancedTaskSettings;
};
```

关键原则：

- `subtitleSource` 表达“自动 / 使用内置字幕 / 本地识别 / 云端识别 / 使用已有字幕”。
- `speechRecognition` 表达 ASR 服务，不和翻译 provider 混在一起。
- `terms` 表达术语表使用方式，不直接暴露 `bootstrap/inject/patch`。
- `output` 使用格式多选，不把 `both` 作为 UI 概念。

### 4.2 Task

```ts
export type Task = {
  id: string;
  title: string;
  status: TaskStatus;
  input: TaskInputSummary;
  languages: LanguageSettings;
  pipeline: TaskPipelineStep[];
  outputs: ExportedFile[];
  taskDirectory?: string;
  recoverability: Recoverability;
  error?: UserFacingError;
  createdAt: string;
  updatedAt: string;
};
```

`Task` 由 `TaskRecord` 和 artifact 摘要转换而来。UI 不应直接依赖 `task_id`、`output_paths`、`task_dir` 这些原始字段。

### 4.3 TaskRun

```ts
export type TaskRun = {
  taskId: string;
  phase: TaskPhase;
  currentAction: string;
  progress: ProgressState;
  timeline: TimelineEvent[];
  warnings: UserFacingWarning[];
  error?: UserFacingError;
  canCancel: boolean;
  canResume: boolean;
  lastEventAt?: string;
};
```

`TaskRun` 由 worker 事件流驱动。

### 4.4 Segment

```ts
export type Segment = {
  id: string;
  index: number;
  startMs: number;
  endMs: number;
  sourceText: string;
  translatedText: string;
  issues: SubtitleIssue[];
  termMatches: TermMatch[];
  diagnostics: SegmentDiagnostics;
  dirtyState: SegmentDirtyState;
};
```

`Segment` 是结果检查页的真实编辑对象。SRT、ASS、VTT 都是从 `Segment` 渲染出的导出视图。

### 4.5 SubtitleIssue

```ts
export type SubtitleIssue = {
  id: string;
  code: string;
  severity: "blocking" | "warning" | "info";
  title: string;
  description?: string;
  segmentId?: string;
  nextActions: IssueAction[];
};
```

内部 code 可以保留，但 UI 主文案使用 `title` 和 `description`。

### 4.6 TermEntry

```ts
export type TermEntry = {
  id: string;
  source: string;
  target: string;
  type: "person" | "address" | "term" | "title" | "asr_correction" | "phrase";
  status: "proposed" | "confirmed" | "locked";
  scope: "task" | "project" | "global";
  note?: string;
  relatedSegmentIds: string[];
};
```

`preset`、`runtime memory` 和任务内术语建议需要分清，不能在 UI 上混成一个列表来源。

### 4.7 ServiceConnection

```ts
export type ServiceConnection = {
  id: string;
  kind: "translation" | "asr";
  providerName: string;
  displayName: string;
  model?: string;
  credentialStatus: CredentialStatus;
  connectionStatus: ConnectionStatus;
  isDefault: boolean;
  fallbackTargets: ServiceTarget[];
  expertConfigAvailable: boolean;
};
```

翻译服务和 ASR 服务必须用 `kind` 分开。

## 5. Worker 和 Tauri 边界

现有 Tauri command 可以先作为基础设施入口保留，例如：

- `get_config`
- `list_tasks`
- `doctor`
- `read_events`
- `start_task`
- `resume_task`
- `cancel_task`
- `open_task_result`
- `save_task_segments`
- `reexport_task`
- `probe_provider`
- `save_provider_config`
- `test_provider_connection`
- `fetch_provider_models`
- `open_path`
- `probe_subtitle_streams`

但页面不应直接调用这些 command。推荐 service 映射：

| Service | 负责的 command |
| --- | --- |
| `taskService` | `list_tasks`, `start_task`, `resume_task`, `cancel_task` |
| `taskRunService` | `read_events`, worker event listener |
| `resultWorkspaceService` | `open_task_result`, `save_task_segments` |
| `exportService` | `reexport_task` |
| `providerService` | `probe_provider`, `save_provider_config`, `test_provider_connection`, `fetch_provider_models`, `save_provider_routing` |
| `environmentService` | `doctor`, `probe_subtitle_streams` |
| `fileService` | `open_path`, file picker, directory picker |

## 6. Adapter 设计

### 6.1 TaskDraftAdapter

`TaskDraftAdapter` 负责把前端任务草稿转成 worker payload。

示例职责：

- 把“字幕来源”转换为 `source_mode`。
- 把“语音识别服务”转换为 `asr_mode` 和 ASR 相关字段。
- 把“输出格式多选”转换为 worker 当前支持的输出格式字段。
- 把“术语使用设置”转换为 memory 相关开关。
- 把“项目背景 + 风格要求”转换为 `translation_style_prompt`。

这个 adapter 是唯一应该理解 CLI/worker 参数细节的前端位置之一。

### 6.2 WorkerEventAdapter

`WorkerEventAdapter` 负责把原始 `WorkerEvent` 转换为：

- `TimelineEvent`
- `TaskPhase`
- `ProgressState`
- `UserFacingError`
- `Recoverability`
- `ExportedFile`

它应该把阶段和事件转成用户可理解的状态，例如：

- 正在识别音频。
- 正在翻译字幕。
- 正在修复格式错误。
- 正在检查字幕质量。
- 正在导出 SRT、ASS、VTT。
- 翻译服务返回限流错误，可以稍后恢复或切换备用模型。

### 6.3 ResultWorkspaceAdapter

`ResultWorkspaceAdapter` 负责：

- 把 `ResultSegment` 转成 `Segment`。
- 把 quality report 转成 `SubtitleIssue`。
- 把 memory consistency issue 转成术语问题。
- 把 delivery report 转成输出格式状态。
- 把编辑后的 `Segment` 转回 `save_task_segments` 需要的结构。

### 6.4 ProviderAdapter

`ProviderAdapter` 负责：

- 把 provider config 转成 `ServiceConnection`。
- 把凭据状态转成 `CredentialStatus`。
- 把连接测试结果转成用户可理解的诊断。
- 隔离专家配置字段，例如 `request_mapping`、`response_mapping`、`extra_headers`。

## 7. 状态管理

状态可以使用 React context、Zustand、Redux Toolkit 或其他轻量方案。关键不是库，而是状态边界。

推荐 store：

- `taskStore`：任务列表、任务摘要、任务详情缓存。
- `taskRunStore`：当前运行任务、事件时间线、进度、取消和恢复状态。
- `resultWorkspaceStore`：当前任务的 segments、筛选、选中行、dirty 状态、保存状态。
- `providerStore`：服务连接、模型列表、连接测试、专家配置草稿。
- `termStore`：术语表、术语建议、任务术语命中、一致性问题。
- `environmentStore`：环境诊断结果和启动前检查结果。
- `uiStore`：导航、面板展开、toast、modal 等纯 UI 状态。

不要把所有状态继续放在 `App.tsx`。

## 8. 任务状态机

任务运行状态至少应覆盖：

```text
idle
draft
ready
starting
running
cancelRequested
cancelled
failedRecoverable
failedFatal
completed
```

任务完成后的结果检查状态应覆盖：

```text
notOpened
loading
clean
dirty
saving
savedPendingExport
exporting
exported
exportFailed
```

状态文案要从状态机派生，而不是由多个布尔值拼出来。

例如：

- `dirty`：有未保存修改。
- `savedPendingExport`：已保存，待重新导出。
- `exported`：已重新导出。
- `exportFailed`：导出失败，可查看原因或重试。

## 9. 结果检查架构

结果检查是最高风险页面，必须单独设计数据流。

推荐数据流：

```text
open_task_result
  -> ResultWorkspaceAdapter
  -> resultWorkspaceStore
  -> virtualized Segment list
  -> selected Segment editor
  -> local edits
  -> save_task_segments
  -> savedPendingExport
  -> reexport_task
  -> exported / exportFailed
```

关键约束：

- 字幕列表必须支持虚拟化，不能用普通表格硬撑几千行。
- 当前行编辑应只更新局部 dirty 状态。
- 质量问题和术语问题必须能跳转到字幕行。
- 保存时只保存结构化字幕行，不直接编辑 SRT/ASS/VTT 文件。
- 重新导出必须明确使用哪些格式。
- 输出预览是从当前 segments 派生的视图，不是唯一数据源。
- 字幕时间使用毫秒或明确单位，UI 显示时再格式化。

## 10. Provider 和凭据架构

Provider 页面应分两层：

- 普通服务连接：服务商、API key 状态、模型、测试连接、默认和备用模型。
- 专家配置：base URL、endpoint、auth、headers、request mapping、response mapping、limits、fallback 等。

领域模型应区分：

- `ProviderProfile`：非敏感 provider 配置。
- `CredentialStatus`：凭据是否存在、来源是什么、是否可用。
- `ServiceConnection`：用户看到的翻译服务或 ASR 服务连接。
- `RoutingProfile`：主模型和备用模型。

安全约束：

- 不在前端日志、toast、错误详情、文档或提交信息里显示 API key。
- 不把 key 写入 provider YAML。
- `.env` 只能作为开发兼容或兜底，不作为默认凭据方案。
- 保存凭据和测试连接都必须通过统一 credential resolver。

## 11. 术语表架构

术语表需要同时支持任务内使用和长期资产沉淀。

建议区分：

- `PresetTermBase`：用户选择或维护的预设术语表。
- `RuntimeTermMemory`：任务运行中形成的术语库。
- `ProposedTermEntry`：系统建议，待确认。
- `ConfirmedTermEntry`：用户确认。
- `LockedTermEntry`：强制固定。
- `TermConsistencyIssue`：疑似违反术语表的字幕行问题。

结果检查和术语表页面应共用术语领域模型。结果检查页看到的是“当前任务相关术语和问题”，术语表页管理的是“可复用资产”。

从任务沉淀术语表必须是明确动作，不应在用户无感知时自动覆盖人工术语。

## 12. 错误和诊断架构

UI 不应直接展示 Python traceback 或 provider 原始错误作为主提示。

推荐错误模型：

```ts
export type UserFacingError = {
  title: string;
  impact: string;
  nextActions: ErrorAction[];
  severity: "blocking" | "warning" | "info";
  technicalDetail?: string;
  source?: "worker" | "provider" | "asr" | "filesystem" | "environment";
};
```

错误提示结构：

```text
发生了什么
影响是什么
下一步可以做什么
技术详情
```

环境诊断项也应采用类似结构：

```ts
export type EnvironmentCheck = {
  id: string;
  label: string;
  status: "pass" | "warn" | "fail";
  category: "blocking" | "quality_risk" | "optional";
  impact: string;
  nextActions: DiagnosticAction[];
  technicalDetail?: string;
};
```

## 13. 组件开发约束

组件实现应遵守：

- 不使用有完整视觉风格的通用组件库作为视觉基础。
- 不从 `Card`、`Panel`、`Badge`、`DashboardGrid` 这类后台抽象开始设计页面。
- 可复用组件只能从已经成立的界面中提取，不能预先发明组件系统再让设计服从它。
- 新设计里的核心图形不能由通用线性图标库决定。
- 高密度列表必须有稳定行高和虚拟化方案。
- 图标按钮必须有 tooltip。
- 状态色必须配文字或图标，不能只靠颜色表达。
- 长任务区域必须提供取消、日志入口和失败恢复入口。
- 专家字段不得出现在普通路径默认视图。
- 字幕编辑器不能因为内容变化导致页面大幅跳动。
- 结果检查里的搜索、筛选和问题跳转必须保持键盘效率。
- 工件目录入口可以存在，但普通用户优先看到“打开输出文件”“查看质量报告”“查看 ASR 诊断”等包装入口。
- 文件路径和凭据状态要清楚，但不得暴露 secret。

## 14. 重建设计策略

新前端不建议围绕当前 `desktop/src/main.tsx` 做长期渐进式迁移。

当前 desktop 的价值是能力验证：它证明了 Tauri 可以调用 worker、接收事件、管理 provider、打开结果、保存字幕行并重新导出。它不应该继续承担新信息架构和新视觉体系的演进基础。

推荐策略是：

> 保留旧 desktop 作为能力参考和临时验证入口，新前端按目标架构重建。

重建时应遵守：

1. 先建立 `domain/`、`services/`、`adapters/`、`state/`、`pages/` 的目标目录结构。
2. 先封装 Tauri command service，不让新页面直接调用 `invoke(...)`。
3. 先定义 `TaskDraft`、`Task`、`TaskRun`、`Segment`、`TermEntry`、`ServiceConnection` 等领域模型。
4. 再实现新页面骨架：新建任务、任务历史、任务详情、结果检查、术语表、模型与凭据、环境诊断。
5. 新页面只复用经过确认的能力边界和少量纯函数，不把旧页面状态结构搬进新架构。
6. 旧页面中的 provider helper、JSON mapping、时间格式化等逻辑如需复用，应先抽成独立模块，再由 adapter/service 调用。
7. 新旧界面可以短期并存，但不能为了兼容旧页面而扭曲新领域模型。

这不是推倒 worker 或 Tauri command。需要重建的是前端信息架构、状态结构和页面组合方式。底层 worker 能力、任务工件、provider 管理和结果工作区能力应继续复用。

## 15. 开发验收标准

第一批前端重构至少应满足：

- 新建任务页面使用 `TaskDraft`，而不是直接编辑 worker payload。
- 启动任务通过 `taskService` 和 `TaskDraftAdapter`。
- 任务详情从事件流派生当前阶段、进度、错误和可恢复状态。
- 结果检查使用 `Segment` 作为编辑对象。
- 编辑字幕后能显示 dirty 状态。
- 保存后能显示“已保存，待重新导出”。
- 重新导出后能显示输出文件状态。
- 翻译服务和 ASR 服务在模型与凭据页分开表达。
- Provider key 只显示保存状态，不显示 secret。
- 环境诊断能区分阻塞问题、质量风险和可选增强。
- 普通页面不直接显示 `bootstrap`、`inject`、`patch`、`request_mapping` 等内部术语。

这些标准不是完整功能清单，而是架构底线。只要底线成立，前端可以逐步填充更完整的能力。
