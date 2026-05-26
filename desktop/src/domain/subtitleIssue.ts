export type IssueSeverity = "blocking" | "warning" | "info";

export type IssueAction = {
  id: string;
  label: string;
  target?: "segment" | "terms" | "settings" | "diagnostics";
};

export type SubtitleIssue = {
  id: string;
  code: string;
  severity: IssueSeverity;
  title: string;
  description?: string;
  segmentId?: string;
  nextActions: IssueAction[];
};
