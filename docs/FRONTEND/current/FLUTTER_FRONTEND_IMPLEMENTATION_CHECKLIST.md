# Flutter 前端实现清单

本文档把 `FRONTEND_DEVELOPMENT_GOALS.md` 的验收标准、`FRONTEND_DESIGN_SPEC.md` 的三个窗口 MVP、`DESKTOP_APP_LOCAL_SERVICE_ARCHITECTURE.md` 的本地服务模型，收敛成一份可直接施工的实现清单。

它不是新的设计稿，也不是再抽象一层架构图。它只回答四件事：

- Flutter 前端 MVP 现在要做什么。
- 每个界面应该接哪些后端能力。
- 当前后端已经能接什么，哪里还缺口。
- 哪些验证必须做，才算真的接上。

---

## 0. 结论先行

当前阶段的 Flutter 前端 MVP 目标，不是“把 Spike 做漂亮”，而是把主流程接成一条真实链路：

1. 主窗口显示真实服务状态和真实配置摘要。
2. 用户从主窗口选择片源。
3. 用户在主窗口设置本单运行参数。
4. 用户点击开始后，任务进入 `runtime.submitRun`。
5. 运行中状态、任务事件、失败信息从 `runtime.snapshot` / `tasks.events` / `desktop.snapshot` 刷新。
6. 完成后能打开输出、打开任务目录、重新导出。

三个窗口的 MVP 仍然成立：

- 主窗口
- 翻译模型设置窗
- 语音识别设置窗

其余能力先归入“后续设计轮次”，不要反客为主。

---

## 1. 现有基础

### 已有的 Flutter 基础

- `desktop_flutter/lib/services/app_service_client.dart` 已有 `JsonRpcTransport`、`LocalServiceSupervisor`、`AppServiceClient`、`ServiceInfo`、`ServiceHealth`、`DesktopSnapshot`。
- `desktop_flutter/lib/services/local_service_controller.dart` 已有启动、刷新、重启、关闭、退出监控。
- `desktop_flutter/lib/main.dart` 已经能在主窗口读取 `desktop.snapshot`，并把配置就绪状态灌进主屏。
- `desktop_flutter/lib/widgets/job_line.dart`、`primary_action.dart`、`settings_window.dart`、`sidecar_probe_view.dart` 已经把 spike 结构搭起来。

### 已有的后端能力

- `src/transvortex/app_service.py` 已有 `service.info`、`service.health`、`service.shutdown`、`desktop.snapshot`、`runtime.snapshot`、`runtime.reconcile`、`runtime.submitRun`、`runtime.submitResume`、`runtime.acquireNext`、`runtime.releaseActive`、`runtime.cancel`、`tasks.list`、`tasks.events`、`provider.*`、`auth.*`、`prompt.asr.*`、`result.*`、`memory.exportPreset`。
- `src/transvortex/artifacts/runtime.py` 已有任务排队、单活动 worker、reconcile、取消宽限、强制取消。
- `src/transvortex/artifacts/task_store.py` 已有事件页读取，cursor 以行号方式工作。
- `src/transvortex/app/desktop_requests.py` 已有 `RunRequest` / `ResumeRequest` 的 payload 规范，`overrides` 可承载运行时选项。

### 当前明确缺口

- 主窗口已经把“开始译制”接到 `runtime.submitRun`，并能轮询任务状态、读取事件页、取消任务。
- 翻译设置窗已经能读取真实 provider / routing，并调用 `provider.save`、`provider.models`、`provider.test`、`provider.routing.save`。
- ASR 设置窗已经有 `asr.provider.save` 后端入口，能保存默认识别方案到 `pipeline.yaml`，远端 key 仍写用户级 `auth.json`。
- 完成态已经能读取结果并打开字幕 / 所在文件夹；错误修复件、任务历史、诊断窗、术语管理、结果审看仍属后续轮次。

---

## 2. MVP 范围

### 必做

- 主窗口真实启动 Local Service。
- 主窗口读取真实 `desktop.snapshot`。
- 主窗口把“开始译制”接到 `runtime.submitRun`。
- 主窗口在运行中可刷新任务状态与事件页。
- 主窗口完成后能打开结果和任务目录。
- 翻译设置窗能够修改当前默认翻译路由。
- 翻译设置窗能够保存 provider、key、routing，并做连接测试 / 模型列表拉取。
- ASR 设置窗能够展示当前 ASR 方案，并完成最少一条“可选引擎”的配置链路。

