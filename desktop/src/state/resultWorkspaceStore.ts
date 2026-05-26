import { useMemo } from "react";
import type { ExportJob } from "../domain/export";
import type { Segment } from "../domain/segment";
import { mockExportJob, mockSegments } from "./mockData";

export type ResultWorkspaceState = {
  taskId?: string;
  segments: Segment[];
  selectedSegmentId?: string;
  saveState: "clean" | "dirty" | "saving" | "savedPendingExport";
  exportJob: ExportJob;
};

export function useResultWorkspaceStore(taskId?: string): ResultWorkspaceState {
  return useMemo(
    () => ({
      taskId,
      segments: mockSegments,
      selectedSegmentId: mockSegments[2]?.id,
      saveState: "savedPendingExport",
      exportJob: mockExportJob,
    }),
    [taskId],
  );
}
