import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { EnvironmentCheck } from "../domain/environment";
import type { UserFacingError } from "../domain/error";
import { runEnvironmentDoctor } from "../services/environmentService";

export function useEnvironmentStore() {
  const [checks, setChecks] = useState<EnvironmentCheck[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<UserFacingError>();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setChecks(await runEnvironmentDoctor());
      setError(undefined);
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "environment"));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return useMemo(
    () => ({
      checks,
      loading,
      error,
      refresh,
    }),
    [checks, loading, error, refresh],
  );
}
