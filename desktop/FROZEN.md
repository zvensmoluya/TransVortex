# Tauri 前端：已冻结（Frozen）

Tauri 桌面前端（`desktop/`、`desktop/src-tauri/`）已冻结为参考实现。主体验前端为 Flutter（`desktop_flutter/`）。

- 后端契约只由 CLI / Agent 与 Flutter Local Service 驱动；后端改动不承诺保持本 Tauri UI 可用，Tauri 不作为兼容约束。
- 冻结期允许已知降级行为，不作为 bug 处理。
- 必须保留的护栏：Tauri sidecar 以 `--no-pump` 启动 `transvortex.app_service`，避免其 Rust worker 驱动与 Python Local Service pump 在同一 `artifacts_dir` 上重复 acquire / spawn。
- 完整策略见仓库根 `AGENTS.md` 的 “Repository Boundaries” 一节。
