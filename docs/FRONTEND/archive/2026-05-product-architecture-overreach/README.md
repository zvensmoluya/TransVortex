# 2026-05 Product And Architecture Overreach Archive

本目录保存此前的产品方向和前端架构长文档。

归档原因：

> 这些文档包含一些仍然有用的产品判断和工程边界，但整体篇幅过重，容易把后续讨论重新拉回信息架构、代码分层和治理体系。当前前端已经长出了可用的 React/Tauri/service/adapter 框架，继续把注意力放在架构治理上会强化开发惯性，削弱设计判断。

这些文档不再是当前有效规范。

## 文件说明

- `核心方向.md`
  - 旧产品方向文档。
  - 其中关于任务、结果检查、术语、provider 的产品语义可作为历史参考。
  - 其中关于页面结构、信息架构、视觉方向的内容不再作为规范。
- `FRONTEND_IMPLEMENTATION_ARCHITECTURE.md`
  - 旧工程架构文档。
  - 其中 service/adapter/state 的边界可作为已有代码参考。
  - 它不应继续主导下一轮设计。

## 当前取代关系

当前前端重建优先遵守：

```text
docs/FRONTEND/rules/FRONTEND_FAILURE_RECOVERY_RULES.md
```

后续如果需要新的产品意图说明，应写成短文档，只回答“这是什么应用、要避免什么、第一张工作面应该是什么感觉”，不要恢复大而全的治理文档。
