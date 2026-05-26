import type { TaskRun, TimelineEvent, TaskPhase } from "../domain/taskRun";

type RawWorkerEvent = Record<string, unknown>;

export function normalizeWorkerEvents(taskId: string, payload: unknown): TaskRun {
  const events = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { events?: unknown[] })?.events)
      ? (payload as { events: unknown[] }).events
      : [];
  const timeline = events.map((event, index) => workerEventToTimelineEvent(event, index));
  const lastEvent = timeline[timeline.length - 1];

  return {
    taskId,
    phase: lastEvent?.phase ?? "idle",
    currentAction: lastEvent?.title ?? "等待任务事件",
    progress: {
      percent: lastEvent?.phase === "completed" ? 100 : 0,
      label: lastEvent?.phase === "completed" ? "已完成" : "等待更新",
    },
    timeline,
    warnings: [],
    canCancel: false,
    canResume: false,
    lastEventAt: lastEvent?.at,
  };
}

export function workerEventToTimelineEvent(event: unknown, index = 0): TimelineEvent {
  const raw = (event ?? {}) as RawWorkerEvent;
  const type = stringValue(raw.type) || stringValue(raw.event) || "event";
  const phase = mapEventPhase(type);

  return {
    id: stringValue(raw.id) || `event-${index}`,
    at: stringValue(raw.at) || stringValue(raw.timestamp) || new Date().toISOString(),
    phase,
    title: mapEventTitle(type),
    detail: stringValue(raw.message) || stringValue(raw.detail),
    severity: mapEventSeverity(type),
  };
}

function mapEventPhase(type: string): TaskPhase {
  if (type.includes("asr")) return "asr";
  if (type.includes("translate")) return "translation";
  if (type.includes("quality")) return "qualityReview";
  if (type.includes("export")) return "export";
  if (type.includes("complete")) return "completed";
  if (type.includes("fail") || type.includes("error")) return "failed";
  return "input";
}

function mapEventTitle(type: string): string {
  if (type.includes("asr")) return "正在识别音频";
  if (type.includes("translate")) return "正在翻译字幕";
  if (type.includes("quality")) return "正在检查字幕质量";
  if (type.includes("export")) return "正在导出字幕文件";
  if (type.includes("complete")) return "任务已完成";
  if (type.includes("fail") || type.includes("error")) return "任务遇到问题";
  return "记录任务事件";
}

function mapEventSeverity(type: string): TimelineEvent["severity"] {
  if (type.includes("fail") || type.includes("error")) return "error";
  if (type.includes("warn")) return "warning";
  if (type.includes("complete")) return "success";
  return "info";
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
