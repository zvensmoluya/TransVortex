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
  const label = stringValue(raw.name) || `诊断项 ${index + 1}`;

  return {
    id: stringValue(raw.code) || `environment-${index + 1}`,
    label,
    status,
    category: status === "fail" ? "blocking" : status === "warn" ? "quality_risk" : "optional",
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
