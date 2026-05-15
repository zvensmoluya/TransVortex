# TransVortex Agent Instructions

## Language

- 与用户交流默认使用中文。
- 代码、命令、commit title、技术标识符默认使用英文。
- Commit body 可以使用中文，尤其用于说明设计背景、取舍和验证结果。
- 所有面向用户或协作者可见的中文内容必须按 UTF-8 读写和输出，避免在日志、文档、命令输出总结或提交信息中出现乱码中文。
- 在 PowerShell 中读取中文文件时优先显式使用 `-Encoding utf8`；运行可能输出中文或 Unicode 的 Python CLI 时优先设置 `PYTHONIOENCODING=utf-8`。

## Commit Policy

- 不要在用户未要求时主动提交。
- 提交前必须检查 `git status` 和 staged 范围。
- Commit title 使用简洁英文，优先使用祈使句或清晰的动词短语。
- 避免 `fix`、`update`、`wip`、`changes` 这类过短或信息量不足的提交信息。
- 本项目没有 PR 流程，commit body 必须包含足够上下文：
  - 为什么改
  - 改了哪些范围
  - 做了哪些验证
  - 是否有后续风险或限制
- 提交时务必检查 commit body 是否是真实换行，不要把 `\n` 作为字面量写进提交信息；在 PowerShell 里优先用 here-string 和 `git commit -F`。
- 写入 commit message 文件时必须避免 UTF-8 BOM；PowerShell 中优先用 `.NET UTF8Encoding($false)`，提交后用 `git log -1 --format=%B` 检查标题没有不可见字符。
- 不得提交 `.env`、`auth.json`、API key、token 或任何 secret。

## Commit Message Format

Use this shape:

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

If there is no known follow-up risk, write `风险/后续：无已知风险。`

## Credentials

- 默认凭据方案是用户级 `~/.transvortex/auth.json`；`.env` 只作为开发兼容 fallback。
- Provider YAML 只能保存 `env_key`、`credential_id`、endpoint、model 等非敏感配置。
- CLI、桌面端、doctor、provider test/models、ASR preflight 都应使用统一 credential resolver。

## PowerShell

- 当前 shell 是 PowerShell 时优先使用 PowerShell 原生命令，不要套用 Bash heredoc、`cat > file`、`&&` 等写法。
- 移动、删除、重命名文件时优先使用 `-LiteralPath`；非平凡命令后用 `git status`、`git log` 或文件检查确认结果。

## Validation

- Python 改动优先跑相关 pytest；较大改动跑全量 `pytest -q`。
- 桌面 UI 或 worker protocol 改动至少跑 `npm run build`；Tauri/Rust 改动至少跑 `cargo check`。
- 最终回复必须说明实际跑过的验证命令和结果。
