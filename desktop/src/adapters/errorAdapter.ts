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
