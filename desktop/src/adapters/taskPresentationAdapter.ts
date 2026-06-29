import type { ExportFormat, ExportedFile } from "../domain/export";
import type { Task } from "../domain/task";
import type { ProgressState, TaskPhase, TaskRun } from "../domain/taskRun";
import type { Segment } from "../domain/segment";

export type PresentationTone = "success" | "warning" | "danger" | "info" | "neutral";

export type TaskActionId =
  | "refresh"
  | "openTaskDirectory"
  | "resume"
  | "cancel"
  | "reviewResult"
  | "saveResult"
  | "reexport"
  | "openPrimaryOutput";

export type TaskActionCapability = {
  id: TaskActionId;
  label: string;
  visible: boolean;
  enabled: boolean;
  disabledReason?: string;
};

export type PresentedOutputFile = ExportedFile & {
  displayName: string;
  statusLabel: string;
  statusTone: PresentationTone;
  canOpen: boolean;
};

export type TaskStagePresentation = {
  phase: TaskPhase;
  label: string;
  detail: string;
  tone: PresentationTone;
  progress: ProgressState;
};

export type ResultWorkspacePresentation = {
  segmentCount: number;
  issueCount: number;
  dirtyCount: number;
  unsavedDirtyCount: number;
  saveStateLabel: string;
  saveStateTone: PresentationTone;
  outputStateLabel: string;
  outputStateTone: PresentationTone;
  description: string;
  isLoading: boolean;
  hasSegments: boolean;
  savedPendingExport: boolean;
};

export type DeliveryPresentation = {
  files: PresentedOutputFile[];
  primaryOutput?: PresentedOutputFile;
  stateLabel: string;
  stateTone: PresentationTone;
  emptyLabel: string;
  formatsForReexport: ExportFormat[];
  hasOpenableOutput: boolean;
  savedPendingExport: boolean;
};

export type TaskPresentation = {
  taskId: string;
  title: string;
  subtitle: string;
  statusLabel: string;
  statusTone: PresentationTone;
  stage: TaskStagePresentation;
  actions: Record<TaskActionId, TaskActionCapability>;
  delivery: DeliveryPresentation;
  workspace?: ResultWorkspacePresentation;
};

export type ResultWorkspaceFacts = {
  segments: Segment[];
  saveState: "notOpened" | "loading" | "clean" | "dirty" | "saving" | "savedPendingExport" | "error";
};

type PresentationOptions = {
  task: Task;
  taskRun?: TaskRun;
  workspace?: ResultWorkspaceFacts;
};

const defaultProgress: ProgressState = {
  percent: 0,
  label: "等待更新",
};

export function taskToPresentation({ task, taskRun, workspace }: PresentationOptions): TaskPresentation {
  const workspaceView = workspace ? workspaceToPresentation(workspace) : undefined;
  const delivery = deliveryToPresentation(task.outputs, workspaceView);
  const stage = taskStageToPresentation(task, taskRun);
  const actions = taskActionsToPresentation(task, taskRun, delivery, workspaceView);

  return {
    taskId: task.id,
    title: task.title,
    subtitle: `${task.input.displayName} · ${task.languages.sourceLanguage} → ${task.languages.targetLanguage} · ${stage.detail}`,
    statusLabel: taskStatusLabel(task, taskRun),
    statusTone: taskStatusTone(task, taskRun),
    stage,
    actions,
    delivery,
    workspace: workspaceView,
  };
}

export function taskRunToTopStatusPresentation(currentRun?: TaskRun) {
  if (!currentRun) {
    return {
      label: "工作台已就绪",
      tone: "success" as PresentationTone,
      meta: ["字幕行", "时间轴", "质量检查", "输出文件"],
      progress: undefined,
      failed: false,
    };
  }

  const failed = currentRun.phase === "failed";
  return {
    label: currentRun.currentAction,
    tone: failed ? "danger" as PresentationTone : "info" as PresentationTone,
    meta: [phaseLabel(currentRun.phase), failed && currentRun.canResume ? "可恢复" : currentRun.phase === "completed" ? "可查看结果" : "制作中"],
    progress: currentRun.progress,
    failed,
  };
}

