# TransVortex Frontend Agent Brief

本文档是前端开发任务的入口说明。Agent 在处理 TransVortex desktop/frontend 相关任务前，应先阅读本文档，再按需要查阅更详细文档。

## 1. 当前策略

新前端按目标架构重建，不围绕旧 `desktop/src/main.tsx` 做长期渐进式迁移。

当前 desktop 是能力验证入口，证明了 Tauri 可以调用 worker、接收事件、管理 provider、打开结果、保存字幕行并重新导出。它可以作为能力参考，但不代表目标信息架构、页面结构、状态模型或视觉风格。

可以复用：

- Python worker 能力。
- Tauri command 边界。
- 任务工件和结果工作区能力。
- provider 管理能力。
- 经过确认的纯函数或 helper。

不要复用为新架构基础：

- 旧 `main.tsx` 的页面结构。
- 旧 `FormState` 作为新任务模型。
- 旧页面里的混合状态组织方式。
- 直接把 CLI/worker 参数铺成 React 表单的做法。

## 2. 必须遵守的产品骨架

- 任务是中心对象。
- 结果检查是主流程，不是附属工具。
- `Segment` 是字幕编辑的真实来源。
- SRT、ASS、VTT 是导出视图。
- 保存和重新导出是两个动作。
- 术语表是项目资产，不是隐藏参数。
- Provider 是服务连接体系，不是底层字段集合。
- 翻译服务和 ASR 服务必须分开表达。
- 失败状态必须解释原因、影响和下一步。
- 普通界面不直接暴露 worker/CLI 内部概念。

## 3. 开发前阅读顺序

默认先读：

- `docs/FRONTEND/FRONTEND_AGENT_BRIEF.md`

按任务需要再读：

- 产品方向冲突：`docs/FRONTEND/核心方向.md`
- 视觉和交互风格：`docs/FRONTEND/FRONTEND_DESIGN_STYLE.md`
- 能力范围和落地顺序：`docs/FRONTEND/FRONTEND_DEVELOPMENT_PLAN.md`
- 代码架构、领域模型、service、adapter、状态边界：`docs/FRONTEND/FRONTEND_IMPLEMENTATION_ARCHITECTURE.md`

不要在每个小任务里机械通读所有文档。先用本文档定位，再查相关细节。

## 4. 推荐开发展开

新前端建议从骨架开始，而不是从旧页面拆补开始。

推荐顺序：

1. 建立目标目录结构：`domain/`、`services/`、`adapters/`、`state/`、`pages/`、`components/`。
2. 封装 Tauri command service，不让页面直接调用 `invoke(...)`。
3. 定义前端领域模型：`TaskDraft`、`Task`、`TaskRun`、`Segment`、`SubtitleIssue`、`TermEntry`、`ServiceConnection`、`EnvironmentCheck`。
4. 实现 `AppShell`、路由和基础布局。
5. 实现 `NewTaskPage`。
6. 实现 `TaskHistoryPage` 和 `TaskDetailPage`。
7. 实现 `ResultReviewPage`。
8. 实现 `TermsPage`、`ModelCredentialsPage`、`EnvironmentDiagnosticsPage`。
9. 再补齐专家配置、视频预览、术语治理、批处理等增强能力。

## 5. 禁止事项

- 不要继续扩大 `desktop/src/main.tsx`。
- 不要让页面组件直接散落调用 Tauri `invoke(...)`。
- 不要让 React 表单字段直接等于 CLI/worker 参数。
- 不要把结果检查做成 JSON 查看器或导出文件查看器。
- 不要把术语表降级成 `preset` 下拉框。
- 不要把 provider key 写入 YAML、日志、文档、toast 或错误详情。
- 不要把翻译 provider 和 ASR provider 混成一个配置块。
- 不要把 `bootstrap`、`inject`、`patch`、`request_mapping` 等内部词作为普通界面的主文案。
- 不要为了兼容旧页面而扭曲新领域模型。

## 6. UI 和文案底线

- 默认使用自然中文面向用户解释状态和动作。
- 代码标识符、配置项、文件名、命令和 API 名称保留英文。
- 复杂能力先翻译成用户概念，再在必要时补充实现名。
- 不要使用表情符号作为 UI 元素或状态图标。
- 不要做赛博风、霓虹风、机能风、黑客风。
- 不要使用多颜色渐变、彩虹渐变、紫蓝霓虹渐变或发光字效作为主视觉。
- 不要做营销页式 hero、大面积玻璃拟态、强透明、强模糊、强发光按钮。
- 不要用注释性文字、说明书式段落或代码注释式提示代替界面设计。
- 普通界面不要出现类似“这里用于...”“该字段会传给...”“// ...”的实现说明。
- 高密度区域要稳定、清晰、适合长时间工作。
- 状态色必须配文字或图标，不只靠颜色表达。
- 图标按钮必须有 tooltip。
- 长任务必须有当前阶段、当前动作、取消、日志和失败恢复入口。
- 保存状态和导出状态必须分开显示。

## 7. 验证要求

- 文档改动通常不需要跑测试，但回复时说明未跑测试的原因。
- 桌面 UI 或 worker protocol 改动至少跑 `npm run build`。
- Tauri/Rust 改动至少跑 `cargo check`。
- Python、provider、ASR、翻译流程相关改动按 `AGENTS.md` 的 Validation 规则验证。

## 8. 开发输出要求

完成前端任务时，回复用户应说明：

- 改了哪些页面、模块或文档。
- 是否遵守了 agent brief 和前端架构边界。
- 跑了哪些验证。
- 未验证的风险是什么。

如果发现当前请求会导致前端回到参数表、旧页面补丁或凭据不安全方案，应主动指出风险，并给出符合目标架构的替代做法。
