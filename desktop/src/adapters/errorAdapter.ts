import type { UserFacingError } from "../domain/error";

export function technicalErrorToUserFacingError(error: unknown, source: UserFacingError["source"] = "worker"): UserFacingError {
  const detail = error instanceof Error ? error.message : String(error);

  return {
    title: "任务遇到问题",
    impact: "当前操作没有完成，需要处理后再继续。",
    severity: "blocking",
    source,
    technicalDetail: detail,
    nextActions: [
      { id: "retry", label: "重试" },
      { id: "diagnostics", label: "查看诊断", target: "/diagnostics" },
    ],
  };
}

export function taskErrorToUserFacingError(errorInfo: unknown, fallbackMessage?: unknown): UserFacingError | undefined {
  const raw = isRecord(errorInfo) ? errorInfo : undefined;
  const message = stringValue(raw?.message) ?? stringValue(fallbackMessage);
  if (!raw && !message) {
    return undefined;
  }

  const hint = stringValue(raw?.hint_zh);
  const stage = stringValue(raw?.stage);
  const retryable = raw?.retryable === true;

  return {
    title: titleForStage(stage),
    impact: hint ?? "当前任务没有完成，需要处理后再继续。",
    severity: retryable ? "warning" : "blocking",
    source: sourceForType(stringValue(raw?.type), stage),
    technicalDetail: message,
    nextActions: [
      retryable ? { id: "resume", label: "恢复任务" } : { id: "diagnostics", label: "查看诊断", target: "/diagnostics" },
      { id: "services", label: "检查服务连接", target: "/services" },
    ],
  };
}

function titleForStage(stage?: string): string {
  switch (stage) {
    case "INGEST":
      return "素材读取遇到问题";
    case "ASR":
      return "识别音频遇到问题";
    case "TRANSLATE":
    case "SEGMENT":
      return "翻译字幕遇到问题";
    case "QUALITY":
      return "质量检查遇到问题";
    case "EXPORT":
      return "导出字幕遇到问题";
    default:
      return "任务遇到问题";
  }
}

function sourceForType(type?: string, stage?: string): UserFacingError["source"] {
  if (stage === "ASR" || type?.includes("asr")) return "asr";
  if (type?.includes("provider") || type?.includes("auth")) return "provider";
  if (type?.includes("file")) return "filesystem";
  return "worker";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
