# TransVortex Agent Instructions

## Language

- 与用户交流默认使用中文。
- 代码、命令、commit title、技术标识符默认使用英文。
- Commit body 可以使用中文，尤其用于说明设计背景、取舍和验证结果。

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
- 不得提交 `.env`、`auth.json`、API key、token 或任何 secret。

## Commit Message Format

Use this shape:

```text
Short English title

中文说明：为什么需要这次改动，以及主要设计取舍。

改动范围：
- ...

验证：
- ...

风险/后续：
- ...
```

If there is no known follow-up risk, write `风险/后续：无已知风险。`

## Credentials

- 默认凭据方案是用户级 `~/.transvortex/auth.json`。
- `.env` 只作为开发兼容 fallback，不作为常规主路径。
- Provider YAML 只能保存 `env_key`、`credential_id`、endpoint、model 等非敏感配置。
- CLI、桌面端、doctor、provider test/models、ASR preflight 都应使用统一 credential resolver。

## Validation

- Python 改动优先跑相关 pytest；较大改动跑全量 `pytest -q`。
- 桌面 UI 或 worker protocol 改动至少跑 `npm run build`；Tauri/Rust 改动至少跑 `cargo check`。
- 最终回复必须说明实际跑过的验证命令和结果。
