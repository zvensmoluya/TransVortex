# Flutter APP 人工 E2E 第一阶段验收

- 日期：2026-07-17
- 结论：通过
- 代码基线：`0fb3d4e85ec708c7797136e12d369df1bd6ecad9`
- 验收范围：开发态隔离 Profile 下的可见 Flutter Release 全流程

## 验收范围

使用真实日语音频完成以下用户流程：

1. 启动可见 Flutter Release，并确认首页任务摘要。
2. 选择真实媒体并提交日语到简体中文的双语字幕任务。
3. 观察本机 Whisper 识别、翻译分片和任务进度。
4. 等待任务完成并生成 SRT、ASS。
5. 打开结果工作区，审看字幕、使用编辑能力并重新导出。

本次验收确认的是 APP 端实际体验和开发态工作区全链路，不是 CLI smoke。验收人确认整体流程连贯、主要动作可理解、任务可完成，可以评估为第一阶段功能通过。

## 机器证据

- Flutter Release SHA-256：`7f37ad53bfd8285029e24a1e55b84adb2755fece42a63e78c7e22265b23656a8`。
- 任务：`tvx_20260717_233655_926c67`，最终状态 `DONE`。
- Python Worker：`owner=python`、`command=_worker`、`state=ended`、`exit_code=0`。
- ASR：11 / 11 个音频分段完成，持久化 11 个 rows 文件、279 条识别结果。
- 全部识别结果均记录：
  - `provider=faster_whisper_large_v3`
  - `protocol=faster_whisper`
  - `runtime_source=external`
  - `transport=stdio_jsonl`
  - `device=cuda`
  - `compute_type=int8_float16`
- 翻译：任务完成 2 个逻辑分片，发生过一次自适应拆分 / batch recovery，最终正常完成。
- 输出：SRT 与 ASS 均存在且非空；结果工作区随后完成一次重新导出。
- 会话级 `app_e2e_session.json` 严格校验通过，覆盖可见 Release、工作区 Local Service、external local worker、独立 JSONL Whisper Host、真实 ASR 媒体任务、结果打开与审看。

片源名称、用户目录和临时会话绝对路径不写入仓库文档；完整结构化证据只保留在现场机器的隔离 E2E 会话目录。

## 人工体验结论

通过项：

- 从选择片源到识别、翻译、完成、结果审看和重新导出的主流程成立。
- 运行状态能够表达当前处于识别还是翻译，并显示分段 / 分片进度。
- 首阶段产品功能没有发现阻断性流程问题。

非阻断观察：

- 长任务运行界面仍偏单调；阶段反馈、交互动效和整体美术风格可以继续深化。
- 结果编辑工作区的字幕轴目前可用性一般，定位和校时手感仍有改进空间。
- 这些属于体验深化，不要求首阶段做到专业 NLE 或极致字幕编辑器能力，不影响本次功能通过结论。
- 本次任务最终质量报告仍有 `quality_status=FAIL`、交付检查为 `WARN`，主要包含行数、短时长和 CPS 提醒。本次只确认功能链路与人工操作体验，不把单一样本的字幕质量当作质量基准验收。

## 未覆盖范围

- 受管 Whisper runtime、NVIDIA 组件和模型的下载、校验与安装。
- 正式安装目录中的同等真实媒体任务。
- 干净 Windows 系统的首启、配置和真实任务。
- 通知归属、点击聚焦和 Authenticode 等公开发布条件。

因此，本报告关闭“开发态真实可见窗口完整任务验收”，但不关闭受管组件、已安装路径和干净系统的 P0 验收项。