function taskActionsToPresentation(
  task: Task,
  taskRun: TaskRun | undefined,
  delivery: DeliveryPresentation,
  workspace: ResultWorkspacePresentation | undefined,
): Record<TaskActionId, TaskActionCapability> {
  const terminalStatus = task.status === "completed" || task.status === "cancelled" || task.status === "interrupted" || task.status === "failedRecoverable" || task.status === "failedFatal";
  const canCancel = !terminalStatus && (taskRun?.canCancel === true || ["starting", "running", "cancelRequested"].includes(task.status));
  const canResume = task.recoverability.canResume || (taskRun?.phase === "failed" && task.status !== "failedFatal");
  const hasReviewResult = workspace?.hasSegments === true || delivery.files.length > 0;
  const saveEnabled = workspace?.unsavedDirtyCount ? workspace.unsavedDirtyCount > 0 : false;
  const reexportDisabledReason = reexportDisabledReasonFor(workspace, delivery);
  const hasTaskDirectory = Boolean(task.taskDirectory);

  return {
    refresh: action("refresh", "刷新", true, true),
    openTaskDirectory: action(
      "openTaskDirectory",
      "任务目录",
      hasTaskDirectory,
      hasTaskDirectory,
      hasTaskDirectory ? undefined : "任务目录尚未生成",
    ),
    resume: action(
      "resume",
      task.recoverability.resumeLabel ?? "恢复任务",
      canResume,
      canResume,
      canResume ? undefined : "当前任务不需要恢复",
    ),
    cancel: action(
      "cancel",
      task.status === "cancelRequested" ? "正在取消" : "取消",
      canCancel,
      canCancel && task.status !== "cancelRequested",
      task.status === "cancelRequested" ? "正在等待任务停止" : "当前任务不可取消",
    ),
    reviewResult: action(
      "reviewResult",
      "结果检查",
      true,
      hasReviewResult,
      hasReviewResult ? undefined : "还没有可检查的字幕结果",
    ),
    saveResult: action(
      "saveResult",
      workspace?.savedPendingExport ? "已保存" : "保存修改",
      workspace !== undefined,
      saveEnabled,
      saveEnabled ? undefined : "没有未保存修改",
    ),
    reexport: action(
      "reexport",
      "重新导出",
      true,
      !reexportDisabledReason,
      reexportDisabledReason,
    ),
    openPrimaryOutput: action(
      "openPrimaryOutput",
      "打开输出",
      delivery.primaryOutput !== undefined,
      delivery.primaryOutput?.canOpen === true,
      delivery.primaryOutput ? undefined : "还没有可打开的输出文件",
    ),
  };
}

function taskStageToPresentation(task: Task, taskRun?: TaskRun): TaskStagePresentation {
  if (taskRun) {
    return {
      phase: taskRun.phase,
      label: taskRun.currentAction,
      detail: phaseDetail(taskRun.phase),
      tone: phaseTone(taskRun.phase),
      progress: taskRun.progress,
    };
  }

  const activeStep = task.pipeline.find((step) => step.status === "active");
  const failedStep = task.pipeline.find((step) => step.status === "failed");
  const phase = failedStep?.id ?? activeStep?.id ?? phaseFromTaskStatus(task.status);
  return {
    phase,
    label: statusStageLabel(task.status, phase),
    detail: task.recoverability.resumeLabel ?? phaseDetail(phase),
    tone: taskStatusTone(task),
    progress: {
      percent: task.status === "completed" ? 100 : 0,
      label: task.status === "completed" ? "已完成" : "等待更新",
    },
  };
}

function deliveryToPresentation(
  files: ExportedFile[],
  workspace: ResultWorkspacePresentation | undefined,
): DeliveryPresentation {
  const savedPendingExport = workspace?.savedPendingExport === true;
  const presentedFiles = files.map((file) => outputFileToPresentation(file, savedPendingExport));
  const state = deliveryState(presentedFiles, savedPendingExport);
  const formats = uniqueFormats(presentedFiles.map((file) => file.format));

  return {
    files: presentedFiles,
    primaryOutput: presentedFiles.find((file) => file.canOpen),
    stateLabel: state.label,
    stateTone: state.tone,
    emptyLabel: "还没有可交付的字幕文件。",
    formatsForReexport: formats.length > 0 ? formats : ["srt"],
    hasOpenableOutput: presentedFiles.some((file) => file.canOpen),
    savedPendingExport,
  };
}

