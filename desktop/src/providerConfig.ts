import { t, zh, type I18nKey } from "./i18n";
import type {
  ConfigPayload,
  ProviderConfig,
  ProviderDiagnostic,
  ProviderDraft,
  ProviderTemplate,
  ProviderTestPayload,
  RoutingProfile,
} from "./types";

export function textValue(value: unknown, fallback: string) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

export function numberValue(value: unknown, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export function arrayValue(value: unknown) {
  return Array.isArray(value) ? value.map(String).filter(Boolean) : [];
}

export function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export function defaultTemplate(config: ConfigPayload | null) {
  const templates = config?.protocol_templates?.length ? config.protocol_templates : config?.provider_templates || [];
  return templates.find((item) => item.id === "openai_chat") || templates[0];
}

export function protocolTemplates(config: ConfigPayload | null) {
  return config?.protocol_templates?.length ? config.protocol_templates : config?.provider_templates || [];
}

export function nextRouteProfileIdFromSeq(nextSeq: number) {
  return `route_${Math.max(1, Math.floor(nextSeq || 1))}`;
}

export function nextRouteProfileName(profiles: RoutingProfile[]) {
  const used = new Set(profiles.map((item) => item.name));
  for (let index = 1; index < 1000; index += 1) {
    const candidate = `配置 ${index}`;
    if (!used.has(candidate)) return candidate;
  }
  return "配置";
}

export function normalizeRoutingProfiles(config: ConfigPayload | null): RoutingProfile[] {
  if (!config) return [];
  if (config.routing_profiles?.length) {
    return config.routing_profiles.map((profile) => ({
      ...profile,
      fallback: profile.fallback || [],
    }));
  }
  return [
    {
      id: "default",
      name: "Default",
      primary: config.routing.primary,
      fallback: config.routing.fallback || [],
    },
  ];
}

export function validateRoutingProfileDrafts(profiles: RoutingProfile[]) {
  if (!profiles.length) return "至少需要一个 Route profile。";
  const names = new Set<string>();
  for (const profile of profiles) {
    const name = profile.name.trim();
    if (!name) return "Route profile 名称不能为空。";
    const key = name.toLocaleLowerCase();
    if (names.has(key)) return `Route profile 名称重复：${name}。`;
    names.add(key);
    if (!profile.primary.provider || !profile.primary.model) return `${name} 的 Primary provider 和 model 都不能为空。`;
    for (const route of profile.fallback) {
      if (!route.provider || !route.model) return `${name} 的 Fallback provider 和 model 都不能为空。`;
    }
  }
  return "";
}

export function envKeyForName(name: string) {
  const slug = name.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").toUpperCase() || "CUSTOM";
  return `TVX_PROVIDER_${slug}_API_KEY`;
}

export function providerToDraft(provider: ProviderConfig): ProviderDraft {
  return {
    name: provider.name,
    api_type: provider.api_type,
    compat_mode: provider.compat_mode,
    base_url: provider.base_url,
    env_key: provider.env_key,
    credential_id: provider.credential_id || provider.name,
    models: provider.models || [],
    auth: provider.auth || { type: "bearer", header_name: "Authorization", query_name: "key", prefix: "Bearer " },
    endpoint: provider.endpoint || { path_template: "/chat/completions", method: "POST" },
    request_mapping: provider.request_mapping || { style: provider.compat_mode },
    response_mapping: { text_paths: provider.response_mapping?.text_paths || [] },
    extra_headers: provider.extra_headers || {},
    model_list: provider.model_list || { path_template: "/models", method: "GET", response_paths: ["data[].id"] },
    capabilities: provider.capabilities || {},
  };
}

export function templateToDraft(template: ProviderTemplate, name = "custom_provider"): ProviderDraft {
  return {
    name,
    api_type: template.api_type,
    compat_mode: template.compat_mode,
    base_url: template.base_url,
    env_key: envKeyForName(name),
    credential_id: name,
    models: [],
    auth: { ...template.auth },
    endpoint: { ...template.endpoint },
    request_mapping: { ...template.request_mapping },
    response_mapping: { text_paths: [...(template.response_mapping?.text_paths || [])] },
    extra_headers: { ...(template.extra_headers || {}) },
    model_list: {
      path_template: template.model_list?.path_template || "/models",
      method: template.model_list?.method || "GET",
      response_paths: [...(template.model_list?.response_paths || ["data[].id"])],
    },
    capabilities: { ...(template.capabilities || {}) },
  };
}

export function diagnosticText(payload?: ProviderDiagnostic | ProviderTestPayload | null) {
  if (!payload) return "";
  if ("checks" in payload) {
    const failed = payload.checks.find((check) => check.status === "FAIL") || payload.checks[0];
    return failed ? `${diagnosticHint(failed)} (${failed.code})` : payload.status;
  }
  return `${diagnosticHint(payload)} (${payload.code})`;
}

export function diagnosticHint(payload: { code?: string; hint_zh?: string; message?: string }) {
  const code = payload.code as I18nKey | undefined;
  if (code && code in zh) return t(code);
  return payload.hint_zh || payload.message || "";
}

export function fieldTranslation(payload: ConfigPayload["pipeline"]) {
  return payload.translation as
    | {
        style_preset?: string;
        style_prompt?: string;
        chunk_lines?: number;
        context_before_lines?: number;
        context_after_lines?: number;
        repair?: { enabled?: boolean };
      }
    | undefined;
}
