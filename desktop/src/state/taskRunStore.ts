import { useMemo } from "react";
import { mockTaskRun } from "./mockData";

export function useTaskRunStore(taskId?: string) {
  return useMemo(
    () => ({
      currentRun: taskId === mockTaskRun.taskId ? mockTaskRun : undefined,
    }),
    [taskId],
  );
}
