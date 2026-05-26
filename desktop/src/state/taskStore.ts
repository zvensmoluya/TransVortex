import { useMemo } from "react";
import { mockTaskDraft, mockTasks } from "./mockData";

export function useTaskStore() {
  return useMemo(() => {
    const recentReviewTask = mockTasks.find((task) => task.outputs.length > 0);
    return {
      draft: mockTaskDraft,
      tasks: mockTasks,
      recentReviewTask,
    };
  }, []);
}
