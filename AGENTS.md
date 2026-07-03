# TransVortex Agent Instructions

## Language and Communication

- 与用户交流默认使用自然中文。
- 面向用户解释问题、方案、设计取舍和验证结果时，优先使用清楚、可理解的中文。
- 不要为了显得“技术化”而把内部实现名直接当作主要表述。
- 也不要为了追求纯中文而翻译代码标识符、配置项、类名、函数名、文件名、命令、包名或 API 名称。
- 当英文词是项目里的真实命名时，可以保留英文原文，但应说明它在当前语境里的中文含义。
- 优先先说用户能理解的中文概念，再补充对应的代码名。
- 如果一句话里连续出现多个英文实现名，应改成“中文解释 + 必要代码名”的形式，避免用户需要自己翻译整句话。
- 代码、命令、commit title、技术标识符默认使用英文。
- Commit body 可以使用中文，尤其用于说明设计背景、取舍和验证结果。
- 所有面向用户或协作者可见的中文内容必须按 UTF-8 读写和输出，避免乱码。
- 在 PowerShell 中读取中文文件时优先使用 `-Encoding utf8`。
- 运行可能输出中文或 Unicode 的 Python CLI 时，优先设置 `PYTHONIOENCODING=utf-8`。



## Technical Naming

- 如果英文是代码里的真实名字，保留英文，不要擅自翻译成另一个名字。
- 如果英文只是普通表达，优先改成自然中文。
- 同一个概念第一次出现时，可以使用“中文解释 + 英文原名”的形式。
- 后续如果语境清楚，可以直接使用中文，必要时再补充英文名。
- `preset`、`runtime`、`bootstrap`、`memory`、`merge`、`patch` 这类项目内部词可以出现，但不要直接当作中文句子的主干。
- 这些词出现时应服务于解释代码，而不是替代解释。

涉及术语记忆相关逻辑时，可优先使用这些表达：

| Code / English term | 中文表达建议 |
| --- | --- |
| `memory` | 术语记忆 / 翻译记忆，视上下文而定 |
| `memory subsystem` | memory 子系统 / 术语记忆子系统 |
| `preset` | 预设术语表 |
| `selected preset` | 用户选择的预设术语表 |
| `runtime memory` | 运行时术语库 |
| `translation_memory.json` | 运行时术语库文件 `translation_memory.json` |
| `bootstrap` | 初始化术语记忆 / 自动生成初始术语记忆 |
| `merge` | 合并 |
| `patch` | 修改补丁 / 模型生成的修改建议 |
| `protected entries` | 受保护条目 / 受保护的人工术语 |
| `effective memory` | 最终生效的术语记忆 |

这些只是表达建议，不是强制替换表。实际回复以清楚、准确、自然为优先。

## Product Semantics

解释产品行为时，要区分“用户能理解的产品概念”和“代码里的实现概念”。

例如：

- “启用术语记忆能力”不一定等于“启用整个 memory 子系统”。
- “用户选择的预设术语表”不等于“模型运行时自动积累的术语库”。
- “人工术语有更高优先级”不等于“产品配置语义已经足够清楚”。
- “当前实现能工作”不等于“命名和用户理解一致”。

如果配置名、字段名或 UI 文案容易让用户误解，应明确指出问题，并给出更清楚的命名或拆分建议。

## Frontend Strategy

主体验前端是 Flutter（`desktop_flutter/`）。Tauri（`desktop/`）已冻结为参考实现，不作为兼容约束（背景见 `desktop/FROZEN.md`）。

- 后端契约只由 CLI / Agent 与 Flutter Local Service 驱动；改后端不需要保 Tauri 可用，也不必为它保留 RPC 形状或修复其已知降级。
- 保留唯一护栏：Tauri sidecar 以 `--no-pump` 启动，避免与 Python pump 抢同一 `artifacts_dir`；改 runtime 队列 / 锁语义时一并考虑。
- 后端 runtime / 协议改动以 Python 测试为准；仅当主动改 `desktop/src-tauri` 时才跑 `cargo check`。

## Commit Policy

- 不要在用户未要求时主动提交。
- 如果用户只要求修改代码，不要顺手提交。
- 提交前必须检查 `git status`，确认工作区状态和 staged 范围符合预期。
- 提交前必须确认没有提交 `.env`、`auth.json`、API key、token 或任何 secret。
- Commit title 使用简洁英文，优先使用祈使句或清晰的动词短语。
- 避免 `fix`、`update`、`wip`、`changes` 这类过短或信息量不足的提交信息。
- 本项目没有 PR 流程，commit body 应包含足够上下文，方便以后直接从 git 历史理解这次改动。
- Commit body 优先说明为什么改、改了哪些范围、做了哪些验证、是否有后续风险或限制。
- 提交时检查 commit body 是否是真实换行，不要把 `\n` 作为字面量写进提交信息。
- 在 PowerShell 中写多行 commit message 时，优先使用 here-string 和 `git commit -F`。
- 写入 commit message 文件时避免 UTF-8 BOM。
- 提交后用 `git log -1 --format=%B` 检查提交信息，确认没有乱码、不可见字符或错误换行。

