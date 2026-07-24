# TransVortex Agent Usage

当前 Agent / CLI 手册位于 [`agent/AGENT_USAGE.md`](agent/AGENT_USAGE.md)。

仓库与安装包共同使用 `agent/` 中的版本，避免打包复制后出现两份不同的说明。Agent 应从 [`agent/README.md`](agent/README.md) 开始，并在正式安装中优先读取 `%LOCALAPPDATA%\TransVortex\Agent\current.json` 给出的绝对文档路径和 `argv` 数组。
