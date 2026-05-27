import { providerConfigsToServiceConnections } from "../adapters/providerAdapter";
import type { ServiceConnection, ServiceKind } from "../domain/serviceConnection";
import type { ServiceTarget } from "../domain/serviceConnection";
import type { ProviderModelsPayload, ProviderTestPayload } from "../types";
import { invokeCommand } from "./tauriClient";

export async function listServiceConnections(kind: ServiceKind = "translation"): Promise<ServiceConnection[]> {
  const payload = await invokeCommand<unknown>("get_config");
  return providerConfigsToServiceConnections(payload, kind);
}

export async function listAllServiceConnections(): Promise<ServiceConnection[]> {
  const payload = await invokeCommand<unknown>("get_config");
  return [
    ...providerConfigsToServiceConnections(payload, "translation"),
    ...providerConfigsToServiceConnections(payload, "asr"),
  ];
}

export async function getProviderConfig(): Promise<unknown> {
  return invokeCommand<unknown>("get_config");
}

export async function probeProvider(providerDraft: unknown): Promise<unknown> {
  return invokeCommand<unknown>("probe_provider", { providerDraft });
}

export async function saveProviderConfig(providerDraft: unknown, apiKey?: string, expectedVersion?: unknown): Promise<unknown> {
  return invokeCommand<unknown>("save_provider_config", {
    providerDraft,
    apiKey: apiKey || null,
    expectedVersion: expectedVersion || null,
  });
}

export async function testProviderConnection(providerDraft: unknown, model: string, apiKey?: string): Promise<unknown> {
  return invokeCommand<unknown>("test_provider_connection", {
    providerDraft,
    model,
    apiKey: apiKey || null,
  });
}

export async function fetchProviderModels(providerDraft: unknown, apiKey?: string): Promise<unknown> {
  return invokeCommand<unknown>("fetch_provider_models", {
    providerDraft,
    apiKey: apiKey || null,
  });
}

export async function saveProviderRouting(routing: unknown): Promise<unknown> {
  return invokeCommand<unknown>("save_provider_routing", { routing });
}

export function providerDraftFromConnection(connection: ServiceConnection): unknown {
  return connection.rawConfig ?? {
    name: connection.providerName,
    models: connection.model ? [connection.model] : connection.models,
    env_key: connection.envKey,
    credential_id: connection.credentialId,
  };
}

export async function testServiceConnection(connection: ServiceConnection, model?: string, apiKey?: string): Promise<ProviderTestPayload> {
  if (connection.kind !== "translation") {
    return {
      status: connection.credentialStatus.state === "missing" ? "FAIL" : "PASS",
      checks: [
        {
          name: connection.providerName,
          status: connection.credentialStatus.state === "missing" ? "FAIL" : "PASS",
          code: connection.credentialStatus.state === "missing" ? "asr_key_missing" : "asr_config_present",
          message: connection.credentialStatus.state === "missing" ? "missing ASR credential" : "ASR configuration is present",
          hint_zh: connection.credentialStatus.state === "missing" ? "请先保存云端 ASR 的 API key。" : "ASR 服务配置已具备，实际可用性会在任务或环境诊断中确认。",
        },
      ],
    };
  }
  return testProviderConnection(providerDraftFromConnection(connection), model ?? connection.model ?? connection.models[0] ?? "", apiKey) as Promise<ProviderTestPayload>;
}

export async function fetchModelsForConnection(connection: ServiceConnection, apiKey?: string): Promise<ProviderModelsPayload> {
  const payload = await fetchProviderModels(providerDraftFromConnection(connection), apiKey);
  return payload as ProviderModelsPayload;
}

export async function saveProviderModelList(connection: ServiceConnection, models: string[], apiKey?: string): Promise<unknown> {
  const draft = {
    ...(providerDraftFromConnection(connection) as Record<string, unknown>),
    models,
  };
  return saveProviderConfig(draft, apiKey);
}

export async function saveDefaultAndFallbackModels(primary: ServiceTarget, fallbackTargets: ServiceTarget[] = []): Promise<unknown> {
  return saveProviderRouting({
    primary: { provider: primary.providerName, model: primary.model ?? "" },
    fallback: fallbackTargets
      .filter((target) => target.providerName && target.model)
      .map((target) => ({ provider: target.providerName, model: target.model })),
  });
}
