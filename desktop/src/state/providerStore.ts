import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { ServiceConnection, ServiceTarget } from "../domain/serviceConnection";
import { getCredentialBoundary, saveApiKeyCredential } from "../services/credentialService";
import {
  fetchModelsForConnection,
  listAllServiceConnections,
  saveDefaultAndFallbackModels,
  saveProviderModelList,
  testServiceConnection,
} from "../services/providerService";
import type { ProviderModelsPayload, ProviderTestPayload } from "../types";

export function useProviderStore() {
  const [connections, setConnections] = useState<ServiceConnection[]>([]);
  const [loading, setLoading] = useState(true);
  const [workingConnectionId, setWorkingConnectionId] = useState<string>();
  const [connectionReports, setConnectionReports] = useState<Record<string, ProviderTestPayload | ProviderModelsPayload>>({});
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

  const saveApiKey = useCallback(async (connection: ServiceConnection, apiKey: string) => {
    const credentialId = connection.credentialId ?? connection.providerName;
    setWorkingConnectionId(connection.id);
    try {
      await saveApiKeyCredential(credentialId, apiKey);
      setError(undefined);
      await refresh();
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "provider"));
    } finally {
      setWorkingConnectionId(undefined);
    }
  }, [refresh]);

  const testConnection = useCallback(async (connection: ServiceConnection, model?: string, apiKey?: string) => {
    setWorkingConnectionId(connection.id);
    try {
      const report = await testServiceConnection(connection, model, apiKey);
      setConnectionReports((current) => ({ ...current, [connection.id]: report }));
      setError(undefined);
      await refresh();
      return report;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "provider"));
      return undefined;
    } finally {
      setWorkingConnectionId(undefined);
    }
  }, [refresh]);

  const fetchModels = useCallback(async (connection: ServiceConnection, apiKey?: string) => {
    setWorkingConnectionId(connection.id);
    try {
      const report = await fetchModelsForConnection(connection, apiKey);
      setConnectionReports((current) => ({ ...current, [connection.id]: report }));
      if (report.models.length > 0) {
        await saveProviderModelList(connection, report.models, apiKey);
        await refresh();
      }
      setError(undefined);
      return report;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "provider"));
      return undefined;
    } finally {
      setWorkingConnectionId(undefined);
    }
  }, [refresh]);

  const saveRouting = useCallback(async (primary: ServiceTarget, fallbackTargets: ServiceTarget[] = []) => {
    setLoading(true);
    try {
      await saveDefaultAndFallbackModels(primary, fallbackTargets);
      setError(undefined);
      await refresh();
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "provider"));
    } finally {
      setLoading(false);
    }
  }, [refresh]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return useMemo(
    () => ({
      connections,
      credentialBoundary: getCredentialBoundary(),
      loading,
      workingConnectionId,
      connectionReports,
      error,
      refresh,
      saveApiKey,
      testConnection,
      fetchModels,
      saveRouting,
    }),
    [connections, loading, workingConnectionId, connectionReports, error, refresh, saveApiKey, testConnection, fetchModels, saveRouting],
  );
}
