export type TermEntryType = "person" | "address" | "term" | "title" | "asr_correction" | "phrase";
export type TermEntryStatus = "proposed" | "confirmed" | "locked";
export type TermEntryScope = "task" | "project" | "global";

export type TermEntry = {
  id: string;
  source: string;
  target: string;
  type: TermEntryType;
  status: TermEntryStatus;
  scope: TermEntryScope;
  origin: "runtime" | "preset" | "suggestion";
  editable: boolean;
  note?: string;
  relatedSegmentIds: string[];
};

export type TermStatusUpdate = {
  termId: string;
  status: Extract<TermEntryStatus, "confirmed" | "locked">;
};

export type TermPresetExportRequest = {
  taskId: string;
  presetId: string;
  name?: string;
  description?: string;
  defaultStatus: TermEntryStatus;
  overwrite?: boolean;
};

export type TermMatch = {
  termId: string;
  source: string;
  expectedTarget: string;
  status: "matched" | "missing" | "conflict";
};

export type TermUsageSettings = {
  selectedTermBaseId?: string;
  useProjectTerms: boolean;
  allowSystemSuggestions: boolean;
  enforceLockedTerms: boolean;
};
