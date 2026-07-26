# ASR Environment And Resource Setup

这是 TransVortex 交给本机 Agent 的一次性工作流。目标不是运行一遍通用诊断，而是由 Agent 侦查当前电脑，并按用户选择的范围准备、接入和验证 ASR 资源。

## 1. 读取当前契约

从稳定入口读取 `current.json`，执行其中的 `capabilities_argv`，再执行能力响应广告的 `asr setup-plan --json`。命令使用返回的 `argv` 数组，不依赖 `PATH`。

`setup-plan` 本身只读取状态。重点字段是：

- `provider_mode`：`local_worker`、`local_service` 或 `remote_provider`；
- `resources`：runtime、模型、GPU 加速、系统驱动和配置各自的来源、所有权与状态；
- `plan.actions[]`：操作、执行者、所有权以及 TransVortex 可执行命令；
- `blocking_items`：当前尚未满足的条件。

执行模式和资源来源是两件事。例如 `local_worker` 可以同时使用 TransVortex runtime、外部模型和外部 GPU 加速资源。

## 2. 遵守用户选择的范围

桌面端会明确交接以下一种范围：

- `inspect`：只侦查本机并给出方案；
- `prepare_model`：准备模型并接入；
- `prepare_accelerator`：准备 NVIDIA GPU 加速并接入；
- `register`：接入用户已经准备好的资源，不重新下载；
- `full`：把本地 ASR 准备到严格验证通过。

Agent 可以使用自己的本机工具、下载能力和环境知识完成范围内的工作。`setup-plan` 提供的是 TransVortex 接口与兼容目标，不限制 Agent 如何取得外部模型或 NVIDIA 用户态资源。

## 3. 分别处理资源

### Runtime

桌面产品的 `local_worker` 使用 TransVortex 管理的固定 faster-whisper runtime。通过计划广告的 `setup-apply --resource runtime` 安装。不要为普通用户另配 Python；外部 Python 仅保留为 CLI 和开发兼容状态，不是环境准备目标。

### 模型

模型有两种独立来源：

- `managed`：调用计划广告的 `setup-apply --resource model --item-id <model-id>`；
- `external`：Agent 自行下载、转换或定位兼容的 CTranslate2 Whisper 模型，然后调用 `model-probe` 或 `model-register`。

`model-register` 会由固定 runtime 实际加载模型并运行最小转录。Agent 可附加 `--label <display-name>` 写入面向用户的显示名称；它只修改登记元数据，不重命名或移动模型目录。成功结果中的 registration ID 再交给 `resources-activate --model-registration-id <id>`。TransVortex 只登记并使用外部目录，不接管其文件生命周期。

### GPU 加速

GPU 加速也有两种独立来源：

- `managed`：清单已发布时调用 `setup-apply --resource accelerator --item-id <accelerator-id>`；
- `external`：Agent 根据本机 GPU、驱动和当前兼容要求准备 NVIDIA 用户态库目录，然后调用 `accelerator-probe` 或 `accelerator-register`。

外部目录需要满足计划给出的兼容版本和 DLL 布局。`accelerator-register` 会用固定 runtime 真实执行 CUDA 探测；成功结果中的 registration ID 再交给 `resources-activate --accelerator-registration-id <id>`。显卡驱动属于系统资源，由 Agent 结合本机情况处理，不写入 TransVortex 资源目录。

### 配置

外部资源准备完成并不等于已经启用。使用能力契约广告的 `resources-activate` 修改活动 local worker 的资源引用。模型与加速资源可以分别激活，不要求来自同一来源；Agent 也可以通过同一命令的 `--device` 与 `--compute-type` 把侦查结果写回 local worker 配置。

## 4. 其他执行模式

`local_service` 和 `remote_provider` 不需要本地 runtime、模型或 CUDA 资源。按能力响应运行对应的 `provider-test`，不要把翻译服务的 `probe-provider` 当成 ASR provider 验证。具体边界见 [`../references/provider-modes.md`](../references/provider-modes.md)。

## 5. 由 TransVortex 收口验证

完成范围内的操作后，执行 contract 返回的：

```powershell
transvortex asr setup-verify --json --strict
```

对于 `local_worker`，该命令会检查配置与资源登记，启动所选 runtime，加载所选模型，并转录本机生成的短音频；使用 CUDA 时还会验证所选加速资源。它不访问网络。

只有 `ok: true` 才表示 TransVortex 已可使用。资源尚缺时继续返回 `needs_action`；需要改变用户选择时返回 `needs_user`；实际执行失败时保留结构化错误。不要用“文件已下载”或 Agent 自己的环境判断代替这一步。

完整数据结构见 [`../references/setup_contract.schema.json`](../references/setup_contract.schema.json)。
