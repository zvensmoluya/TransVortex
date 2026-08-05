# TransVortex 文档入口

本文档说明仓库里各类文档的用途和有效性。查找当前状态时先从这里进入，不要从历史快照反推现状。

## 用户文档

1. [`../README.md`](../README.md)
   - 产品介绍、下载、五步快速开始、当前能力、隐私摘要和已知限制。
2. [`USER_GUIDE.md`](USER_GUIDE.md)
   - Windows 桌面安装、首次配置、翻译与识别设置、任务制作、字幕审看、数据管理和故障恢复。
3. [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md)
   - 面向 CLI、Agent、手工 YAML 和兼容服务接入的高级配置与协议参考；普通桌面使用不需要先阅读。

## 当前工作入口

1. [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md)
   - 当前统一待办、`0.1.0` 发布事实、优先级和状态。
   - 只记录尚未闭环的事项，详细设计链接到对应专题文档。
2. [`运行与测试指南.md`](运行与测试指南.md)
   - 开发、构建、打包和验收命令。
3. [`FRONTEND/README.md`](FRONTEND/README.md)
   - Flutter 主体验前端的产品表面、配置语义、设计规格和历史归档入口。

## 发布与安全

- [`../SECURITY.md`](../SECURITY.md)：支持范围以及普通问题与敏感漏洞的报告方式。
- [`../CHANGELOG.md`](../CHANGELOG.md)：公开版本中用户可见的重要变化与发布边界。

## 当前专题文档

| 主题 | 文档 | 说明 |
| --- | --- | --- |
| 产品与系统总览 | [`PRODUCT_OVERVIEW.md`](PRODUCT_OVERVIEW.md) | 稳定产品模型、业务真实来源、核心流程与系统边界 |
| 后端分层 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | Python core、CLI、协议和桌面接入的所有权边界 |
| 桌面运行架构 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) | Local Service、Worker、Supervisor、托盘和发布基础 |
| 应用运行时与安装 | [`APP_RUNTIME.md`](APP_RUNTIME.md) | 固定 Python / FFmpeg runtime、NSIS 安装器和公开发布边界 |
| FFmpeg 分发合规 | [`FFMPEG_DISTRIBUTION_COMPLIANCE.md`](FFMPEG_DISTRIBUTION_COMPLIANCE.md) | core 编译许可、对应源码、通知和技术审查证据 |
| 高级配置与凭据 | [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md) | CLI / Agent 配置优先级、provider 协议、用户级凭据和安全边界 |
| 本机语音识别 | [`LOCAL_ASR_COMPONENTS.md`](LOCAL_ASR_COMPONENTS.md) | 本机 Whisper 组件、模型、下载和安装边界 |
| Agent / CLI 接入 | [`../agent/README.md`](../agent/README.md) / [`../agent/AGENT_USAGE.md`](../agent/AGENT_USAGE.md) | 安装后稳定入口、机器可读能力、Agent 自适配和按需 workflow |
| 翻译链路 | [`TRANSLATION_DESIGN.md`](TRANSLATION_DESIGN.md) | 当前分片、术语记忆、校验和修复边界 |
| 低优先级验证 | [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) | 已观察到但暂不承诺实现的实验问题 |

## 历史归档

以下目录保留历史上下文，不再表示当前实现或优先级：

- [`archive/README.md`](archive/README.md)：开发与设计快照、研究材料、单次执行记录和 E2E 报告。
- [`FRONTEND/README.md`](FRONTEND/README.md)：前端当前入口及其方向、失败实验和技术路线归档说明。

## 文档优先级

发生冲突时按以下规则判断：

1. 当前代码和验证结果优先于历史描述。
2. 当前状态与短期顺序以 `CURRENT_BACKLOG.md` 为准。
3. 前端能力是否公开以 `FRONTEND/current/FRONTEND_PRODUCT_SURFACES.md` 为准；视觉与交互以当前前端规格为准。
4. 安装、runtime、用户目录和桌面生命周期分别以对应专题文档为准。
5. 历史快照只用于理解背景，不建立新的兼容约束。

## 维护约定

- 新待办先判断是否已有专题文档；总待办只添加一句可验收描述和链接。
- 完成事项从总待办移除，必要的验证结论回写专题文档或 Git 历史，不在总表长期堆积完成项。
- 低优先级研究问题放入 `KNOWN_ISSUES_AND_VALIDATION.md`，不要与发布阻塞项混在一起。
- 单次执行过程不作为当前专题文档滚动维护；需要保留时归档，可复用的运行方式写入 `运行与测试指南.md`。
