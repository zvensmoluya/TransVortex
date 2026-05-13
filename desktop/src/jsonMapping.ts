function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseJsonObject(value: string) {
  try {
    const parsed = JSON.parse(value || "{}");
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function cloneRecord(value: Record<string, unknown>) {
  return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

export function getPathValue(root: Record<string, unknown>, path: string) {
  let current: unknown = root;
  for (const token of path.split(".")) {
    if (!isRecord(current)) return undefined;
    current = current[token];
  }
  return current;
}

function setPathValue(root: Record<string, unknown>, path: string, value: unknown) {
  const tokens = path.split(".").filter(Boolean);
  if (tokens.length === 0) return;
  let current: Record<string, unknown> = root;
  tokens.slice(0, -1).forEach((token) => {
    if (!isRecord(current[token])) current[token] = {};
    current = current[token] as Record<string, unknown>;
  });
  current[tokens[tokens.length - 1]] = value;
}

function deletePathValue(root: Record<string, unknown>, path: string) {
  const tokens = path.split(".").filter(Boolean);
  if (tokens.length === 0) return;
  let current: unknown = root;
  tokens.slice(0, -1).forEach((token) => {
    current = isRecord(current) ? current[token] : undefined;
  });
  if (isRecord(current)) delete current[tokens[tokens.length - 1]];
}

function formatJsonObject(value: Record<string, unknown>) {
  return JSON.stringify(value, null, 2);
}

function updateRequestMappingJson(raw: string, updater: (mapping: Record<string, unknown>) => void) {
  const parsed = parseJsonObject(raw);
  if (!parsed) return raw;
  const next = cloneRecord(parsed);
  updater(next);
  return formatJsonObject(next);
}

export function requestBodyPath(path: string) {
  return `body_overrides.${path}`;
}

export function setRequestBodyOverride(raw: string, path: string, value: unknown) {
  return updateRequestMappingJson(raw, (mapping) => {
    if (value === "" || value === undefined || value === null) {
      deletePathValue(mapping, requestBodyPath(path));
      return;
    }
    setPathValue(mapping, requestBodyPath(path), value);
  });
}

export const tokenLimitFields = [
  { value: "auto", label: "不指定" },
  { value: "max_tokens", label: "max_tokens" },
  { value: "max_completion_tokens", label: "max_completion_tokens" },
  { value: "generationConfig.maxOutputTokens", label: "Gemini maxOutputTokens" },
];

export function tokenLimitFieldForMapping(mapping: Record<string, unknown> | null) {
  if (!mapping) return "auto";
  if (getPathValue(mapping, "max_tokens") !== undefined) return "max_tokens";
  if (getPathValue(mapping, requestBodyPath("max_completion_tokens")) !== undefined) return "max_completion_tokens";
  if (getPathValue(mapping, requestBodyPath("max_tokens")) !== undefined) return "max_tokens";
  if (getPathValue(mapping, requestBodyPath("generationConfig.maxOutputTokens")) !== undefined) return "generationConfig.maxOutputTokens";
  return "auto";
}

export function tokenLimitValueForMapping(mapping: Record<string, unknown> | null) {
  if (!mapping) return "";
  const field = tokenLimitFieldForMapping(mapping);
  if (field === "auto") return "";
  if (field === "max_tokens") {
    return String(getPathValue(mapping, "max_tokens") ?? getPathValue(mapping, requestBodyPath("max_tokens")) ?? "");
  }
  return String(getPathValue(mapping, requestBodyPath(field)) ?? "");
}

export function setTokenLimit(raw: string, field: string, value: string) {
  return updateRequestMappingJson(raw, (mapping) => {
    deletePathValue(mapping, "max_tokens");
    deletePathValue(mapping, requestBodyPath("max_tokens"));
    deletePathValue(mapping, requestBodyPath("max_completion_tokens"));
    deletePathValue(mapping, requestBodyPath("generationConfig.maxOutputTokens"));
    const parsedValue = value === "" ? undefined : Number(value);
    if (field === "auto" || parsedValue === undefined || !Number.isFinite(parsedValue)) return;
    if (field === "max_tokens") {
      setPathValue(mapping, "max_tokens", parsedValue);
      return;
    }
    setPathValue(mapping, requestBodyPath(field), parsedValue);
  });
}
