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
