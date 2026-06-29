import type { ExportFormat, ExportedFile } from "../domain/export";
import type { Task, TaskStatus } from "../domain/task";
import type { TaskPipelineStep } from "../domain/taskRun";
import { taskErrorToUserFacingError } from "./errorAdapter";

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
  const inputPath = stringValue(raw.input_file) || stringValue(raw.input);
  const inputName = stringValue(raw.input_name) || fileNameFromPath(inputPath);
  const title = stringValue(raw.title) || inputName || `字幕任务 ${index + 1}`;
  const status = mapTaskStatus(stringValue(raw.status), stringValue(raw.checkpoint_status));
  const outputPaths = raw.output_paths && typeof raw.output_paths === "object" ? (raw.output_paths as Record<string, unknown>) : {};
  const outputs = outputFilesFromRecord(outputPaths, stringValue(raw.output_path), stringValue(raw.updated_at));
  const errorInfo = raw.error_info && typeof raw.error_info === "object" ? raw.error_info : undefined;

  return {
    id,
    title,
    status,
    input: {
      kind: mapInputKind(raw),
      path: inputPath,
      displayName: inputName || title,
    },
    languages: {
      sourceLanguage: stringValue(raw.source_lang) || "auto",
      targetLanguage: stringValue(raw.target_lang) || "zh-CN",
    },
    pipeline: pipelineFromTask(status, raw.progress_detail),
    outputs,
    taskDirectory: stringValue(raw.task_dir),
    recoverability: {
      canResume: status === "failedRecoverable" || status === "cancelled" || status === "interrupted",
      resumeLabel:
        status === "failedRecoverable"
          ? "从上次完成的步骤继续"
          : status === "cancelled"
            ? "从取消点继续"
            : status === "interrupted"
              ? "从中断点继续"
            : undefined,
    },
    error: taskErrorToUserFacingError(errorInfo, raw.error),
    createdAt: stringValue(raw.created_at) || new Date().toISOString(),
    updatedAt: stringValue(raw.updated_at) || new Date().toISOString(),
  };
}

function mapTaskStatus(status?: string, checkpointStatus?: string): TaskStatus {
  const normalized = status?.trim().toUpperCase();
  const normalizedCheckpoint = checkpointStatus?.trim().toUpperCase();
  if (normalized === "CANCEL_REQUESTED" && normalizedCheckpoint && ["DONE", "FAILED", "CANCELLED"].includes(normalizedCheckpoint)) {
    return mapNormalizedTaskStatus(normalizedCheckpoint);
  }
  return mapNormalizedTaskStatus(normalized);
}

function mapNormalizedTaskStatus(normalized?: string): TaskStatus {
  switch (normalized) {
    case "DRAFT":
      return "draft";
    case "READY":
    case "QUEUED":
    case "INIT":
    case "PRECHECK":
    case "ASR":
    case "SEGMENT":
    case "TRANSLATE":
    case "ALIGN":
    case "QUALITY":
    case "EXPORT":
      return "running";
    case "STARTING":
      return "starting";
    case "RUNNING":
      return "running";
    case "CANCEL_REQUESTED":
      return "cancelRequested";
    case "CANCELLED":
      return "cancelled";
    case "FAILED":
    case "FAILED_RECOVERABLE":
      return "failedRecoverable";
    case "INTERRUPTED":
      return "interrupted";
    case "FAILED_FATAL":
      return "failedFatal";
    case "DONE":
    case "COMPLETED":
      return "completed";
    default:
      return "ready";
  }
}

