# TransVortex 文档入口

本文档说明仓库里各类文档的用途和有效性。查找当前状态时先从这里进入，不要从历史快照反推现状。

## 当前工作入口

1. [`CURRENT_BACKLOG.md`](CURRENT_BACKLOG.md)
   - 当前统一待办、优先级和状态。
   - 只记录尚未闭环的事项，详细设计链接到对应专题文档。
2. [`运行与测试指南.md`](运行与测试指南.md)
   - 开发、构建、打包和验收命令。
3. [`FRONTEND/README.md`](FRONTEND/README.md)
   - Flutter 主体验前端的当前规则、规格、施工清单和历史归档入口。

## 当前专题文档

| 主题 | 文档 | 说明 |
| --- | --- | --- |
| 综合设计背景 | [`项目设计说明书.md`](../项目设计说明书.md) | 产品与架构演进说明，不代替当前施工计划和专题边界 |
| 产品方向 | [`PRODUCT_DIRECTION.md`](PRODUCT_DIRECTION.md) | 长期产品定位和能力边界，不代替短期待办 |
| 后端分层 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | Python core、CLI、协议和桌面接入的所有权边界 |
| 桌面运行架构 | [`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md`](DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md) | Local Service、Worker、Supervisor、托盘和发布基础 |
| 应用运行时与安装 | [`APP_RUNTIME.md`](APP_RUNTIME.md) | 固定 Python / FFmpeg runtime、NSIS 安装器和公开发布边界 |
| 配置与凭据 | [`CONFIG_GUIDE.md`](CONFIG_GUIDE.md) | 配置优先级、provider、用户级凭据和安全边界 |
| 本机语音识别 | [`LOCAL_ASR_COMPONENTS.md`](LOCAL_ASR_COMPONENTS.md) | 本机 Whisper 组件、模型、下载和安装边界 |
| 云端语音识别方向 | [`ASR_PROVIDER_DIRECTION.md`](ASR_PROVIDER_DIRECTION.md) | 云端 ASR provider 的设计和演进方向 |
| 翻译链路 | [`TRANSLATION_DESIGN.md`](TRANSLATION_DESIGN.md) | 翻译、术语记忆、校验和修复设计 |
| 低优先级验证 | [`KNOWN_ISSUES_AND_VALIDATION.md`](KNOWN_ISSUES_AND_VALIDATION.md) | 已观察到但暂不承诺实现的实验问题 |

## 历史归档

以下目录保留历史上下文，不再表示当前实现或优先级：

- [`archive/README.md`](archive/README.md)：开发快照、单次执行记录和带日期的 E2E 报告。
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
