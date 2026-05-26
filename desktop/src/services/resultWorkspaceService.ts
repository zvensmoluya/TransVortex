import { resultWorkspaceToSegments, segmentsToSavePayload } from "../adapters/resultWorkspaceAdapter";
import type { Segment } from "../domain/segment";
import { invokeCommand } from "./tauriClient";

export async function openTaskResult(taskId: string): Promise<Segment[]> {
  const payload = await invokeCommand<unknown>("open_task_result", { taskId });
  return resultWorkspaceToSegments(payload);
}

export async function openTaskResultDetails(taskId: string): Promise<unknown> {
  return invokeCommand<unknown>("open_task_result", { taskId });
}

export async function saveTaskSegments(taskId: string, segments: Segment[]): Promise<{ saved: boolean }> {
  return invokeCommand<{ saved: boolean }>("save_task_segments", {
    taskId,
    segments: segmentsToSavePayload(segments),
  });
}
