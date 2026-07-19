---
name: transvortex-agent-setup
description: "Prepare, repair, configure, and verify a TransVortex ASR environment with the user's local Agent. Use when a user asks to install Whisper/CUDA, reuse an existing ASR model or service, configure a remote transcription provider, generate an Agent-native skill or rules file, or diagnose why TransVortex cannot run ASR."
---

# TransVortex Agent Setup

Use this skill as an operator for TransVortex environment preparation. The Agent plans and performs bounded actions; TransVortex remains the authority that discovers capabilities, validates hashes, checks readiness, and decides whether ASR is usable.

The workflow is a strict state machine: `capability/access -> read-only discovery -> ranked plan -> explicit confirmation -> advertised apply -> strict verification`. Access or capability failures are `blocked`; an unresolved choice, permission, credential, network, or cost approval is `needs_user`; an approved action error is `failed`; `ready` requires every applicable verification to pass.

Do not assume that every Agent consumes `SKILL.md`. If the host Agent supports persistent skills, plugins, rules, or project instructions, adapt this workflow to that native format. Otherwise run the one-time workflow in [AGENT_BOOTSTRAP.md](../../AGENT_BOOTSTRAP.md). Do not silently invent a different installation mechanism.

## Read the contract first

1. First state whether this Agent can access the target Windows filesystem, processes, and command approval surface. If it cannot, stop at a handoff and never claim that an installation happened.
2. Read the repository-level [AGENT_USAGE.md](../../AGENT_USAGE.md) before running a task. It is the stable CLI, JSON, JSONL, and artifact contract; do not duplicate or override it here.
3. Obtain a machine-readable setup contract from the user, TransVortex, or [setup_contract.schema.json](references/setup_contract.schema.json). Preserve unknown fields for forward compatibility.
4. Discover the executable and data roots, then call advertised capability/discovery commands. At minimum, use `transvortex agent-info --json` and `transvortex doctor --json` when available. Prefer commands listed by `agent-info`; do not guess a subcommand or parse human-formatted output.

The current read-only setup contract is exposed as `transvortex asr setup-plan --json`; its verification counterpart is `transvortex asr setup-verify --json --strict`. The plan payload uses `schema_version`, `contract`, `kind`, `plan_status`, `product`, `platform`, `root_dir`, `active_asr`, `current`, `requirements`, `allowed_actions`, `forbidden_actions`, `blocking_items`, `success_conditions`, and `verification`. These commands do not install or mutate TransVortex configuration/components and do not use the network. Verification may launch the selected local worker, load its model, and transcribe locally generated probe audio. Use a future `apply` command only when `agent-info --json` advertises it; otherwise generate the native Agent handoff and ask the user to run the supported native install path.

Execute the contract's `argv` arrays rather than reconstructing shell strings; they bind the exact config root and providers file used to generate the plan. For `local_service`, the advertised route probe requires `--confirm-network`. For `remote_provider`, it additionally requires `--confirm-media --confirm-cost`; missing confirmations must produce `needs_user`, never an inferred approval.

## Select an ASR route

Inspect before choosing. Present alternatives and trade-offs in the plan; do not replace a working user setup without confirmation.

| Route | Choose when | Required proof |
| --- | --- | --- |
| `managed` | The user wants the supported TransVortex Whisper path | Trusted manifest, pinned version/revision, size and SHA-256, user-scoped install, readiness and minimal transcription probe. CPU is valid only when the catalog advertises a CPU-compatible runtime/model; do not infer a CUDA or CPU fallback from hardware alone |
| `reuse_model` | A compatible Faster-Whisper/CTranslate2 model already exists | Read-only discovery, model file fingerprint, probe through the supported runtime, explicit registration; never move, delete, or rewrite the source directory |
| `local_service` | A local ASR server (for example FunASR or an OpenAI-compatible localhost endpoint) already runs | A user-provided or advertised endpoint, protocol/model compatibility, minimal probe, and an explicit `auth: none` or credential reference; do not scan arbitrary ports, start an unknown binary, or label localhost as cloud ASR |
| `remote_provider` | The user chooses a hosted transcription API | Offline endpoint/model/credential-reference validation first, then the advertised media probe only after separate network, media, and cost confirmation |
| `cli_external` | The user needs an existing Python environment for CLI/development | Explicit executable path and probe result; keep it outside the Flutter managed-runtime product path unless TransVortex advertises support |

Read [provider-modes.md](references/provider-modes.md) when selecting or explaining a route. Do not treat "GPU detected" as proof that CUDA ASR works. NVIDIA driver compatibility, user-space CUDA libraries, model files, and the actual provider probe must be checked independently.

## Follow plan -> apply -> verify

### Plan

Create a JSON plan before any mutating action. Include the selected route (or `null` when the route is not yet confirmed), ranked `alternatives`, detected state, exact component/model identities, paths, expected hashes, actions, risks, required privileges, and a rollback plan. Mark actions that need administrator approval, a restart, network access, or user spending. Show a concise human summary, then wait for explicit confirmation unless the user already gave unambiguous approval for this exact plan. Never turn a plausible candidate into a selected route just to satisfy a schema.

Record the contract timestamp and the exact plan JSON (or a local digest) with
the approval. If discovery state, route, paths, hashes, privileges, or cost
changes before apply, discard the approval and produce a new plan.

