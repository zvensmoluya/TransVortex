import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { ServiceConnection } from "../domain/serviceConnection";
import { getCredentialBoundary } from "../services/credentialService";
import { listAllServiceConnections } from "../services/providerService";

export function useProviderStore() {
  const [connections, setConnections] = useState<ServiceConnection[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<UserFacingError>();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setConnections(await listAllServiceConnections());
      setError(undefined);
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "provider"));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return useMemo(
    () => ({
      connections,
      credentialBoundary: getCredentialBoundary(),
      loading,
      error,
      refresh,
    }),
    [connections, loading, error, refresh],
  );
}
