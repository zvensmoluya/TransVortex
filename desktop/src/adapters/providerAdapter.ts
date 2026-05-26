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

  return [
    {
      id: "asr-local",
      kind: "asr",
      providerName: "faster-whisper",
      displayName: "本地识别",
      model: "small",
      credentialStatus: { state: "notRequired", label: "无需凭据" },
      connectionStatus: { state: "untested", label: "由环境诊断确认" },
      isDefault: true,
      fallbackTargets: [],
      expertConfigAvailable: false,
    },
  ];
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

  return {
    id: `${kind}-${name}`,
    kind,
    providerName: name,
    displayName: stringValue(raw.display_name) || name,
    model: isDefault ? primaryModel || firstString(raw.models) : firstString(raw.models),
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

function firstString(value: unknown): string | undefined {
  return Array.isArray(value) ? value.find((item) => typeof item === "string") : undefined;
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
