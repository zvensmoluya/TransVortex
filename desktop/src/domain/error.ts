export type ErrorSeverity = "blocking" | "warning" | "info";

export type ErrorAction = {
  id: string;
  label: string;
  target?: string;
};

export type UserFacingError = {
  title: string;
  impact: string;
  nextActions: ErrorAction[];
  severity: ErrorSeverity;
  technicalDetail?: string;
  source?: "worker" | "provider" | "asr" | "filesystem" | "environment";
};

export type UserFacingWarning = Omit<UserFacingError, "severity"> & {
  severity: "warning" | "info";
};