function pipelineFromTask(status: TaskStatus, progressDetail: unknown): TaskPipelineStep[] {
  const raw = (progressDetail ?? {}) as RawTaskRecord;
  const stage = stringValue(raw.translate_current_mode) || stringValue(raw.stage);
  const completedCount = numberValue(raw.translate_done_count) ?? 0;
  const totalCount = numberValue(raw.translate_total_chunks) ?? 0;
  const activeFromStage = stageIndex(stage);

  return [
    pipelineStep("input", "输入素材", status === "draft" ? "active" : "completed"),
    pipelineStep("subtitleSource", "获取源字幕", activeFromStage >= 1 || status === "completed" ? "completed" : stage === "ASR" ? "active" : "pending"),
    pipelineStep("translation", "翻译字幕", activeFromStage >= 2 || status === "completed" ? "completed" : stage === "SEGMENT" || stage === "TRANSLATE" || stage === "ALIGN" ? "active" : "pending"),
    pipelineStep("termConsistency", "术语一致性", activeFromStage >= 3 || status === "completed" ? "completed" : stage === "QUALITY" ? "active" : "pending"),
    pipelineStep("qualityReview", "质量检查", activeFromStage >= 4 || status === "completed" ? "completed" : stage === "QUALITY" || stage === "EXPORT" ? "active" : "pending"),
    pipelineStep("export", "导出交付", status === "completed" || stage === "EXPORT" ? "completed" : activeFromStage >= 5 ? "completed" : "pending"),
  ].map((step, index) => {
    if (step.status === "pending" && ((totalCount > 0 && index <= Math.min(totalCount, completedCount)) || index < activeFromStage)) {
      return pipelineStep(step.id, step.label, "completed");
    }
    return step;
  });
}

function outputFilesFromRecord(outputPaths: Record<string, unknown>, outputPath?: string, updatedAt?: string): ExportedFile[] {
  const files = Object.entries(outputPaths)
    .filter(([format, path]) => isExportFormat(format) && typeof path === "string" && path.length > 0)
    .map(([format, path]) => buildExportFile(format, path as string, updatedAt));

  if (files.length === 0 && outputPath) {
    files.push({
      id: "output",
      format: inferFormatFromPath(outputPath),
      path: outputPath,
      status: "ready",
      updatedAt,
    });
  }

  return files;
}

function mapInputKind(raw: RawTaskRecord): Task["input"]["kind"] {
  const inputType = stringValue(raw.input_type) || stringValue(raw.settings && typeof raw.settings === "object" ? (raw.settings as RawTaskRecord).input_type : undefined);
  if (inputType === "srt" || inputType === "srt_translate") return "subtitle";
  if (inputType === "segments" || inputType === "segments_translate") return "segments";
  const inputPath = stringValue(raw.input_file) || stringValue(raw.input);
  return inputPath?.toLowerCase().endsWith(".srt") ? "subtitle" : "video";
}

function fileNameFromPath(path?: string): string | undefined {
  if (!path) return undefined;
  const normalized = path.replace(/\\/g, "/");
  return normalized.split("/").filter(Boolean).pop() || path;
}

function inferFormatFromPath(path: string): ExportedFile["format"] {
  const extension = path.split(".").pop()?.toLowerCase();
  if (extension === "ass") return "ass";
  if (extension === "vtt") return "vtt";
  return "srt";
}

function buildExportFile(format: string, path: string, updatedAt?: string): ExportedFile {
  const normalizedFormat = format === "webvtt" ? "vtt" : (format as ExportFormat);
  return {
    id: format,
    format: normalizedFormat,
    path,
    status: "ready",
    updatedAt,
  };
}

function isExportFormat(value: string): value is ExportedFile["format"] | "webvtt" {
  return value === "srt" || value === "ass" || value === "vtt" || value === "webvtt";
}

function pipelineStep(id: TaskPipelineStep["id"], label: string, status: TaskPipelineStep["status"]): TaskPipelineStep {
  return { id, label, status };
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stageIndex(stage?: string): number {
  switch (stage) {
    case "PRECHECK":
    case "INIT":
    case "QUEUED":
      return 0;
    case "INGEST":
    case "ASR":
      return 1;
    case "SEGMENT":
    case "TRANSLATE":
      return 2;
    case "ALIGN":
      return 3;
    case "QUALITY":
      return 4;
    case "EXPORT":
      return 5;
    default:
      return -1;
  }
}
