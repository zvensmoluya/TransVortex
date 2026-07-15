# TransVortex Agent Instructions

## Language

- 与用户交流默认使用自然、清楚的中文。
- 解释或修改产品行为时，区分用户能理解的产品概念与代码实现字段；发现命名或 UI 文案可能误导用户时应明确指出。
- 代码、命令、commit title 和技术标识符默认使用英文；commit body 可以使用中文说明背景、取舍和验证结果。
- 中文内容统一使用 UTF-8。PowerShell 读取中文文件时使用 `-Encoding utf8`；Python CLI 可能输出 Unicode 时优先设置 `PYTHONIOENCODING=utf-8`。

## Repository Boundaries

- 当前文档入口是 `docs/README.md`，仓库级短期待办是 `docs/CURRENT_BACKLOG.md`；历史归档不建立新的兼容约束。
- 主体验前端是 Flutter（`desktop_flutter/`）。Tauri（`desktop/`）已冻结，不作为设计、验收或后端兼容目标，背景见 `desktop/FROZEN.md`。
- 后端契约由 CLI / Agent 与 Flutter Local Service 驱动；改后端不需要维持 Tauri RPC 形状或修复其已知降级。
- 唯一保留的 Tauri 护栏是 sidecar 以 `--no-pump` 启动，避免与 Python pump 抢同一 `artifacts_dir`；修改 runtime 队列或锁语义时需要一并检查。

## Credentials

- 默认凭据位于用户级 `~/.transvortex/auth.json`；`.env` 只作为开发兼容或本地调试兜底。
- Provider YAML 只能保存 `env_key`、`credential_id`、endpoint、model 等非敏感配置，不得保存 API key、token 或密码。
- CLI、桌面端、doctor、provider test/models 和 ASR preflight 应使用统一 credential resolver，不能形成不同的解析规则。
- 不在日志、提交、文档或回复中暴露 secret；示例使用 `YOUR_API_KEY`、`example-token` 等明显占位符。

## Commit Policy

- 只在用户明确要求时提交；用户只要求修改代码时不要顺手提交。
- 提交前检查 `git status` 和 staged 范围，并确认没有 `.env`、`auth.json`、API key、token 或其他 secret。
- Commit title 使用简洁英文，优先使用祈使句或清晰动词短语，避免 `fix`、`update`、`wip`、`changes` 等低信息标题。
- 本项目没有 PR 流程，commit body 应提供足够上下文，方便以后直接从 Git 历史理解改动。
- 简单文档、注释、配置说明、机械重命名或小修可使用“标题 + 一句 `说明：`”。
- runtime、协议、凭据、产品语义或跨模块行为等实质改动按实际内容使用以下结构：

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

- 只写有实际内容的段落，不使用“无 / N/A”占位；没有风险或后续时省略该段。
- Commit message 使用真实换行，不写字面量 `\n`。PowerShell 中优先用 here-string 和 `git commit -F`，消息文件使用无 BOM UTF-8。
- 提交后运行 `git log -1 --format=%B`，检查乱码、不可见字符和换行。

## PowerShell

- 当前 shell 是 PowerShell 时使用原生命令，不套用 Bash heredoc、`cat > file`、`&&` 或 `rm -rf`。
- 处理中文文件时显式使用 UTF-8；需要无 BOM UTF-8 时使用 `.NET UTF8Encoding($false)`。
- 移动、删除、覆盖或批量重命名时使用 `-LiteralPath` 并先确认目标范围。
- 非平凡操作后通过 `git status`、`git log`、文件内容或目录检查确认结果。

## Validation

- 验证范围与改动风险相匹配，不要求所有改动都跑完整测试。
- Python 改动优先跑相关 pytest；较大或影响核心流程的改动优先跑全量 `pytest -q`。
- 桌面 UI 或 worker protocol 改动默认在 `desktop_flutter/` 运行 `flutter analyze` 和 `flutter test`；较大或影响主流程时补 `flutter build windows`。
- 仅当主动修改冻结的 Tauri 前端时运行 `npm run build`；修改 `desktop/src-tauri` 时至少运行 `cargo check`。
- 凭据、provider、ASR 和翻译流程改动优先运行对应的最小验证命令或相关测试。
- 回复用户时说明已经验证的内容，以及未验证的原因和剩余风险；纯文档、注释或配置说明改动可以不跑代码测试。
