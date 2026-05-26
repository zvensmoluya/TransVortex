import { useCallback, useEffect, useMemo, useState } from "react";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { TaskRun, TimelineEvent } from "../domain/taskRun";
import { readTaskEvents, subscribeWorkerTimeline } from "../services/taskRunService";

export function useTaskRunStore(taskId?: string) {
  const [currentRun, setCurrentRun] = useState<TaskRun>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<UserFacingError>();

  const refresh = useCallback(async () => {
    if (!taskId) {
      setCurrentRun(undefined);
      return;
    }
    setLoading(true);
    try {
      setCurrentRun(await readTaskEvents(taskId));
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

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;

    subscribeWorkerTimeline((event) => {
      if (disposed || (taskId && event.taskId && event.taskId !== taskId)) {
        return;
      }
      setCurrentRun((current) => mergeTimelineEvent(current, taskId ?? event.taskId ?? "", event));
    }).then((value) => {
      unlisten = value;
    });

    return () => {
      disposed = true;
      if (unlisten) unlisten();
    };
  }, [taskId]);

  return useMemo(
    () => ({
      currentRun,
      loading,
      error,
      refresh,
    }),
    [currentRun, loading, error, refresh],
  );
}

function mergeTimelineEvent(current: TaskRun | undefined, taskId: string, event: TimelineEvent): TaskRun {
  const progressPercent = event.progressPercent ?? current?.progress.percent ?? (event.phase === "completed" ? 100 : 0);
  return {
    taskId: current?.taskId || taskId,
    phase: event.phase,
    currentAction: event.title,
    progress: {
      percent: progressPercent,
      label: event.phase === "completed" ? "已完成" : `进度 ${Math.round(progressPercent)}%`,
    },
    timeline: [...(current?.timeline ?? []), event],
    warnings: current?.warnings ?? [],
    error: current?.error,
    canCancel: event.phase !== "completed" && event.phase !== "failed",
    canResume: event.phase === "failed",
    lastEventAt: event.at,
  };
}