### 暂缓

- 任务历史完整页。
- 任务详情完整页。
- 结果审看完整编辑器。
- 术语管理完整页。
- 环境诊断完整页。
- 高级打包 / 通知 / 托盘。

---

## 3. 窗口实现清单

### 3.1 主窗口

#### 要接的能力

- `service.info`
- `service.health`
- `desktop.snapshot`
- `runtime.submitRun`
- `runtime.submitResume`
- `runtime.snapshot`
- `runtime.cancel`
- `tasks.events`
- `result.open`
- `result.reexport`

#### UI 任务

- 空态显示“放入视频或字幕文件”。
- 文件选择走系统文件对话框。
- 拖放文件走当前桌面运行时的原生拖放路径。
- `JobLine` 变成真实运行参数摘要，而不是 spike 演示态。
- 主 CTA 依据真实状态切换：
  - 空态：禁用
  - 就绪：开始译制
  - 受阻：去配置翻译 / ASR
  - 运行中：停下
  - 完成：再做一个
  - 失败：重试

#### 具体字段

- 输入文件路径
- 源语言
- 目标语言
- 双语开关
- 输出格式
- 翻译默认方案
- ASR 默认方案
- 术语记忆相关运行时选项
- 字幕整形相关运行时选项

#### 现在的实现方式建议

- 主窗口先继续保留 `Session`，但它的来源要从 spike 状态改成服务 snapshot + 当前 draft。
- “开始译制”先只支持 `run`，`resume` 作为次级动作。
- 运行参数优先走 `overrides`，不要等完整设置窗全部落完再接线。

### 3.2 翻译模型设置窗

#### 已有后端能力

- `provider.save`
- `provider.delete`
- `provider.models`
- `provider.test`
- `provider.routing.save`
- `auth.set`
- `auth.list`

#### UI 任务

- 左侧 provider 列表，右侧详情面板。
- 当前默认翻译方案要能从 routing 中读写。
- 保存 provider 时，API key 不进 YAML，只写用户级认证文件。
- 拉模型列表、测试连接、设为默认模型都要可用。
- 保存后主窗口的翻译默认标签要即时更新。

#### MVP 重点字段

- provider 名称
- api_type / compat_mode
- base_url
- credential_id / env_key
- model 列表
- endpoint
- request / response mapping
- routing primary / fallback

#### 当前注意点

- 现有 Flutter UI 已经接上 provider 保存、模型拉取、连接测试和默认路由写入。
- 需要把“当前默认翻译”与“可编辑 provider 列表”分开，不要回到表格台。
- 当前表单只覆盖 MVP 字段；request / response mapping、fallback routing、高级参数仍应留在后续偏好窗细化。

### 3.3 语音识别设置窗

#### 已有后端能力

- `desktop.snapshot` 里的 `asr_providers`
- `config.get`
- `doctor` 里对 ASR provider 的检查逻辑
- `asr.provider.save`
- `prompt.asr.save`
- `prompt.asr.delete`

#### 现状判断

ASR 设置窗现在能展示现有配置，并能通过 `asr.provider.save` 保存一个默认识别方案。
MVP 先控制在两层：

1. 展示当前引擎和就绪状态。
2. 保存本机 / FunASR / 云端 OpenAI Whisper 的最小配置链路。

#### UI 任务

- 三个引擎的选择要可见：
  - 本机识别
  - FunASR
  - 云端 OpenAI Whisper
- 选中引擎后，右侧显示该引擎的最小必要字段。
- 云端引擎需要 key / base_url / model / endpoint。
- 本地引擎需要 model_size / device / compute_type。
- FunASR 需要本地服务地址和可测试入口。

#### 现实约束

- `asr.provider.save` 已能写入 `pipeline.yaml` 的 `asr.provider` / `asr_providers`。
- FunASR 连通性和本机 faster-whisper 依赖检查仍主要依赖 doctor；设置窗只做最小配置保存，不上传音频做真实识别测试。
- ASR 的高级 chunking、静音切分、并发、预处理参数仍属后续详细设置。

---

## 4. 数据流清单

### 启动

1. `LocalServiceSupervisor.start()`
2. `service.info`
3. `service.health`
4. `desktop.snapshot`
5. 初始化主窗口状态

