# TransVortex ASR Provider Modes And Resource Sources

ASR 的执行位置与资源从哪里取得必须分别判断。先读 `setup-plan` 的 `provider_mode`，再看 `resources` 中每项的 `source`。

## 执行模式

| `provider_mode` | 执行位置 | 本地资源要求 |
| --- | --- | --- |
| `local_worker` | TransVortex 启动固定协议的本机 Whisper worker | 需要产品 runtime 和模型；GPU 加速可选 |
| `local_service` | TransVortex 调用 loopback ASR 服务 | 服务自行管理模型与运行环境 |
| `remote_provider` | TransVortex 调用远程转录服务 | 不需要本地模型或 GPU |

`provider_mode` 不因模型来自已有目录而改变。使用外部模型的本机识别仍然是 `local_worker`，不是一条 `reuse_model` 路线。

## Local Worker 资源

| 资源 | 产品来源 | 外部来源 | 接入方式 |
| --- | --- | --- | --- |
| runtime | `managed`，TransVortex 固定并安装 | 仅 CLI/开发兼容，不向普通用户推广 | 托管 `setup-apply` |
| model | `managed` | Agent 或用户准备的 CTranslate2 Whisper 目录 | `model-register` 后 `resources-activate` |
| accelerator | `managed` | Agent 或用户准备的兼容 NVIDIA 用户态库目录 | `accelerator-register` 后 `resources-activate` |
| NVIDIA driver | 不由 TransVortex 管理 | 系统资源，由 Agent 或用户按本机情况准备 | 由 CUDA probe 验证 |

模型和 accelerator 的来源互不绑定。以下组合都合法：

- 托管模型 + 托管 accelerator；
- 外部模型 + 托管 accelerator；
- 托管模型 + 外部 accelerator；
- 外部模型 + 外部 accelerator；
- CPU 模式，不使用 accelerator。

TransVortex 管理自己下载的资源。外部资源只保存路径、指纹、兼容信息和 probe 结果；应用删除资源、清理组件或卸载时不删除外部目录。目录内容变化后登记会失效，需要重新 probe/register。

## Local Service

`local_service` 用于 loopback 地址上的 FunASR 或兼容服务。模型、Python、CUDA 和服务生命周期都属于该服务，不混入 TransVortex local worker 的资源契约。使用服务自己的协议和模型标识，并用广告的 ASR `engine-test` 验证。

## Remote Provider

`remote_provider` 用于用户选择的托管转录端点。Engine YAML 只保存 endpoint、model、`binding_id` 和 `secret_ref` 等非敏感配置，凭据由统一 resolver 取得；`env_fallback` 只允许 canonical 官方 Endpoint 显式声明。当前 Engine probe 会发送生成的短音频，并可能产生服务费用。

## External Python Compatibility

显式外部 Python 环境仍可服务旧 CLI、自动化和开发验收，但它不是第四种 provider mode，也不是桌面 Agent 环境准备的资源选项。桌面设置保存 local worker 时恢复产品托管 runtime；Agent 应准备模型或 accelerator，而不是替用户拼装另一套 Python runtime。
