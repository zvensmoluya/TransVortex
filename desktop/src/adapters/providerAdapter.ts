import type { ServiceConnection, ServiceKind } from "../domain/serviceConnection";

type RawProvider = Record<string, unknown>;

export function providerConfigsToServiceConnections(payload: unknown, kind: ServiceKind = "translation"): ServiceConnection[] {
  const providers = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { providers?: unknown[] })?.providers)
      ? (payload as { providers: unknown[] }).providers
      : [];

  const routing = isRecord((payload as { routing?: unknown })?.routing) ? (payload as { routing: Record<string, unknown> }).routing : {};
  const primary = isRecord(routing.primary) ? routing.primary : {};
  const fallback = Array.isArray(routing.fallback) ? routing.fallback : [];

  const translationConnections = providers.map((provider, index) =>
    providerConfigToServiceConnection(
      provider,
      "translation",
      stringValue(primary.provider) ? stringValue((provider as RawProvider).name) === stringValue(primary.provider) : index === 0,
      fallback,
      stringValue(primary.model),
    ),
  );

  if (kind === "translation") {
    return translationConnections;
  }

  const pipeline = isRecord((payload as { pipeline?: unknown })?.pipeline) ? (payload as { pipeline: Record<string, unknown> }).pipeline : {};
  const activeAsrProvider = stringValue(pipeline.asr_provider);
  const rawAsrProviders = isRecord((payload as { asr_providers?: unknown })?.asr_providers)
    ? Object.values((payload as { asr_providers: Record<string, unknown> }).asr_providers)
    : [];
  const asrConnections = rawAsrProviders.filter(isRecord).map((provider, index) =>
    asrProviderConfigToServiceConnection(
      provider,
      activeAsrProvider ? stringValue(provider.name) === activeAsrProvider : index === 0,
    ),
  );

  return asrConnections;
}

export function providerConfigToServiceConnection(
  provider: unknown,
  kind: ServiceKind,
  isDefault = false,
  fallback: unknown[] = [],
  primaryModel?: string,
): ServiceConnection {
  const raw = (provider ?? {}) as RawProvider;
  const name = stringValue(raw.name) || "unknown";
  const hasKey = raw.has_key === true;
  const credentialSource = stringValue(raw.credential_source);
  const models = stringList(raw.models);
  const credentialId = stringValue(raw.credential_id) || name;

  return {
    id: `${kind}-${name}`,
    kind,
    providerName: name,
    displayName: stringValue(raw.display_name) || name,
    model: isDefault ? primaryModel || firstString(raw.models) : firstString(raw.models),
    models,
    credentialId,
    envKey: stringValue(raw.env_key),
    rawConfig: raw,
    credentialStatus: {
      state: hasKey ? "saved" : "missing",
      source: hasKey ? mapCredentialSource(credentialSource) : undefined,
      label: hasKey ? "凭据已保存" : "缺少凭据",
    },
    connectionStatus: {
      state: hasKey ? "connected" : "failed",
      label: hasKey ? "凭据可用" : "缺少凭据",
    },
    isDefault,
    fallbackTargets: fallback
      .filter(isRecord)
      .map((target) => ({ providerName: stringValue(target.provider) || "", model: stringValue(target.model) }))
      .filter((target) => target.providerName),
    expertConfigAvailable: true,
  };
}

function asrProviderConfigToServiceConnection(provider: RawProvider, isDefault: boolean): ServiceConnection {
  const name = stringValue(provider.name) || "asr-provider";
  const rawAuth = isRecord(provider.auth) ? provider.auth : {};
  const authType = stringValue(rawAuth.type) || "bearer";
  const hasKey = authType === "none" || provider.has_key === true || stringValue(provider.credential_source) !== "missing";
  const credentialSource = stringValue(provider.credential_source);
  const model = stringValue(provider.model);
  const providerKind = stringValue(provider.kind) || "remote";
  return {
    id: `asr-${name}`,
    kind: "asr",
    providerName: name,
    displayName: stringValue(provider.display_name) || asrDisplayName(name, providerKind),
    model,
    models: model ? [model] : [],
    credentialId: stringValue(rawAuth.credential_id) || stringValue(provider.credential_id) || name,
    envKey: stringValue(rawAuth.env_key) || stringValue(provider.env_key),
    rawConfig: provider,
    credentialStatus: {
      state: authType === "none" ? "notRequired" : hasKey ? "saved" : "missing",
      source: hasKey && authType !== "none" ? mapCredentialSource(credentialSource) : undefined,
      label: authType === "none" ? "无需凭据" : hasKey ? "凭据已保存" : "缺少凭据",
    },
    connectionStatus: {
      state: hasKey ? "untested" : "failed",
      label: hasKey ? "待测试" : "缺少凭据",
    },
    isDefault,
    fallbackTargets: [],
    expertConfigAvailable: false,
  };
}

function asrDisplayName(name: string, kind: string): string {
  if (kind === "local_inprocess") return `${name} · 本地进程`;
  if (kind === "local_server") return `${name} · 本地服务`;
  if (kind === "remote") return `${name} · 远端服务`;
  return name;
}

function firstString(value: unknown): string | undefined {
  return Array.isArray(value) ? value.find((item) => typeof item === "string") : undefined;
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item.length > 0) : [];
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function mapCredentialSource(value?: string): ServiceConnection["credentialStatus"]["source"] {
  if (value === "auth_json") return "user_auth_file";
  if (value === "env") return "environment";
  return "user_auth_file";
}
