import type { Task, TaskStatus } from "../domain/task";
import type { TaskPipelineStep } from "../domain/taskRun";

type RawTaskRecord = Record<string, unknown>;

export function taskRecordsToTasks(payload: unknown): Task[] {
  const records = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { tasks?: unknown[] })?.tasks)
      ? (payload as { tasks: unknown[] }).tasks
      : [];

  return records.map((record, index) => taskRecordToTask(record, index));
}

export function taskRecordToTask(record: unknown, index = 0): Task {
  const raw = (record ?? {}) as RawTaskRecord;
  const id = stringValue(raw.task_id) || stringValue(raw.id) || `task-${index + 1}`;
  const title = stringValue(raw.title) || stringValue(raw.input_name) || `字幕任务 ${index + 1}`;
  const status = mapTaskStatus(stringValue(raw.status));

  return {
    id,
    title,
    status,
    input: {
      kind: "video",
      path: stringValue(raw.input),
      displayName: stringValue(raw.input_name) || title,
    },
    languages: {
      sourceLanguage: stringValue(raw.source_lang) || "auto",
      targetLanguage: stringValue(raw.target_lang) || "zh-CN",
    },
    pipeline: defaultPipeline(status),
    outputs: [],
    taskDirectory: stringValue(raw.task_dir),
    recoverability: {
      canResume: status === "failedRecoverable",
      resumeLabel: status === "failedRecoverable" ? "从上次完成的步骤继续" : undefined,
    },
    createdAt: stringValue(raw.created_at) || new Date().toISOString(),
    updatedAt: stringValue(raw.updated_at) || new Date().toISOString(),
  };
}

function mapTaskStatus(status?: string): TaskStatus {
  switch (status) {
    case "running":
      return "running";
    case "cancelled":
      return "cancelled";
    case "failed":
    case "failed_recoverable":
      return "failedRecoverable";
    case "failed_fatal":
      return "failedFatal";
    case "completed":
      return "completed";
    default:
      return "ready";
  }
}

function defaultPipeline(status: TaskStatus): TaskPipelineStep[] {
  const completed = status === "completed";
  return [
    { id: "input", label: "输入素材", status: completed ? "completed" : "completed" },
    { id: "subtitleSource", label: "获取源字幕", status: completed ? "completed" : "completed" },
    { id: "translation", label: "翻译字幕", status: completed ? "completed" : status === "running" ? "active" : "pending" },
    { id: "qualityReview", label: "质量检查", status: completed ? "completed" : "pending" },
    { id: "export", label: "导出交付", status: completed ? "completed" : "pending" },
  ];
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
