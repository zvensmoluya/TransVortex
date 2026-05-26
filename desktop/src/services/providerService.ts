import { providerConfigsToServiceConnections } from "../adapters/providerAdapter";
import type { ServiceConnection, ServiceKind } from "../domain/serviceConnection";
import { invokeCommand } from "./tauriClient";

export async function listServiceConnections(kind: ServiceKind = "translation"): Promise<ServiceConnection[]> {
  const payload = await invokeCommand<unknown>("get_config");
  return providerConfigsToServiceConnections(payload, kind);
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
