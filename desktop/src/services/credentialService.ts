import { invokeCommand } from "./tauriClient";

export type CredentialBoundary = {
  storageLabel: string;
  secretValuesNeverRendered: boolean;
  yamlStoresSecrets: false;
};

export function getCredentialBoundary(): CredentialBoundary {
  return {
    storageLabel: "~/.transvortex/auth.json",
    secretValuesNeverRendered: true,
    yamlStoresSecrets: false,
  };
}

export async function saveApiKeyCredential(credentialId: string, apiKey: string): Promise<{ ok: boolean; credential_id: string; auth_file: string }> {
  return invokeCommand<{ ok: boolean; credential_id: string; auth_file: string }>("save_auth_credential", {
    credentialId,
    apiKey,
  });
}

export async function listSavedCredentials(): Promise<unknown> {
  return invokeCommand<unknown>("list_auth_credentials");
}
