# ASR Environment Setup Workflow

这是一次性的 Agent 工作流，用于准备、修复或诊断 TransVortex ASR 环境。它不是通用 skill，也不是可直接执行的大型 prompt。

## 1. 确认本机能力

先说明当前 Agent 是否能够访问目标 Windows 文件系统、运行进程并向用户请求命令授权。不能访问本机的 Agent 只能生成交接说明，不能声称已经发现、安装或验证任何资源。

读取稳定入口和 `current.json`，执行其中的 `capabilities_argv`。所有后续命令优先使用能力响应或 setup contract 返回的 `argv` 数组。

## 2. 只读发现

执行当前能力广告的只读命令，通常包括：

- `asr setup-plan --json`
- `doctor --json`
- 最终的 `asr setup-verify --json --strict`

`setup-plan` 生成 `transvortex.agent_setup` 契约，但不会安装资源、写配置、调用 `pip`、修改驱动或访问网络。`ok: true` 只表示契约生成成功；只有 `ready: true`、`plan_status: "ready"` 且没有 blocking item 才表示当前计划无需处理。

发现范围包括当前 ASR route、运行组件、模型、GPU/驱动、磁盘、已登记的外部环境和安全的 provider 元数据。只记录 endpoint、model、`env_key`、`credential_id` 等元数据，不读取或输出 API key、token、密码或 `auth.json` 内容。

## 3. 形成计划并等待确认

根据证据选择路线。路线尚未确认时保持 `route: null`，并给出有排名的 alternatives；不要为了完成流程而猜测。路线边界见 [`../references/provider-modes.md`](../references/provider-modes.md)。

计划至少列出：

- 精确组件、模型、revision、路径、大小和 SHA-256；
- 每个 action 是否写入、联网、上传媒体、产生费用、需要管理员或重启；
- 预期输出、失败处理和 rollback；
- 计划 ID 或可复核摘要。

安装、下载、配置写入、网络探针、媒体上传、费用、删除、覆盖、驱动修改和管理员操作必须得到对应范围的明确确认。状态、路径、哈希、费用或权限发生变化时，原确认失效，需要重新规划。

## 4. 只调用已广告的应用入口

只执行 TransVortex 当前能力明确广告、且已被用户批准的操作。当前 `setup-plan` 和 `setup-verify` 都是只读命令，不是 apply；没有 CLI apply 时，使用 Flutter 原生向导或当前版本提供的 Local Service 能力，不要自行拼接安装命令。

禁止全局 `pip install`、修改系统 Python、使用未固定 URL、执行不受信脚本、静默改变 NVIDIA 驱动，或移动、覆盖、删除用户已有模型和环境。复用外部模型时保持源目录只读。

本地或远程 ASR route probe 是独立网络操作。本地服务至少需要网络确认；远程 provider 还需要媒体上传与费用确认。不要用翻译 provider 的离线 `probe-provider` 代替 ASR route probe。

## 5. 由 TransVortex 验证

应用完成后重新执行 contract 返回的 strict verify `argv`、`doctor --json`，以及与路线匹配且已授权的最小 probe。对于 local worker，strict verify 可能在本机启动已选 runtime、加载模型并识别生成的短音频，但不访问网络。

只有以下条件全部满足才能返回 `ready`：

- 配置中的 route 与批准计划一致；
- 受管组件标记、模型 revision 和适用的 SHA-256 校验通过；
- readiness 表示可运行；
- 最小 probe 使用预期 runtime、protocol、device、compute type 和 model；
- 外部模型目录未被修改；
- 失败使用非成功状态和可操作的结构化错误表示。

如果需要用户选择或额外授权，返回 `needs_user`；Agent 无法访问本机、资产不可信或能力未广告时返回 `blocked`；批准的操作实际失败时返回 `failed`。不要以下载完成、Python 可导入或 Agent 自己的文字判断替代验证。

完整 contract 形状见 [`../references/setup_contract.schema.json`](../references/setup_contract.schema.json)。
