import { taskDraftToStartTaskPayload } from "../adapters/taskDraftAdapter";
import { taskRecordsToTasks } from "../adapters/taskRecordAdapter";
import type { Task, TaskDraft } from "../domain/task";
import { invokeCommand } from "./tauriClient";

export type StartTaskResponse = {
  started: boolean;
};

export async function listTasks(): Promise<Task[]> {
  const payload = await invokeCommand<unknown>("list_tasks");
  return taskRecordsToTasks(payload);
}

export async function startTask(draft: TaskDraft): Promise<StartTaskResponse> {
  return invokeCommand<StartTaskResponse>("start_task", {
    request: taskDraftToStartTaskPayload(draft),
  });
}

export async function resumeTask(taskId: string, draft?: Partial<TaskDraft>): Promise<StartTaskResponse> {
  return invokeCommand<StartTaskResponse>("resume_task", {
    request: {
      taskId,
      ...(draft ? taskDraftToStartTaskPayload(draft as TaskDraft) : {}),
    },
  });
}

export async function cancelTask(): Promise<{ cancelled: boolean }> {
  return invokeCommand<{ cancelled: boolean }>("cancel_task");
}
