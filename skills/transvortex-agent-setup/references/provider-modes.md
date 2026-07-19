# TransVortex ASR route reference

Use this file after discovery when an Agent must explain or choose an ASR route. The repository's [AGENT_USAGE.md](../../../AGENT_USAGE.md) remains the source of truth for CLI syntax and task artifacts. If a command or field is not advertised by `agent-info --json`, do not invent it; return `blocked` with a concrete compatibility note.

## Route decision

| Route | Data path | Strength | Main caveat |
| --- | --- | --- | --- |
| `managed` | TransVortex user data -> pinned local runtime/model | Reproducible and supported by the desktop app | Large download; CUDA still depends on a compatible NVIDIA driver |
| `reuse_model` | Existing model directory loaded by a supported runtime | Avoids a second multi-GB model download | The source directory must remain user-owned and unchanged; compatibility must be probed |
| `local_service` | TransVortex -> localhost ASR endpoint | Reuses a user's running FunASR or compatible server | Endpoint lifecycle and protocol differences must be explicit |
| `remote_provider` | TransVortex -> hosted transcription endpoint | No local model or GPU required | Network, quota, cost, privacy, and credentials need user consent |
| `cli_external` | CLI/Agent -> user's explicit Python environment | Useful for development and existing automation | Not the default Flutter product path; provenance and upgrades are user responsibility |

## Managed Whisper

Use only the current TransVortex component catalog or a contract snapshot produced by TransVortex. The plan should identify:

- runtime component and version;
- accelerator component and version, if CUDA is selected;
- model ID, revision, expected file list, sizes, and SHA-256 values;
- target user data root and cache location;
- selected `device` and `compute_type`.

Install components in the user-scoped TransVortex data directory. Do not use the system Python, the repository virtual environment, or an unpinned `pip install`. A complete `.part` cache may be reused only after size and hash validation. A successful download is not a successful installation until readiness and a minimal transcription probe pass.

The NVIDIA driver is a system dependency. Installing user-space CUDA libraries does not install, upgrade, or repair the driver. If the driver is missing or incompatible, stop with `needs_user` and describe the approved driver path and possible reboot.

## Reusing an existing model

Use `reuse_model` only after read-only discovery identifies a plausible Faster-Whisper/CTranslate2 model directory. The Agent must:

1. Ask the user to confirm the path if discovery found more than one candidate.
2. Check that required model files are readable and that the directory has no unsafe reparse/link escape.
3. Compute a fingerprint or the exact file hashes required by the advertised probe.
4. Run TransVortex's supported environment/model probe with the intended device and compute type.
5. Register only metadata (path, model ID/revision if known, file fingerprint, probe timestamp).

Never copy, move, delete, rename, upgrade, or write into the source model directory. If it changes later, mark the registration stale and ask for a new probe. Do not claim that an arbitrary model format is compatible merely because its folder name contains `whisper`.

## Local ASR service

Use `local_service` only for a server bound to a loopback address. Configure any LAN or public endpoint as `remote_provider`, because media leaves the local process boundary. The configuration must state:

- endpoint and protocol (`funasr_openai`, `openai_transcriptions`, or another advertised protocol);
- model identifier;
- whether authentication is `none`, an environment key, or a credential ID;
- health/readiness behavior and timeout.

Treat localhost FunASR as a local/self-hosted provider, not a cloud provider. Check endpoint reachability and protocol shape before sending media. A health check alone is insufficient; use the smallest provider probe supported by the server. Do not start an untrusted binary or silently install a server as part of discovery.

## Remote provider

Use `remote_provider` when the user intentionally chooses a hosted ASR endpoint. Keep provider YAML limited to endpoint, model, `env_key`, and `credential_id`; resolve actual secrets through TransVortex's user-level credential store. Validate those fields offline first. The current ASR connection probe uploads generated media, so request separate network, media, and cost confirmation before running it.

The report may include provider name, endpoint host, model ID, protocol, status code, and latency, but never API keys, authorization headers, full request bodies, or sensitive response text. A valid translation provider does not prove that an ASR provider is configured; test the selected ASR provider separately.

## External Python / CLI compatibility

`cli_external` is a compatibility route for an explicit user path or development workflow. Record the executable path, executable hash, Python version, package versions, model path, device, and probe result. Do not silently promote it to the Flutter managed runtime. If the desktop application does not advertise external runtime support, keep the result CLI-only and explain the boundary.

## Failure handling

Return a structured state rather than guessing:

- `needs_user`: a choice, secret setup, administrator approval, reboot, cost approval, or path confirmation is required;
- `blocked`: the current Agent cannot access the machine, the command is not advertised, the asset is unpublished/untrusted, or a safety check cannot be satisfied;
- `failed`: an approved action ran but returned an error; preserve its JSON diagnostics and do not retry destructive steps automatically;
- `ready`: the selected route passed TransVortex readiness and the minimal probe.

When multiple routes are viable, leave the current working route unchanged and present a ranked plan. A setup Agent is an assistant, not the authority that changes the user's provider silently.