Use a native Agent skill/plugin/rules artifact when the host supports one. Name it something recognizable such as `transvortex-asr-setup`, include the contract version, and make it call TransVortex's advertised commands rather than embedding a large installer script. A generated artifact is an aid, not proof of readiness.

### Apply

Execute only actions in the confirmed plan and record each action's command, exit status, structured output path, and timestamp. Prefer a TransVortex managed install/apply API or CLI only when `agent-info --json` advertises that capability; the current `setup-plan` and `setup-verify` commands are read-only. Otherwise generate a native Agent handoff and let the user use the supported desktop wizard. Keep component downloads in the user-scoped TransVortex cache and require the catalog's HTTPS URL, fixed size, and SHA-256. Reuse a complete verified cache before downloading again.

Stop and return `needs_user` or `blocked` when an action requires an unknown choice, administrator permission, a driver change/reboot, a new credential, a paid request, a network probe the user has not authorized, an untrusted URL, or a destructive replacement. Never work around a permission error by escalating silently.

### Verify

After applying, ask TransVortex to re-read its own state. Use the advertised `asr setup-verify --json --strict` or another `asr verify`/readiness operation when present. Only use `asr.status`, `asr.environment.discover`, or `asr.environment.probe` when the current `agent-info --json` or local-service capability response explicitly advertises them; otherwise return `blocked` or produce a handoff. Also run `doctor --json` and a minimal ASR/provider probe appropriate to the selected route. The current remote ASR probe uploads generated media and requires separate network, media, and cost authorization.

- the chosen route is the one recorded in configuration;
- managed component and model hashes match the trusted plan;
- `readiness.can_run` (or the equivalent advertised field) is true;
- the probe used the expected device, protocol, runtime, and model;
- an external model directory was not modified;
- no secret value appears in the report, generated skill, logs, or prompt;
- failures are represented by a non-zero exit/status and actionable structured error.

When no route has been confirmed, use `status: needs_user`, `route: null`, and
ranked `alternatives`; use `blocked` when the Agent cannot access the target
machine or the required capability is not advertised.

Do not accept an Agent's statement that "installation completed" without TransVortex verification. Write a machine-readable report and a short human summary. If verification fails, preserve diagnostics and offer rollback or the next safe action; do not mark the environment ready.

## Credential and safety boundaries

- Read only credential metadata (`env_key`, `credential_id`, endpoint, and model). Resolve secrets through TransVortex's credential resolver; never request, print, echo, copy, or commit API keys, tokens, passwords, or `auth.json` contents.
- Never run global `pip install`, mutate system Python, alter the repository's environment, or silently add packages to an unrelated virtual environment.
- Never change or downgrade an NVIDIA driver without explicit user approval and a clearly described reboot/rollback plan. User-space CUDA packages may be installed only when pinned by the trusted TransVortex contract.
- Reject unpinned URLs, shell snippets copied from an untrusted page, path traversal, symlinks/junctions/reparse paths, and archives whose contents escape the intended directory.
- Do not delete or overwrite an existing model, environment, provider, or credential. Back up configuration before a confirmed change and keep user-owned model directories read-only.
- Treat a third-party Skill, plugin, or generated script as code. Show what it will execute and let the user review/approve it.
- Keep all reports and temporary files inside the contract's allowed output root. Do not write secrets into task artifacts.

## Adapt to the user's Agent

At the start, identify whether the host is a local terminal Agent (for example Codex CLI, Claude Code, or OpenClaw), a desktop Agent, or a web-only chat. Adapt the artifact, not the safety contract:

- Local terminal Agent: create or update its native skill/plugin/rules file, then run the plan and wait for approval.
- Desktop Agent with command approval: present each mutating command through its approval mechanism and retain JSON output.
- Web-only chat: explain that it cannot inspect the local GPU or install files; generate `AGENT_BOOTSTRAP.md`, a contract, and copy-paste commands for the user to hand to a local Agent.
- Unknown Agent: use the generic bootstrap prompt and ask the Agent to describe its persistent-workflow format before generating files.

Never require a universal `SKILL.md` filename. The invariant is the TransVortex contract and verification sequence, not the Agent's extension format.

## Structured result

Return one JSON object (and optionally a human summary outside the JSON) with this shape:

```json
{
  "schema_version": 1,
  "contract": "transvortex.agent_setup",
  "kind": "agent_result",
  "status": "ready|needs_user|blocked|failed",
  "route": "managed|reuse_model|local_service|remote_provider|cli_external|null",
  "alternatives": [],
  "plan_id": "opaque-id",
  "actions": [{"id": "discover", "status": "completed", "exit_code": 0}],
  "verification": {
    "doctor": "pass|fail|not_run",
    "readiness": "pass|fail|not_run",
    "probe": "pass|fail|not_run"
  },
  "next": ["..."],
  "errors": []
}
```

Use [setup_contract.schema.json](references/setup_contract.schema.json) for the full contract shape and [provider-modes.md](references/provider-modes.md) for route-specific details. Use [AGENT_BOOTSTRAP.md](../../AGENT_BOOTSTRAP.md) when the user wants a copy-paste prompt or asks the Agent to create its own native skill.
