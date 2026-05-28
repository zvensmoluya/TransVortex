# TransVortex Frontend Docs

本目录用于管理 TransVortex 前端失败后的开发准则和历史归档。

当前结论：

> 旧 desktop 前端已经验证了后端对接能力，但视觉和页面结构走向了 Web 管理台。后续前端不能沿着旧界面继续调色、换组件或精修卡片布局。

## 当前有效文档

- `rules/FRONTEND_FAILURE_RECOVERY_RULES.md`
  - 定义失败后的硬规则。
  - 后续前端重建优先遵守这份文档。

当前不保留大而全的产品方向或架构治理文档作为前置规范。已有 React/Tauri/service/adapter 框架可以作为代码事实存在，但不应继续吸走设计注意力。

## 已归档文档

- `archive/2026-05-web-workbench-failure/`
  - 保存旧设计风格、开发计划和生图提示。
  - 这些文档只能作为历史材料和反例，不能作为当前实现规范。
- `archive/2026-05-product-architecture-overreach/`
  - 保存旧产品方向和工程架构长文档。
  - 这些文档有参考价值，但不再具备当前规范地位。

## 使用原则

先读 `rules/FRONTEND_FAILURE_RECOVERY_RULES.md`。只有在需要查历史判断或已有代码边界时，才去 archive 目录。

如果某份文档、代码或设计稿把前端推向下面这些方向，应立即停止：

- 通用后台管理台。
- SaaS 控制台。
- 左栏 + 顶栏 + 面板 + 列表的默认 Web 骨架。
- 圆角卡片网格。
- 用组件库审美代替设计意向。
- 用调色修补已经错误的页面结构。
