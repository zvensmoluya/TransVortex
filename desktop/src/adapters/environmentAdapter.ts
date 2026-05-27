import type { EnvironmentCheck } from "../domain/environment";

type RawDoctorCheck = Record<string, unknown>;

export function doctorPayloadToEnvironmentChecks(payload: unknown): EnvironmentCheck[] {
  const checks = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { checks?: unknown[] })?.checks)
      ? (payload as { checks: unknown[] }).checks
      : [];

  return checks.map((check, index) => doctorCheckToEnvironmentCheck(check, index));
}

export function doctorCheckToEnvironmentCheck(check: unknown, index = 0): EnvironmentCheck {
  const raw = (check ?? {}) as RawDoctorCheck;
  const status = mapStatus(stringValue(raw.status));
  const name = stringValue(raw.name) || `diagnostic_${index + 1}`;
  const label = labelForCheck(name);

  return {
    id: stringValue(raw.code) || `environment-${index + 1}`,
    label,
    status,
    category: categoryForCheck(name, status),
    impact: stringValue(raw.hint_zh) || stringValue(raw.message) || "该项会影响任务运行前检查。",
    nextActions: actionsForCheck(name, status, raw),
    technicalDetail: stringValue(raw.code),
  };
}

function mapStatus(status?: string): EnvironmentCheck["status"] {
  if (status === "PASS" || status === "pass") return "pass";
  if (status === "WARN" || status === "warn") return "warn";
  return "fail";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function labelForCheck(name: string): string {
  const labels: Record<string, string> = {
    python: "任务运行环境",
    transvortex_package: "TransVortex 包",
    ffmpeg: "ffmpeg",
    ffprobe: "ffprobe",
    providers_file: "服务配置文件",
    artifacts: "任务工件目录",
    faster_whisper: "本地识别",
    routing: "翻译服务路由",
    provider_env_key: "翻译服务凭据",
    provider_protocol: "服务协议预检",
  };
  return labels[name] ?? name;
}

function categoryForCheck(name: string, status: EnvironmentCheck["status"]): EnvironmentCheck["category"] {
  if (status === "fail") return "blocking";
  if (name === "faster_whisper" || name.includes("asr")) return "quality_risk";
  if (status === "warn") return "quality_risk";
  return "optional";
}

function actionsForCheck(name: string, status: EnvironmentCheck["status"], raw: RawDoctorCheck): EnvironmentCheck["nextActions"] {
  const details = isRecord(raw.details) ? raw.details : {};
  const path = stringValue(details.path) || stringValue(details.auth_file) || stringValue(details.providers_file);
  if (status === "pass") {
    return path ? [{ id: "open-path", label: "打开位置", kind: "openPath", target: path }] : [];
  }
  if (name === "provider_env_key" || name === "provider_protocol" || name === "routing" || name === "asr_env_key" || name === "asr_provider") {
    return [{ id: "services", label: "打开模型与凭据", kind: "navigate", target: "/services" }];
  }
  if (name === "providers_file" || name === "config_load") {
    return [
      { id: "settings", label: "打开设置", kind: "navigate", target: "/settings" },
      ...(path ? [{ id: "open-path", label: "打开配置位置", kind: "openPath" as const, target: path }] : []),
    ];
  }
  if (name === "artifacts" && path) {
    return [{ id: "open-path", label: "打开任务目录", kind: "openPath", target: path }];
  }
  return [{ id: "refresh", label: "重新检测", kind: "refresh" }];
}
