# 受管 ASR 与安装版 APP E2E 验收

- 日期：2026-07-18
- 结论：受管组件本地暂存、安装、readiness、最小转录、安装器自动验收和已安装可见 APP 真实媒体任务全部通过
- 执行前代码基线：`269bf554c1d99f04981a90db58e358d6b189b68b`
- 验收范围：Windows x64 本机隔离暂存、内部 NSIS 安装目录与受管 `faster-whisper`

## 验收目标

本次把首阶段 external runtime APP E2E 之后最高风险的两层提前验真：

1. 本地构建的 Whisper runtime、NVIDIA 加速组件和固定模型能否在不修改产品清单的前提下，经由正式受管安装路径完成校验、切换和 readiness。
2. 内部安装包中的固定主 Python runtime 能否在不依赖工作区 Python 的情况下加载受管模型并运行独立 JSONL Whisper Host。
3. 从已安装的可见 Flutter APP 完成一条确实需要 ASR 的真实媒体任务，并固定任务、Worker、识别行和导出证据。

## 受管组件产物

构建清单与现场 ZIP 的大小和 SHA-256 已重新校验：

| 组件 | 版本 | 大小 | SHA-256 |
| --- | --- | ---: | --- |
| `managed:faster-whisper` | `1.0.0` | 97,550,681 bytes | `c9dd9904a1ea930d658c1381f3cffa3d3f263bcb89fef1d626f6b7416502cf0e` |
| `nvidia-cuda12` | `12.4` | 1,097,454,012 bytes | `92b4d540390c2240cd913d894f0066ee66aeb110b1c4e843bbd4a3331650d53c` |

模型使用 `large-v3`，固定 revision 为 `edaa852ec7e145841d8ffdb056a99866b5f0a478`。暂存脚本验证了清单中 5 个模型文件，安装后再次计算哈希，5 / 5 与隔离清单一致。

## 本地暂存与受管安装证据

- 会话使用独立 `LOCALAPPDATA` 和只在会话内有效的 ASR 清单副本。
- 产品清单未被修改；会话清单中的 URL 仅是 `https://local-staging.invalid/` 占位地址。
- runtime、NVIDIA ZIP 和 5 个模型文件以经验证的完整 `.part` 缓存提供；安装先校验缓存，未建立外部下载请求。
- 工作区 Python 验收报告记录 `ok=true`、`readiness.state=ready`、`runtime_source=managed`、`transport=stdio_jsonl`、`device=cuda`、`compute_type=int8_float16`。
- provider test 真实加载 `large-v3` 并返回 1 行探测转录，不是只检查文件存在。

安装中还观察到 Windows 安全扫描或共享锁可能使包含大量 DLL 的组件目录在原子切换时短暂返回权限错误。有界重试后同一切换正常完成，不放宽 ZIP、路径或哈希校验。

## 安装包与安装目录 runtime 证据

- 内部安装包：`TransVortex-0.1.0-windows-x64-setup-internal.exe`。
- 大小：79,485,120 bytes。
- SHA-256：`d03b605d6e988e84a990adb7527eaafa2d9e1d2eed107296b52974d7a5d3617f`。
- 安装器自动验收通过：目录保护、全新安装、固定 runtime、升级、运行中保护、AUMID 快捷方式、卸载与用户数据保留均通过。
- 使用安装目录内置 Python `3.13.14` 重跑受管验收，报告记录 `ok=true`、`readiness.state=ready`、`managed + stdio_jsonl + cuda + int8_float16`。
- 已安装 Flutter EXE SHA-256：`7f37ad53bfd8285029e24a1e55b84adb2755fece42a63e78c7e22265b23656a8`。

这些证据证明主 runtime 和受管 ASR 安装链路已从工作区 Python 解耦，并为随后可见 APP 任务提供了固定安装基线。

## 已安装可见 APP 真实媒体任务

- 从隔离安装目录启动正式 Flutter EXE，应用读到受管 `large-v3`、CUDA 和正式翻译路由；最终任务 ID 为 `tvx_20260718_100316_0195e8`。
- 任务与 checkpoint 最终均为 `DONE`；1 / 1 ASR 音频分段、1 / 1 翻译分片完成，规范化后得到 22 个源字幕段。
- Worker 归属为 `python`，命令为 `_worker`，状态为 `ended`，退出码为 0，并持久化最终 `DONE` 事件。`worker.json` 记录的解释器路径和 SHA-256 与安装目录 `runtime/python/python.exe`、验收器当前解释器完全一致。
- 1 个 ASR row 文件包含 23 条识别行；每条都记录 `runtime_source=managed`、`runtime_id=managed:faster-whisper`、`transport=stdio_jsonl`、`device=cuda`、`compute_type=int8_float16`。
- SRT 为 2,075 bytes，SHA-256 为 `c5bf12377d3f1b06cdddc58707de7269c98e42f8ea24ac77f0565205ff69e1d6`；ASS 为 4,595 bytes，SHA-256 为 `6fc14a7cfdef423a5309c55343d0304dd44102a9745f7d517fcc5706cb68b582`。
- 完成页正确显示结果和待审看提示；独立任务处理窗显示 22 个片段、SRT + ASS、双语与译文在前设置，可以浏览字幕和时间码。
- 点击“重新导出”后界面显示“字幕文件已更新”。机器报告同时证明两份输出在 Worker 退出约 130 秒后重新写出。
- 最终机器报告 `managed_asr_installed_app_e2e.json` 由安装目录内置 Python 生成，`ok=true`。报告只保留在隔离现场目录，不提交绝对路径。

一次先行任务使用了不适配的本机翻译端点并按预期失败；切回仓库正式路由后，旧任务继续保持创建时固化的路由，所以没有篡改失败任务，而是保留诊断证据并新建上述成功任务。这也验证了失败提示、检查点恢复和任务配置不可漂移的边界。

## 卸载与数据保留

确认无活动 Worker 后运行隔离安装目录中的静默卸载器：退出码为 0，程序目录在超时前删除；隔离 `Workspace/Tasks`、受管组件数据和最终机器报告仍保留。由此完成本机内部安装路径的真实任务与清理闭环。

## 其他验证

- Python 全量测试：573 passed。
- Flutter 静态检查：无问题。
- Flutter 测试：200 passed。

## 未覆盖与仍待闭环

- GitHub Release 或其他固定 HTTPS 地址上的真实组件发布、Range 续传和下载闭环。
- 没有任何工作区或开发工具的干净 Windows 首启、配置和真实媒体任务。
- 已安装路径的通知归属和点击聚焦。
- Authenticode 签名、时间戳和 Windows 验证。
- 与内置 LGPL FFmpeg 严格对应的完整源码公开托管。

片源名称、用户目录、安装目录和临时会话绝对路径不写入仓库文档；完整结构化报告只保留在现场机器的隔离会话目录。
