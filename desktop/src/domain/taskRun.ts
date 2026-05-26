import type { UserFacingError, UserFacingWarning } from "./error";

export type TaskPhase =
  | "idle"
  | "input"
  | "subtitleSource"
  | "asr"
  | "translation"
  | "termConsistency"
  | "qualityReview"
  | "export"
  | "completed"
  | "failed";

export type ProgressState = {
  percent: number;
  completedUnits?: number;
  totalUnits?: number;
  label: string;
};

export type TimelineEvent = {
  id: string;
  at: string;
  phase: TaskPhase;
  title: string;
  detail?: string;
  severity: "info" | "success" | "warning" | "error";
};

export type TaskPipelineStep = {
  id: TaskPhase;
  label: string;
  status: "pending" | "active" | "completed" | "failed";
};

export type TaskRun = {
  taskId: string;
  phase: TaskPhase;
  currentAction: string;
  progress: ProgressState;
  timeline: TimelineEvent[];
  warnings: UserFacingWarning[];
  error?: UserFacingError;
  canCancel: boolean;
  canResume: boolean;
  lastEventAt?: string;
};
