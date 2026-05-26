import { useCallback, useEffect, useMemo, useState } from "react";
import { configToTaskDraft, updateDraftInput } from "../adapters/taskDraftDefaults";
import type { Task, TaskDraft } from "../domain/task";
import { getProviderConfig } from "../services/providerService";
import { listTasks, startTask } from "../services/taskService";
import { technicalErrorToUserFacingError } from "../adapters/errorAdapter";
import type { UserFacingError } from "../domain/error";
import type { ServiceConnection } from "../domain/serviceConnection";

export type TaskStoreState = {
  draft?: TaskDraft;
  tasks: Task[];
  recentReviewTask?: Task;
  activeTaskId?: string;
  loading: boolean;
  starting: boolean;
  error?: UserFacingError;
  setDraft: (draft: TaskDraft) => void;
  updateInputPath: (path: string) => void;
  updateOutputDirectory: (path: string) => void;
  refreshTasks: () => Promise<Task[]>;
  startDraftTask: () => Promise<string | undefined>;
};

export function useTaskStore(serviceConnections: ServiceConnection[] = []): TaskStoreState {
  const [draft, setDraft] = useState<TaskDraft>();
  const [tasks, setTasks] = useState<Task[]>([]);
  const [activeTaskId, setActiveTaskId] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<UserFacingError>();

  const refreshTasks = useCallback(async (): Promise<Task[]> => {
    setLoading(true);
    try {
      const latest = await listTasks();
      setTasks(latest);
      setError(undefined);
      return latest;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
      return [];
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function loadInitialState() {
      try {
        const [config, taskList] = await Promise.all([getProviderConfig(), listTasks()]);
        if (cancelled) return;
        setTasks(taskList);
        setDraft((previous) => configToTaskDraft(config, serviceConnections, previous));
        setError(undefined);
      } catch (err) {
        if (!cancelled) setError(technicalErrorToUserFacingError(err, "worker"));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    loadInitialState();
    return () => {
      cancelled = true;
    };
  }, [serviceConnections]);

  const updateInputPath = useCallback((path: string) => {
    setDraft((current) => current ? updateDraftInput(current, path) : current);
  }, []);

  const updateOutputDirectory = useCallback((path: string) => {
    setDraft((current) => current ? { ...current, output: { ...current.output, outputDirectory: path } } : current);
  }, []);

  const startDraftTask = useCallback(async () => {
    if (!draft?.input.path) {
      setError({
        title: "还没有选择素材",
        impact: "请选择本地音视频或 SRT 字幕后再开始任务。",
        severity: "blocking",
        source: "filesystem",
        nextActions: [{ id: "choose-file", label: "选择文件" }],
      });
      return undefined;
    }

    setStarting(true);
    try {
      const response = await startTask(draft);
      setError(undefined);
      const taskId = response.taskId;
      if (taskId) {
        setActiveTaskId(taskId);
      }
      const latest = await refreshTasks();
      return taskId || latest[0]?.id;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
      return undefined;
    } finally {
      setStarting(false);
    }
  }, [draft, refreshTasks]);

  const recentReviewTask = useMemo(
    () => tasks.find((task) => task.outputs.length > 0 && task.status === "completed") ?? tasks.find((task) => task.outputs.length > 0),
    [tasks],
  );

  return {
    draft,
    tasks,
    recentReviewTask,
    activeTaskId,
    loading,
    starting,
    error,
    setDraft,
    updateInputPath,
    updateOutputDirectory,
    refreshTasks,
    startDraftTask,
  };
}
