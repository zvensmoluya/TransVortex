import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { ExportFormat, ExportJob } from "../domain/export";
import type { UserFacingError } from "../domain/error";
import type { Segment } from "../domain/segment";
import { reexportTask } from "../services/exportService";
import { openTaskResult, saveTaskSegments } from "../services/resultWorkspaceService";

export type ResultWorkspaceState = {
  taskId?: string;
  segments: Segment[];
  selectedSegmentId?: string;
  saveState: "notOpened" | "loading" | "clean" | "dirty" | "saving" | "savedPendingExport" | "error";
  exportJob: ExportJob;
  error?: UserFacingError;
  setSelectedSegmentId: (segmentId: string) => void;
  updateSegment: (segmentId: string, patch: Partial<Pick<Segment, "sourceText" | "translatedText" | "startMs" | "endMs">>) => void;
  refresh: () => Promise<void>;
  save: () => Promise<void>;
  reexport: (formats: ExportFormat[]) => Promise<void>;
};

const idleExportJob: ExportJob = {
  id: "export-idle",
  taskId: "",
  formats: [],
  status: "idle",
};

export function useResultWorkspaceStore(taskId?: string): ResultWorkspaceState {
  const [segments, setSegments] = useState<Segment[]>([]);
  const [selectedSegmentId, setSelectedSegmentId] = useState<string>();
  const [saveState, setSaveState] = useState<ResultWorkspaceState["saveState"]>(taskId ? "loading" : "notOpened");
  const [exportJob, setExportJob] = useState<ExportJob>(idleExportJob);
  const [error, setError] = useState<UserFacingError>();

  const refresh = useCallback(async () => {
    if (!taskId) {
      setSegments([]);
      setSelectedSegmentId(undefined);
      setSaveState("notOpened");
      return;
    }
    setSaveState("loading");
    try {
      const loaded = await openTaskResult(taskId);
      setSegments(loaded);
      setSelectedSegmentId((current) => current && loaded.some((segment) => segment.id === current) ? current : loaded[0]?.id);
      setSaveState("clean");
      setError(undefined);
    } catch (err) {
      setSaveState("error");
      setError(technicalErrorToUserFacingError(err, "worker"));
    }
  }, [taskId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const updateSegment = useCallback<ResultWorkspaceState["updateSegment"]>((segmentId, patch) => {
    setSegments((current) =>
      current.map((segment) =>
        segment.id === segmentId ? { ...segment, ...patch, dirtyState: "dirty" } : segment,
      ),
    );
    setSaveState("dirty");
  }, []);

  const save = useCallback(async () => {
    if (!taskId) return;
    setSaveState("saving");
    try {
      await saveTaskSegments(taskId, segments);
      setSegments((current) => current.map((segment) => ({ ...segment, dirtyState: "savedPendingExport" })));
      setSaveState("savedPendingExport");
      setError(undefined);
    } catch (err) {
      setSaveState("error");
      setError(technicalErrorToUserFacingError(err, "worker"));
    }
  }, [segments, taskId]);

  const reexport = useCallback(async (formats: ExportFormat[]) => {
    if (!taskId) return;
    setExportJob({
      id: `export-${taskId}`,
      taskId,
      formats,
      status: "exporting",
      updatedAt: new Date().toISOString(),
    });
    try {
      const job = await reexportTask(taskId, { formats });
      setExportJob(job);
      setSegments((current) => current.map((segment) => ({ ...segment, dirtyState: "clean" })));
      setSaveState("clean");
      setError(undefined);
    } catch (err) {
      setExportJob({
        id: `export-${taskId}`,
        taskId,
        formats,
        status: "exportFailed",
        error: err instanceof Error ? err.message : String(err),
        updatedAt: new Date().toISOString(),
      });
      setError(technicalErrorToUserFacingError(err, "worker"));
    }
  }, [taskId]);

  return useMemo(
    () => ({
      taskId,
      segments,
      selectedSegmentId,
      saveState,
      exportJob,
      error,
      setSelectedSegmentId,
      updateSegment,
      refresh,
      save,
      reexport,
    }),
    [taskId, segments, selectedSegmentId, saveState, exportJob, error, updateSegment, refresh, save, reexport],
  );
}
