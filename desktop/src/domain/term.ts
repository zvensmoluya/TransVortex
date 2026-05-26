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
  note?: string;
  relatedSegmentIds: string[];
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
