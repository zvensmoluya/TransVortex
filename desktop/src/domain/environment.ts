export type DiagnosticStatus = "pass" | "warn" | "fail";
export type DiagnosticCategory = "blocking" | "quality_risk" | "optional";

export type DiagnosticAction = {
  id: string;
  label: string;
  target?: string;
  kind?: "navigate" | "openPath" | "refresh";
};

export type EnvironmentCheck = {
  id: string;
  label: string;
  status: DiagnosticStatus;
  category: DiagnosticCategory;
  impact: string;
  nextActions: DiagnosticAction[];
  technicalDetail?: string;
};
