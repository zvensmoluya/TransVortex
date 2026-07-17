# TransVortex 历史文档归档

本目录保存已经完成使命、但仍有追溯价值的计划快照、执行记录和测试复盘。这里的内容不代表当前实现、优先级或兼容承诺。

当前文档入口见 [`../README.md`](../README.md)，当前统一待办见 [`../CURRENT_BACKLOG.md`](../CURRENT_BACKLOG.md)。前端设计路线的独立历史归档由 [`../FRONTEND/README.md`](../FRONTEND/README.md) 统一说明。

## 开发快照

- [`development-snapshots/2026-02-13-provider-probe-execution-log.md`](development-snapshots/2026-02-13-provider-probe-execution-log.md)
  - provider 私有配置与零 Token 预检落地时的单次执行记录。
- [`development-snapshots/2026-05-v1-implementation-plan.md`](development-snapshots/2026-05-v1-implementation-plan.md)
  - V1.x 早期 CLI、Tauri、凭据和分发判断的阶段快照。

## E2E 报告

- [`e2e-reports/2026-05-13-e2e-report.md`](e2e-reports/2026-05-13-e2e-report.md)
  - 真实日语动画样本的早期全链路测试记录。
- [`e2e-reports/2026-07-11-mare-postmortem.md`](e2e-reports/2026-07-11-mare-postmortem.md)
  - Mare 任务请求放大问题及后续修正的复盘证据。
- [`e2e-reports/2026-07-17-flutter-app-e2e-first-stage.md`](e2e-reports/2026-07-17-flutter-app-e2e-first-stage.md)
  - 可见 Flutter Release 使用开发态 external Whisper Worker 完成首阶段人工 APP E2E 的机器证据与体验结论。

## 设计快照与研究

- [`design-snapshots/2026-07-project-design-evolution.md`](design-snapshots/2026-07-project-design-evolution.md)：旧项目设计演进说明。
- [`design-snapshots/2026-07-product-direction.md`](design-snapshots/2026-07-product-direction.md)：旧产品方向与入口路线。
- [`design-snapshots/2026-05-translation-design.md`](design-snapshots/2026-05-translation-design.md)：早期翻译 MVP 与目标设计。
- [`design-snapshots/2026-07-local-service-architecture.md`](design-snapshots/2026-07-local-service-architecture.md)：Local Service 分阶段架构长稿。
- [`research/2026-06-asr-provider-direction.md`](research/2026-06-asr-provider-direction.md)：多厂商 ASR 生态调研。

## 归档规则

- 带日期的一次性执行记录、测试报告和复盘在结论稳定后移入这里。
- 仍约束当前产品语义、架构边界、运行方式或验证入口的专题文档留在 `docs/` 根目录。
- 归档内容如与当前代码或专题文档冲突，以当前代码、验证结果和当前专题文档为准。
- 归档文件原则上不继续滚动更新；仍有效的结论应回写当前专题文档。
