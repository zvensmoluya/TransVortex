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
    nextActions: [{ id: "review", label: status === "pass" ? "保持当前配置" : "查看处理方式", target: "/diagnostics" }],
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
