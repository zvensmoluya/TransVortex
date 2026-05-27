import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { TermEntry, TermPresetExportRequest, TermStatusUpdate } from "../domain/term";
import { openTaskResultDetails, updateTaskMemoryEntryStatus } from "../services/resultWorkspaceService";
import { exportTaskMemoryPreset, type TermPresetExportResult } from "../services/termService";

export function useTermStore(taskId?: string) {
  const [terms, setTerms] = useState<TermEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [savingTermId, setSavingTermId] = useState<string>();
  const [exportResult, setExportResult] = useState<TermPresetExportResult>();
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

  const updateStatus = useCallback(async (update: TermStatusUpdate) => {
    if (!taskId) return;
    setSavingTermId(update.termId);
    try {
      await updateTaskMemoryEntryStatus(taskId, update.termId, update.status);
      await refresh();
      setError(undefined);
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
    } finally {
      setSavingTermId(undefined);
    }
  }, [refresh, taskId]);

  const exportPreset = useCallback(async (request: Omit<TermPresetExportRequest, "taskId">) => {
    if (!taskId) return undefined;
    setLoading(true);
    try {
      const result = await exportTaskMemoryPreset({ ...request, taskId });
      setExportResult(result);
      setError(undefined);
      return result;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
      return undefined;
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
      savingTermId,
      exportResult,
      error,
      refresh,
      updateStatus,
      exportPreset,
    }),
    [terms, loading, savingTermId, exportResult, error, refresh, updateStatus, exportPreset],
  );
}

function termEntriesFromMemory(memory: unknown): TermEntry[] {
  if (!isRecord(memory)) {
    return [];
  }
  const entryItems = Array.isArray(memory.entry_items) ? memory.entry_items.filter(isRecord) : [];
  const presetItems = Array.isArray(memory.preset_items) ? memory.preset_items.filter(isRecord) : [];
  return [
    ...entryItems.map((entry, index) => termEntryFromMemoryItem(entry, index, "runtime" as const)),
    ...presetItems.map((entry, index) => termEntryFromMemoryItem(entry, index + entryItems.length, "preset" as const)),
  ];
}

function termEntryFromMemoryItem(entry: Record<string, unknown>, index: number, origin: TermEntry["origin"]): TermEntry {
  return {
    id: stringValue(entry.id) || `term-${index + 1}`,
    source: stringValue(entry.source) || "",
    target: stringValue(entry.target) || "",
    type: mapType(stringValue(entry.category)),
    status: mapStatus(stringValue(entry.status)),
    scope: origin === "preset" ? "project" : mapScope(isRecord(entry.scope) ? stringValue(entry.scope.type) : undefined),
    origin: origin === "runtime" && mapStatus(stringValue(entry.status)) === "proposed" ? "suggestion" : origin,
    editable: origin === "runtime",
    note: stringValue(entry.notes),
    relatedSegmentIds: Array.isArray(entry.evidence_ids) ? entry.evidence_ids.map(String) : [],
  };
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
