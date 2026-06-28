import { useCallback, useEffect, useMemo, useState } from "react";
import { configToTaskDraft, updateDraftInput } from "../adapters/taskDraftDefaults";
import type { Task, TaskDraft } from "../domain/task";
import { getProviderConfig } from "../services/providerService";
import { cancelTask, listTasks, resumeTask, startTask } from "../services/taskService";
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
  cancelingTaskId?: string;
  error?: UserFacingError;
  setDraft: (draft: TaskDraft) => void;
  updateDraft: (updater: (draft: TaskDraft) => TaskDraft) => void;
  updateInputPath: (path: string) => void;
  updateOutputDirectory: (path: string) => void;
  refreshTasks: () => Promise<Task[]>;
  startDraftTask: () => Promise<string | undefined>;
  resumeStoredTask: (taskId: string) => Promise<string | undefined>;
  cancelStoredTask: (taskId: string) => Promise<void>;
};

export function useTaskStore(serviceConnections: ServiceConnection[] = []): TaskStoreState {
  const [draft, setDraft] = useState<TaskDraft>();
  const [tasks, setTasks] = useState<Task[]>([]);
  const [activeTaskId, setActiveTaskId] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [cancelingTaskId, setCancelingTaskId] = useState<string>();
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
    setActiveTaskId(undefined);
  }, []);

  const updateDraft = useCallback((updater: (draft: TaskDraft) => TaskDraft) => {
    setDraft((current) => current ? updater(current) : current);
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

    const knownTaskIds = new Set(tasks.map((task) => task.id));
    setActiveTaskId(undefined);
    setStarting(true);
    try {
      const response = await startTask(draft);
      setError(undefined);
      const taskId = response.taskId ?? await waitForNewTaskId(knownTaskIds);
      if (taskId) {
        setActiveTaskId(taskId);
      }
      const latest = await refreshTasks();
      return taskId ?? latest.find((task) => !knownTaskIds.has(task.id))?.id;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
      return undefined;
    } finally {
      setStarting(false);
    }
  }, [draft, refreshTasks, tasks]);

  const resumeStoredTask = useCallback(async (taskId: string) => {
    setStarting(true);
    try {
      const response = await resumeTask(taskId);
      setError(undefined);
      setActiveTaskId(response.taskId ?? taskId);
      await refreshTasks();
      return response.taskId ?? taskId;
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
      return undefined;
    } finally {
      setStarting(false);
    }
  }, [refreshTasks]);

  const cancelStoredTask = useCallback(async (taskId: string) => {
    setCancelingTaskId(taskId);
    setTasks((current) => current.map((task) => task.id === taskId ? markTaskCancelRequested(task) : task));
    try {
      const cancelledTask = await cancelTask(taskId);
      setTasks((current) => upsertTask(current, cancelledTask));
      setError(undefined);
      await refreshTasks();
    } catch (err) {
      setError(technicalErrorToUserFacingError(err, "worker"));
    } finally {
      setCancelingTaskId((current) => current === taskId ? undefined : current);
    }
  }, [refreshTasks]);

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
    cancelingTaskId,
    error,
    setDraft,
    updateDraft,
    updateInputPath,
    updateOutputDirectory,
    refreshTasks,
    startDraftTask,
    resumeStoredTask,
    cancelStoredTask,
  };
}

async function waitForNewTaskId(knownTaskIds: Set<string>): Promise<string | undefined> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const latest = await listTasks();
    const created = latest.find((task) => !knownTaskIds.has(task.id));
    if (created) return created.id;
    await delay(250);
  }
  return undefined;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function markTaskCancelRequested(task: Task): Task {
  if (task.status === "completed" || task.status === "cancelled" || task.status === "failedFatal") {
    return task;
  }
  return {
    ...task,
    status: "cancelRequested",
    updatedAt: new Date().toISOString(),
  };
}

function upsertTask(tasks: Task[], task: Task): Task[] {
  const index = tasks.findIndex((item) => item.id === task.id);
  if (index < 0) return [task, ...tasks];
  return tasks.map((item, itemIndex) => itemIndex === index ? task : item);
}