function outputFileToPresentation(file: ExportedFile, forceStale: boolean): PresentedOutputFile {
  const status = forceStale && file.status === "ready" ? "stale" : file.status;
  return {
    ...file,
    status,
    displayName: file.format.toUpperCase(),
    statusLabel: outputStatusLabel(status),
    statusTone: outputStatusTone(status),
    canOpen: Boolean(file.path) && status !== "notGenerated" && status !== "failed",
  };
}

function workspaceToPresentation(
  workspace: ResultWorkspaceFacts,
): ResultWorkspacePresentation {
  const segmentCount = workspace.segments.length;
  const issueCount = workspace.segments.reduce((total, segment) => total + segment.issues.length, 0);
  const dirtyCount = workspace.segments.filter((segment) => segment.dirtyState !== "clean").length;
  const unsavedDirtyCount = workspace.segments.filter((segment) => segment.dirtyState === "dirty").length;
  const savedPendingExport = workspace.saveState === "savedPendingExport" || workspace.segments.some((segment) => segment.dirtyState === "savedPendingExport");
  const outputStateLabel = savedPendingExport || dirtyCount > 0 ? "待重新导出" : "已交付";
  const outputStateTone = savedPendingExport || dirtyCount > 0 ? "warning" : "success";

  return {
    segmentCount,
    issueCount,
    dirtyCount,
    unsavedDirtyCount,
    saveStateLabel: saveStateLabel(workspace.saveState),
    saveStateTone: saveStateTone(workspace.saveState),
    outputStateLabel,
    outputStateTone,
    description: `${segmentCount} 行字幕 · ${issueCount} 个质量问题 · ${dirtyCount} 行尚未交付到输出文件`,
    isLoading: workspace.saveState === "loading",
    hasSegments: segmentCount > 0,
    savedPendingExport,
  };
}

function reexportDisabledReasonFor(
  workspace: ResultWorkspacePresentation | undefined,
  delivery: DeliveryPresentation,
): string | undefined {
  if (workspace?.isLoading) return "结果还在读取中";
  if (workspace?.unsavedDirtyCount && workspace.unsavedDirtyCount > 0) return "请先保存修改";
  if (workspace && !workspace.hasSegments) return "当前任务还没有可导出的字幕结果";
  if (!workspace && delivery.files.length === 0) return "还没有可重新导出的字幕结果";
  return undefined;
}

function action(
  id: TaskActionId,
  label: string,
  visible: boolean,
  enabled: boolean,
  disabledReason?: string,
): TaskActionCapability {
  return { id, label, visible, enabled, disabledReason };
}

function taskStatusTone(task: Task, taskRun?: TaskRun): PresentationTone {
  if (taskRun?.phase === "failed") return "danger";
  if (taskRun && taskRun.phase !== "completed" && taskRun.phase !== "idle") return "info";
  if (task.status === "completed") return "success";
  if (task.status === "running" || task.status === "starting" || task.status === "cancelRequested") return "info";
  if (task.status === "failedRecoverable" || task.status === "cancelled" || task.status === "interrupted") return "warning";
  if (task.status === "failedFatal") return "danger";
  return "neutral";
}

function taskStatusLabel(task: Task, taskRun?: TaskRun): string {
  if (taskRun?.phase === "completed") return "已完成";
  if (taskRun?.phase === "failed") return task.status === "cancelled" ? "已取消" : "遇到问题";
  if (taskRun && taskRun.phase !== "idle") return "制作中";
  switch (task.status) {
    case "completed":
      return "已完成";
    case "running":
      return "运行中";
    case "starting":
      return "启动中";
    case "cancelRequested":
      return "正在取消";
    case "interrupted":
      return "已中断";
    case "failedRecoverable":
      return "可恢复失败";
    case "failedFatal":
      return "失败";
    case "cancelled":
      return "已取消";
    case "draft":
      return "草稿";
    case "ready":
    default:
      return "待处理";
  }
}

