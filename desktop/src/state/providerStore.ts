import { useMemo } from "react";
import { getCredentialBoundary } from "../services/credentialService";
import { mockServiceConnections } from "./mockData";

export function useProviderStore() {
  return useMemo(
    () => ({
      connections: mockServiceConnections,
      credentialBoundary: getCredentialBoundary(),
    }),
    [],
  );
}
