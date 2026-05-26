import type { TaskRun, TimelineEvent, TaskPhase } from "../domain/taskRun";
import { taskErrorToUserFacingError } from "./errorAdapter";

type RawWorkerEvent = Record<string, unknown>;

export function normalizeWorkerEvents(taskId: string, payload: unknown): TaskRun {
  const events = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { events?: unknown[] })?.events)
      ? (payload as { events: unknown[] }).events
      : [];
  const timeline = events.map((event, index) => workerEventToTimelineEvent(event, index));
  const lastEvent = timeline[timeline.length - 1];
  const lastRawEvent = events.length > 0 ? (events[events.length - 1] as RawWorkerEvent) : undefined;
  const lastProgress = numberValue(lastRawEvent?.progress);
  const errorInfo = isRecord(lastRawEvent?.details) ? lastRawEvent.details.error_info : undefined;

  return {
    taskId,
    phase: lastEvent?.phase ?? "idle",
    currentAction: lastEvent?.title ?? "等待任务事件",
    progress: {
      percent: typeof lastProgress === "number" ? Math.round(lastProgress * 10000) / 100 : lastEvent?.phase === "completed" ? 100 : 0,
      label: progressLabel(lastProgress, lastEvent?.phase),
    },
    timeline,
    warnings: [],
    error: taskErrorToUserFacingError(errorInfo, stringValue(lastRawEvent?.message)),
    canCancel: false,
    canResume: lastEvent?.phase === "failed" || lastEvent?.phase === "translation" || lastEvent?.phase === "asr",
    lastEventAt: lastEvent?.at,
  };
}

export function workerEventToTimelineEvent(event: unknown, index = 0): TimelineEvent {
  const raw = (event ?? {}) as RawWorkerEvent;
  const type = stringValue(raw.type) || stringValue(raw.event) || "event";
  const stage = stringValue(raw.stage);
  const phase = mapEventPhase(type, stage);
  const taskId = stringValue(raw.task_id) || stringValue(raw.taskId);

  return {
    id: stringValue(raw.id) || `event-${index}`,
    at: stringValue(raw.at) || stringValue(raw.timestamp) || new Date().toISOString(),
    taskId,
    phase,
    title: mapEventTitle(type, stage),
    detail: stringValue(raw.message) || stringValue(raw.detail),
    progressPercent: numberValue(raw.progress) !== undefined ? Math.round((numberValue(raw.progress) ?? 0) * 100) : undefined,
    severity: mapEventSeverity(type),
  };
}

function mapEventPhase(type: string, stage?: string): TaskPhase {
  switch (stage) {
    case "PRECHECK":
    case "INGEST":
    case "QUEUED":
    case "INIT":
      return "input";
    case "ASR":
      return "asr";
    case "SEGMENT":
    case "TRANSLATE":
    case "ALIGN":
      return "translation";
    case "QUALITY":
      return "qualityReview";
    case "EXPORT":
      return "export";
    case "DONE":
      return "completed";
    case "FAILED":
      return "failed";
  }
  if (type.includes("asr")) return "asr";
  if (type.includes("translate")) return "translation";
  if (type.includes("quality")) return "qualityReview";
  if (type.includes("export")) return "export";
  if (type.includes("complete")) return "completed";
  if (type.includes("fail") || type.includes("error")) return "failed";
  return "input";
}

function mapEventTitle(type: string, stage?: string): string {
  switch (stage) {
    case "PRECHECK":
      return "正在做启动前检查";
    case "INGEST":
      return "正在读取素材";
    case "ASR":
      return "正在识别音频";
    case "SEGMENT":
    case "TRANSLATE":
      return "正在翻译字幕";
    case "ALIGN":
      return "正在对齐字幕";
    case "QUALITY":
      return "正在检查字幕质量";
    case "EXPORT":
      return "正在导出字幕文件";
    case "DONE":
      return "任务已完成";
    case "FAILED":
      return "任务遇到问题";
  }
  if (type.includes("asr")) return "正在识别音频";
  if (type.includes("translate")) return "正在翻译字幕";
  if (type.includes("progress")) return "任务推进中";
  if (type.includes("quality")) return "正在检查字幕质量";
  if (type.includes("export")) return "正在导出字幕文件";
  if (type.includes("complete")) return "任务已完成";
  if (type.includes("fail") || type.includes("error")) return "任务遇到问题";
  if (type.includes("stage")) return "任务正在推进";
  return "记录任务事件";
}

function mapEventSeverity(type: string): TimelineEvent["severity"] {
  if (type.includes("fail") || type.includes("error")) return "error";
  if (type.includes("warn")) return "warning";
  if (type.includes("complete")) return "success";
  if (type.includes("progress")) return "info";
  return "info";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function progressLabel(progress: number | undefined, phase: TaskPhase | undefined): string {
  if (typeof progress === "number") {
    return `进度 ${Math.round(progress * 100)}%`;
  }
  if (phase === "completed") {
    return "已完成";
  }
  if (phase === "failed") {
    return "已失败";
  }
  return "等待更新";
}
