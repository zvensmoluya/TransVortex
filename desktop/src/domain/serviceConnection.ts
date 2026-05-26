export type ServiceKind = "translation" | "asr";

export type CredentialStatus = {
  state: "saved" | "missing" | "invalid" | "notRequired";
  source?: "user_auth_file" | "environment" | "development_env";
  label: string;
};

export type ConnectionStatus = {
  state: "connected" | "untested" | "failed" | "checking";
  label: string;
  checkedAt?: string;
  message?: string;
};

export type ServiceTarget = {
  providerName: string;
  model?: string;
};

export type ServiceConnection = {
  id: string;
  kind: ServiceKind;
  providerName: string;
  displayName: string;
  model?: string;
  credentialStatus: CredentialStatus;
  connectionStatus: ConnectionStatus;
  isDefault: boolean;
  fallbackTargets: ServiceTarget[];
  expertConfigAvailable: boolean;
};
