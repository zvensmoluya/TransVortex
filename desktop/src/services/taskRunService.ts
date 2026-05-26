import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { normalizeWorkerEvents, workerEventToTimelineEvent } from "../adapters/workerEventAdapter";
import type { TaskRun, TimelineEvent } from "../domain/taskRun";
import { invokeCommand } from "./tauriClient";

export async function readTaskEvents(taskId: string): Promise<TaskRun> {
  const payload = await invokeCommand<unknown>("read_events", { taskId });
  return normalizeWorkerEvents(taskId, payload);
}

export async function subscribeWorkerTimeline(onEvent: (event: TimelineEvent) => void): Promise<UnlistenFn> {
  return listen<unknown>("worker-event", (event) => {
    onEvent(workerEventToTimelineEvent(event.payload));
  });
}
