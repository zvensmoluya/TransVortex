# TransVortex Agent / CLI

这是 Agent 使用 TransVortex 的短入口。不要一次性加载全部文档；先取得当前安装的机器可读能力，再按任务读取对应资料。

## 找到当前安装

Windows 安装版提供稳定入口：

```text
%LOCALAPPDATA%\TransVortex\Agent\README.md
%LOCALAPPDATA%\TransVortex\Agent\current.json
```

先读取 `current.json`，再把其中的 `capabilities_argv` 作为参数数组直接执行。不要假设 `transvortex` 已加入 `PATH`，也不要把参数数组拼成 shell 字符串。

`current.json` 会给出当前版本的安装根、配置根、文档路径、CLI 参数前缀和能力查询命令。安装升级可能改变版本化文件，稳定入口路径不变。

在源码仓库中工作时，当前文件就是入口。使用当前 Python 环境执行：

```powershell
python -B -m transvortex.cli --root <config-root> agent-info --json
```

## 按任务继续

- CLI、JSON、JSONL、任务状态和产物约定：读取 `current.json` 的 `documents.usage`；仓库中对应 [`AGENT_USAGE.md`](AGENT_USAGE.md)。
- 需要为当前 Agent 建立长期复用入口：读取 [`ADAPTATION_GUIDE.md`](ADAPTATION_GUIDE.md)。
- 只做一次 ASR 环境准备或修复：读取 [`workflows/ASR_ENVIRONMENT_SETUP.md`](workflows/ASR_ENVIRONMENT_SETUP.md)。
- 需要解释 ASR 路线：读取 [`references/provider-modes.md`](references/provider-modes.md)。
- 需要校验 setup contract：读取 [`references/setup_contract.schema.json`](references/setup_contract.schema.json)。

Agent 可以直接使用 CLI，不要求先创建 skill、plugin 或 rules。只有在用户希望长期复用时，才按 Agent 自身的扩展习惯创建一个薄适配层。

## 不变量

- 只解析 JSON、JSONL 和明确的任务产物，不解析面向人的终端输出。
- 使用能力响应中的绝对路径和 `argv` 数组，不猜安装目录或子命令。
- 环境发现和计划不等于授权；网络、费用、媒体上传、安装、删除和系统级修改需要对应确认。
- 只处理 `env_key`、`credential_id`、endpoint、model 等非敏感元数据，不读取、输出或写入凭据值。
- 是否可用由 TransVortex 的结构化验证结果决定，不由 Agent 自行宣告。