## Commit Message Format

Commit body 要想过四个维度——为什么改（说明）、改了哪些范围、做了哪些验证、有什么风险或后续——但**只写有内容的维度，空的直接省略**，不写「无 / N/A」占位。

按改动分量选格式：

- **简单改动**（文档、注释、配置说明、机械重命名、小修）：标题 + 一句 `说明：` 即可，不套多段。
- **实质改动**（runtime、协议、凭据、产品语义、跨模块行为）：用下面的完整结构，此时「验证」「风险/后续」通常真有内容，应写清。

```text
Short English title

说明：为什么需要这次改动，以及主要设计取舍。

改动范围：
- ...

验证：
- ...

风险/后续：
- ...
```

「风险/后续」段只在**真有风险**、或需要**声明已排查确认无风险**（如凭据、数据安全类改动）时才写；否则省略，不为凑格式写「无已知风险」。

## Credentials

- 默认凭据方案是用户级 `~/.transvortex/auth.json`。
- `.env` 只作为开发兼容方案或本地调试兜底，不应作为主要凭据来源。
- Provider YAML 只能保存非敏感配置，例如 `env_key`、`credential_id`、endpoint、model 等。
- Provider YAML 不得保存 API key、token、密码或其他 secret。
- CLI、桌面端、doctor、provider test/models、ASR preflight 都应使用统一 credential resolver。
- 修改凭据相关逻辑时，应保持各入口行为一致，避免 CLI 和桌面端出现不同的凭据解析规则。
- 不要在日志、提交信息、文档或回复中暴露 token、API key、认证文件内容或其他 secret。
- 示例配置必须使用明显占位符，例如 `YOUR_API_KEY` 或 `example-token`。

## PowerShell

- 当前 shell 是 PowerShell 时，优先使用 PowerShell 原生命令。
- 不要在 PowerShell 中套用 Bash 写法，例如 Bash heredoc、`cat > file`、`&&`、`rm -rf`。
- 移动、删除、重命名文件时优先使用 `-LiteralPath`。
- 处理中文文件时优先显式使用 UTF-8 编码。
- 读取中文文件时优先使用 `Get-Content -Encoding utf8`。
- 写入多行文本时优先使用 here-string，必要时配合明确编码的写入方式。
- 需要写入无 BOM UTF-8 文件时，优先使用 `.NET UTF8Encoding($false)`。
- 非平凡命令执行后，应通过 `git status`、`git log`、文件内容检查或目录检查确认结果。
- 涉及删除、覆盖、批量移动或重命名时，应先确认目标范围。

## Validation

- 不要求任何改动都跑完整测试。
- Python 改动优先跑相关 pytest。
- 较大的 Python 改动，或影响核心流程的改动，优先跑全量 `pytest -q`。
- 桌面 UI 或 worker protocol 改动默认跑 `flutter analyze` 和 `flutter test`（工作目录 `desktop_flutter/`）；较大或影响主流程的改动补 `flutter build windows`。
- 仅当主动改冻结的 Tauri 前端（`desktop/`）时才跑 `npm run build`；日常桌面改动不必构建它。
- Tauri/Rust 改动（仅当主动改 `desktop/src-tauri` 时）至少跑 `cargo check`。
- 凭据、provider、ASR、翻译流程相关改动，应优先跑对应的最小验证命令或相关测试。
- 如果没有跑测试，应明确说明原因。
- 回复用户时说明已经验证的内容，以及未验证但存在风险的部分。
- 如果改动只涉及文档、注释或配置说明，可以说明未跑测试的理由。

## Response Quality

- 不要只复述代码行为，要主动解释它对产品语义、用户体验或维护成本的影响。
- 不要过度使用英文缩写和内部术语。
- 如果必须使用英文术语，确保用户不需要猜它是什么意思。
- 如果用户的理解方向是对的，但表述需要更精确，应先肯定核心判断，再补充边界。
- 如果发现当前实现和用户预期不一致，应明确区分实际行为、用户可能的理解、以及需要改名或调整的地方。
- 不要为了显得完整而输出很长但信息密度低的回答。
- 如果任务只能部分完成，应明确说明已完成部分和未完成部分。
- 如果发现兼容性、迁移、配置语义或用户数据安全风险，应主动指出。
