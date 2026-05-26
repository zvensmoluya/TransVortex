import type { ServiceConnection, ServiceKind } from "../domain/serviceConnection";

type RawProvider = Record<string, unknown>;

export function providerConfigsToServiceConnections(payload: unknown, kind: ServiceKind = "translation"): ServiceConnection[] {
  const providers = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { providers?: unknown[] })?.providers)
      ? (payload as { providers: unknown[] }).providers
      : [];

  return providers.map((provider, index) => providerConfigToServiceConnection(provider, kind, index === 0));
}

export function providerConfigToServiceConnection(provider: unknown, kind: ServiceKind, isDefault = false): ServiceConnection {
  const raw = (provider ?? {}) as RawProvider;
  const name = stringValue(raw.name) || "unknown";
  const hasKey = raw.has_key === true;

  return {
    id: `${kind}-${name}`,
    kind,
    providerName: name,
    displayName: stringValue(raw.display_name) || name,
    model: firstString(raw.models),
    credentialStatus: {
      state: hasKey ? "saved" : "missing",
      source: hasKey ? "user_auth_file" : undefined,
      label: hasKey ? "凭据已保存" : "缺少凭据",
    },
    connectionStatus: {
      state: "untested",
      label: "尚未测试",
    },
    isDefault,
    fallbackTargets: [],
    expertConfigAvailable: true,
  };
}

function firstString(value: unknown): string | undefined {
  return Array.isArray(value) ? value.find((item) => typeof item === "string") : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
