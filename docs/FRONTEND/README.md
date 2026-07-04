# TransVortex Frontend Docs

本目录只保留前端当前施工入口、硬规则和历史归档。

当前结论：

> Flutter 是主体验前端。历史桌面前端只证明后端对接可行，不再作为视觉、页面骨架或兼容约束。
> 早期 Flutter 验证已经收束到正式候选实现路径；这不等于“前端设计 MVP 已完成”，真实可见 release 窗口、外部服务和系统通知仍需单独验收。

## 当前有效文档

按下面顺序读即可：

1. `rules/FRONTEND_FAILURE_RECOVERY_RULES.md`
   - 前端重建的硬规则和停止条件。
   - 如果任何设计或实现重新滑向 Web 管理台感，优先按这份文档停止。
2. `current/FRONTEND_DELIVERY_GOALS.md`
   - 当前剩余交付目标。
   - 明确 Flutter MVP 接线之后还要完成什么，以及做到什么算完成。
3. `current/FRONTEND_DESIGN_SPEC.md`
   - 当前可实现设计规格。
   - 定义主窗口、翻译模型设置窗、语音识别设置窗的产品结构、交互和视觉边界。
4. `current/FRONTEND_IMPLEMENTATION_CONTRACT.md`
   - 早期 Flutter 验证收束为正式候选前端的实施边界。
   - 明确哪些服务接线保留、哪些临时 UI 已重写，以及用户动作到后端 RPC 的契约。
5. `current/FLUTTER_FRONTEND_IMPLEMENTATION_CHECKLIST.md`
   - Flutter MVP 施工清单。
   - 用于跟进真实任务流、配置流、结果流和验证项。

## 已归档文档

- `archive/2026-07-flutter-doc-consolidation/`
  - 保存本轮收敛前的 Goal、正向方向、白描框架、风格稿、图片生成记录、技术栈复盘和 HTML 预览。
  - 这些内容是设计推导和历史证据，不再作为当前入口规范。
- `archive/2026-05-web-workbench-failure/`
  - 保存旧设计风格、开发计划和生图提示。
  - 只能作为历史材料和反例。
- `archive/2026-05-product-architecture-overreach/`
  - 保存旧产品方向和工程架构长文档。
  - 有参考价值，但不具备当前规范地位。

## 使用原则

日常开发不要从 archive 里挑文档重新解释当前方向。需要改 UI 时，先看规则和当前交付目标，再看设计规格、实施契约和清单。

如果某份文档、代码或设计稿把前端推向下面这些方向，应立即停止：

- 通用后台管理台。
- SaaS 控制台。
- 左栏 + 顶栏 + 面板 + 列表的默认 Web 骨架。
- 圆角卡片网格。
- 用组件库审美代替设计意向。
- 用调色修补已经错误的页面结构。
