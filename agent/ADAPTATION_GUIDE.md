# Agent Adaptation Guide

TransVortex 不附带面向所有 Agent 的通用 skill。Codex、Claude Code、OpenClaw 和其他 Agent 各自有不同的扩展格式、发现位置、授权界面与生命周期；应由正在使用 TransVortex 的 Agent 按自己的原生习惯建立适配。

## 什么时候创建适配

单次任务直接读取 [`README.md`](README.md) 并调用 CLI 即可。只有满足以下任一条件时才值得建立持久化适配：

- 用户会重复提交字幕、翻译、导出或环境诊断任务；
- Agent 需要在不同项目中稳定发现本机 TransVortex；
- 用户希望固定审批、进度跟踪或结果交付流程。

ASR 环境准备通常是一次性工作，不应仅因为要准备环境就创建 skill。

## 让 Agent 自己适配

1. 先识别自己支持的持久化机制，例如 skill、plugin、rules、项目指令或普通说明文件。
2. 读取稳定入口 `%LOCALAPPDATA%\TransVortex\Agent\README.md` 和同目录 `current.json`。
3. 执行 `capabilities_argv`，以当前版本返回的能力和命令为准。
4. 建立薄适配层，只记录稳定入口、任务选择规则、授权边界和结构化结果处理方式。
5. 不复制完整 CLI 手册、setup contract、大型 prompt、安装脚本或版本化绝对路径。
6. 用一次只读能力查询和一个无副作用命令验证适配；不要以生成文件成功代替 TransVortex 验证。

一个适配层应当能够在升级后重新读取 `current.json`，而不是绑定旧安装目录。若 Agent 没有持久化扩展机制，可直接保存稳定入口位置，按需搜索文档。

## 适配层应保留的边界

- 长任务使用 `--detach --json` 取得排队回执，再跟踪 events/status；回执不是最终结果。
- 参数按 `argv` 数组传递，不拼接未经转义的 shell 命令。
- 不缓存或转发 secret，不读取 `auth.json` 内容。
- 不把只读 plan 当成 apply，也不发明未被 `agent-info` 广告的命令。
- 不在未经确认时进行网络请求、媒体上传、付费调用、安装、删除、驱动修改或管理员操作。
- Web-only Agent 只能生成交接说明，不能声称已检查或修改本机。

## 推荐的最小内容

持久化适配通常只需要包含：

```text
Product: TransVortex
Stable entry: %LOCALAPPDATA%\TransVortex\Agent\README.md
Discovery: read current.json, then execute capabilities_argv as an argv array
Protocol: JSON/JSONL only; follow current documents.usage
Safety: no secret reads; require explicit authorization for mutation/network/media/cost
```

其余细节留在当前安装的版本化文档和机器可读契约中，由 Agent 在任务需要时读取。