function statusStageLabel(status: Task["status"], phase: TaskPhase): string {
  if (status === "completed") return "任务已完成";
  if (status === "cancelled") return "任务已取消";
  if (status === "interrupted") return "任务已中断";
  if (status === "failedRecoverable" || status === "failedFatal") return "任务遇到问题";
  if (status === "starting") return "正在启动任务";
  if (status === "cancelRequested") return "正在取消任务";
  return phaseLabel(phase);
}

function phaseFromTaskStatus(status: Task["status"]): TaskPhase {
  if (status === "completed") return "completed";
  if (status === "failedRecoverable" || status === "failedFatal" || status === "cancelled" || status === "interrupted") return "failed";
  if (status === "draft" || status === "ready" || status === "starting") return "input";
  return "translation";
}

function phaseLabel(phase: TaskPhase): string {
  switch (phase) {
    case "input":
      return "准备素材";
    case "subtitleSource":
      return "获取源字幕";
    case "asr":
      return "识别音频";
    case "translation":
      return "翻译字幕";
    case "termConsistency":
      return "检查术语";
    case "qualityReview":
      return "检查字幕质量";
    case "export":
      return "导出字幕文件";
    case "completed":
      return "任务已完成";
    case "failed":
      return "任务遇到问题";
    case "idle":
    default:
      return "等待任务事件";
  }
}

function phaseDetail(phase: TaskPhase): string {
  switch (phase) {
    case "input":
      return "正在准备素材和任务配置";
    case "subtitleSource":
      return "正在获取可翻译的源字幕";
    case "asr":
      return "正在从音频中识别字幕文本";
    case "translation":
      return "正在生成目标语言字幕";
    case "termConsistency":
      return "正在统一术语和翻译记忆";
    case "qualityReview":
      return "正在检查时间轴、阅读速度和字幕格式";
    case "export":
      return "正在生成交付文件";
    case "completed":
      return "可以检查结果和打开输出文件";
    case "failed":
      return "可以查看错误并按条件恢复任务";
    case "idle":
    default:
      return "等待任务事件";
  }
}

function phaseTone(phase: TaskPhase): PresentationTone {
  if (phase === "completed") return "success";
  if (phase === "failed") return "danger";
  if (phase === "idle") return "neutral";
  return "info";
}

function outputStatusTone(status: ExportedFile["status"]): PresentationTone {
  if (status === "ready") return "success";
  if (status === "stale") return "warning";
  if (status === "failed") return "danger";
  return "neutral";
}

function outputStatusLabel(status: ExportedFile["status"]): string {
  if (status === "ready") return "已导出";
  if (status === "stale") return "待重新导出";
  if (status === "failed") return "导出失败";
  return "未生成";
}

function deliveryState(files: PresentedOutputFile[], savedPendingExport: boolean): { label: string; tone: PresentationTone } {
  if (savedPendingExport) return { label: "修改已保存，待重新导出", tone: "warning" };
  if (files.length === 0) return { label: "未生成输出", tone: "neutral" };
  if (files.some((file) => file.status === "failed")) return { label: "部分输出失败", tone: "danger" };
  if (files.some((file) => file.status === "stale")) return { label: "待重新导出", tone: "warning" };
  return { label: "输出已就绪", tone: "success" };
}

function saveStateLabel(state: ResultWorkspaceFacts["saveState"]): string {
  switch (state) {
    case "loading":
      return "正在读取";
    case "dirty":
      return "有未保存修改";
    case "saving":
      return "正在保存";
    case "savedPendingExport":
      return "已保存，待重新导出";
    case "error":
      return "保存或导出失败";
    case "clean":
      return "保存状态正常";
    case "notOpened":
    default:
      return "未打开结果";
  }
}

function saveStateTone(state: ResultWorkspaceFacts["saveState"]): PresentationTone {
  if (state === "savedPendingExport" || state === "dirty") return "warning";
  if (state === "error") return "danger";
  if (state === "notOpened" || state === "loading" || state === "saving") return "neutral";
  return "success";
}

function uniqueFormats(formats: ExportFormat[]): ExportFormat[] {
  return formats.filter((format, index) => formats.indexOf(format) === index);
}
