import type { SubtitleIssue } from "./subtitleIssue";
import type { TermMatch } from "./term";

export type SegmentDirtyState = "clean" | "dirty" | "saving" | "savedPendingExport";

export type SegmentDiagnostics = {
  charactersPerSecond: number;
  lineCount: number;
  maxLineLength: number;
  overlapsPrevious: boolean;
};

export type Segment = {
  id: string;
  index: number;
  startMs: number;
  endMs: number;
  sourceText: string;
  translatedText: string;
  issues: SubtitleIssue[];
  termMatches: TermMatch[];
  diagnostics: SegmentDiagnostics;
  dirtyState: SegmentDirtyState;
};