### 运行

1. 用户选片源
2. 读取当前 draft
3. 组装 `runtime.submitRun` 的 request
4. 返回 `task_id`
5. 轮询 `runtime.snapshot`
6. 按需拉 `tasks.events`

### 完成

1. `runtime.snapshot` 进入终态
2. `desktop.snapshot` 刷新任务列表
3. `result.open`
4. `result.reexport`

### 失败

1. 读取 `task.error_info`
2. 读取 `tasks.events`
3. 根据 `code` / `hint_zh` 组织修复动作
4. 必要时导向翻译设置窗 / ASR 设置窗 / 结果修复动作

---

## 5. 主窗口运行参数映射

### 现在可以直接映射的

- `output_format`
- `subtitle_bilingual_order`
- `subtitle_prefer_single_line`
- `subtitle_quality_mode`
- `memory_enabled`
- `memory_bootstrap_enabled`
- `memory_inject_enabled`
- `memory_patch_enabled`
- `memory_intensity`
- `memory_patch_window_chunks`

### 仍需谨慎的

- `memory_presets`
- provider 级 overrides
- ASR 专属 overrides

这些可以先作为高级项保留在 draft 里，不必在第一屏全暴露。

---

## 6. 设计对齐清单

主窗口必须继续满足这些设计要求：

- 单主体，不做 dashboard。
- 不做路由页。
- 不做左栏导航。
- 不做卡片墙。
- 不把设置窗做成网页 modal。
- 不把失败做成错误海报。
- 不把状态只压在颜色上。

翻译窗和 ASR 窗必须满足：

- 真正的独立工具窗。
- 主从结构清楚。
- 左侧是选择，右侧是详情。
- 选择变化后主窗口同步更新。

---

## 7. 验证清单

### Python 侧

- `pytest tests/test_app_service.py`
- `pytest tests/test_task_runtime.py`
- `pytest tests/test_task_store.py`
- `pytest tests/test_utils.py`

### Flutter 侧

- `flutter test`
- `flutter build windows`

### 人工验收

- 主窗口能启动 Local Service。
- 主窗口能读取真实配置摘要。
- 主窗口能把一次任务提交到后端。
- 翻译设置窗改默认方案后，主窗口即时更新。
- ASR 设置窗至少能反映当前引擎和就绪状态。
- 完成态能打开结果。

---

## 8. 建议的实现顺序

1. 已完成：把主窗口的“开始译制”接到 `runtime.submitRun`。
2. 已完成：把主窗口状态改成真实任务状态源，并接 `tasks.events` / `runtime.cancel`。
3. 已完成：把翻译设置窗接到 `provider.save` / `provider.routing.save` / `provider.test` / `provider.models`。
4. 已完成：补 `asr.provider.save` 并接 ASR 设置窗最小保存链路。
5. 已完成：接完成态结果读取、打开字幕、打开所在文件夹、重新导出。
6. 后续：做任务历史、诊断、术语、结果审看、通知和更完整的人工验收矩阵。

---

## 9. 当前缺口总表

| 项目 | 现状 | 处理建议 |
| --- | --- | --- |
| 主窗口启动与健康检查 | 已接真实服务 | 持续保留诊断入口 |
| 主窗口提交任务 | 已接 `runtime.submitRun` | 后续补更完整失败修复动作 |
| 主窗口运行态 | 已接 `runtime.snapshot` / `tasks.events` | 后续做任务详情 / 事件子窗口 |
| 翻译设置保存 | 已接 provider 保存、模型拉取、连接测试、默认路由 | 后续补 fallback routing 和高级 mapping |
| ASR 设置保存 | 已补 `asr.provider.save` 并接 UI | 后续补 doctor 连通性入口和高级参数 |
| 完成态结果动作 | 已接 `result.open` / `result.reexport` / 系统打开 | 后续补结果审看 |
| 任务历史 / 诊断 / 术语 | 未纳入 MVP | 后续轮次再做 |

---

## 10. 结语

这份清单的定位很简单：它把 Flutter 前端 MVP 从“看起来像在做”变成“知道下一步该接哪根线”。

截至当前实现，主窗口真实任务流、翻译设置工具窗和 ASR 设置工具窗的 MVP 接线已经成立。后续优先级应转向结果审看、任务历史、术语管理、诊断修复和真实桌面窗口的视觉 / 交互验收矩阵。
