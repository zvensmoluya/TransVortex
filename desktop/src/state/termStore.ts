import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { TermEntry } from "../domain/term";
import { openTaskResultDetails } from "../services/resultWorkspaceService";

export function useTermStore(taskId?: string) {
  const [terms, setTerms] = useState<TermEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<UserFacingError>();

  const refresh = useCallback(async () => {
    if (!taskId) {
      setTerms([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      const payload = await openTaskResultDetails(taskId);
      const memory = isRecord(payload) && isRecord(payload.memory) ? payload.memory : undefined;
      setTerms(termEntriesFromMemory(memory));
      setError(undefined);
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
    } finally {
      setLoading(false);
    }
  }, [taskId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return useMemo(
    () => ({
      terms,
      loading,
      error,
      refresh,
    }),
    [terms, loading, error, refresh],
  );
}

function termEntriesFromMemory(memory: unknown): TermEntry[] {
  if (!isRecord(memory)) {
    return [];
  }
  const entryItems = Array.isArray(memory.entry_items) ? memory.entry_items.filter(isRecord) : [];
  const presetItems = Array.isArray(memory.preset_items) ? memory.preset_items.filter(isRecord) : [];
  return [...entryItems, ...presetItems].map((entry, index) => ({
    id: stringValue(entry.id) || `term-${index + 1}`,
    source: stringValue(entry.source) || "",
    target: stringValue(entry.target) || "",
    type: mapType(stringValue(entry.category)),
    status: mapStatus(stringValue(entry.status)),
    scope: mapScope(isRecord(entry.scope) ? stringValue(entry.scope.type) : undefined),
    note: stringValue(entry.notes),
    relatedSegmentIds: Array.isArray(entry.evidence_ids) ? entry.evidence_ids.map(String) : [],
  }));
}

function mapType(category?: string): TermEntry["type"] {
  if (category === "name") return "person";
  if (category === "place") return "address";
  if (category === "title") return "title";
  if (category === "phrase") return "phrase";
  return "term";
}

function mapStatus(status?: string): TermEntry["status"] {
  if (status === "locked") return "locked";
  if (status === "confirmed") return "confirmed";
  return "proposed";
}

function mapScope(scope?: string): TermEntry["scope"] {
  if (scope === "global") return "global";
  if (scope === "project") return "project";
  return "task";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
