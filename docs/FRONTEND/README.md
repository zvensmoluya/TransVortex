# TransVortex Frontend Docs

Flutter（`desktop_flutter/`）是唯一产品桌面前端。已移除的历史前端实现只保留在归档文档和 Git 历史中，不建立视觉、产品或兼容约束。

仓库级优先级见 [`../CURRENT_BACKLOG.md`](../CURRENT_BACKLOG.md)。当前前端只保留四份事实源：

1. [`current/FRONTEND_PRODUCT_SURFACES.md`](current/FRONTEND_PRODUCT_SURFACES.md)
   - 决定能力是否公开、归属哪个窗口、当前状态允许什么动作。
2. [`current/FRONTEND_TASK_CONFIGURATION_SEMANTICS.md`](current/FRONTEND_TASK_CONFIGURATION_SEMANTICS.md)
   - 决定参数来源、任务快照、片源差异和继续任务行为。
3. [`current/FRONTEND_DESIGN_SPEC.md`](current/FRONTEND_DESIGN_SPEC.md)
   - 定义窗口模型、主要交互和禁止模式。
4. [`current/FRONTEND_VISUAL_INTERACTION_SPEC.md`](current/FRONTEND_VISUAL_INTERACTION_SPEC.md)
   - 定义视觉世界、场景级动效、颜色和反馈原则。

## 历史归档

- `archive/2026-07-current-doc-cleanup/`：退出当前入口的实施契约、交付目标、施工清单、窗口提案和旧原型。
- `archive/2026-07-flutter-doc-consolidation/`：Flutter 技术路线、风格推导和早期预览。
- `archive/2026-05-web-workbench-failure/`：旧 Web 工作台失败实验。
- `archive/2026-05-product-architecture-overreach/`：旧产品与前端架构长稿。

归档材料只用于理解背景。新增入口或改变产品语义时，必须回写当前四份文档中的对应事实源。
