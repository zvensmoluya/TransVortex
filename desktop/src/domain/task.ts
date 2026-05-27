import type { UserFacingError } from "./error";
import type { ExportedFile, ExportSettings } from "./export";
import type { ServiceTarget } from "./serviceConnection";
import type { TaskPipelineStep } from "./taskRun";
import type { TermUsageSettings } from "./term";

export type TaskStatus =
  | "draft"
  | "ready"
  | "starting"
  | "running"
  | "cancelRequested"
  | "cancelled"
  | "failedRecoverable"
  | "failedFatal"
  | "completed";

export type TaskInputKind = "video" | "subtitle" | "segments";

export type TaskInput = {
  kind: TaskInputKind;
  path?: string;
  displayName: string;
};

export type TaskInputSummary = TaskInput & {
  durationLabel?: string;
};

export type LanguageSettings = {
  sourceLanguage: string;
  targetLanguage: string;
};

export type SubtitleSourceChoice =
  | { mode: "auto" }
  | { mode: "embedded"; streamId?: string }
  | { mode: "localAsr" }
  | { mode: "cloudAsr" }
  | { mode: "existingSubtitle"; path?: string };

export type SubtitleStream = {
  id: string;
  index: number;
  codecName: string;
  language: string;
  title: string;
  default: boolean;
  forced: boolean;
  supported: boolean;
};

export type TranslationSettings = {
  target: ServiceTarget;
  style: "natural" | "literal" | "localized" | "learning";
  projectContext: string;
  stylePrompt: string;
};

export type SpeechRecognitionSettings = {
  mode: "auto" | "local" | "cloud" | "none";
  target?: ServiceTarget;
  promptProfileId?: string;
};

export type AdvancedTaskSettings = {
  qualityMode: "conservative" | "balanced";
  compressionEnabled: boolean;
  reflowEnabled: boolean;
};

export type TaskDraft = {
  input: TaskInput;
  languages: LanguageSettings;
  subtitleSource: SubtitleSourceChoice;
  translation: TranslationSettings;
  speechRecognition: SpeechRecognitionSettings;
  terms: TermUsageSettings;
  output: ExportSettings;
  advanced: AdvancedTaskSettings;
};

export type Recoverability = {
  canResume: boolean;
  resumeLabel?: string;
};

export type Task = {
  id: string;
  title: string;
  status: TaskStatus;
  input: TaskInputSummary;
  languages: LanguageSettings;
  pipeline: TaskPipelineStep[];
  outputs: ExportedFile[];
  taskDirectory?: string;
  recoverability: Recoverability;
  error?: UserFacingError;
  createdAt: string;
  updatedAt: string;
};
