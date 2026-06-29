import { lazy, Suspense, useCallback, useEffect, useMemo } from "react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { taskToPresentation } from "../adapters/taskPresentationAdapter";
import {
  ASR_SELECTION_EVENT,
  CONFIG_UPDATED_EVENT,
  configKindFromLabel,
  type ConfigWindowKind,
  type AsrSelectionPayload,
} from "../services/configWindowService";
import { openPath } from "../services/fileService";
import { useEnvironmentStore } from "../state/environmentStore";
import { useProviderStore } from "../state/providerStore";
import { useResultWorkspaceStore } from "../state/resultWorkspaceStore";
import { useTaskRunStore } from "../state/taskRunStore";
import { useTaskStore } from "../state/taskStore";

const ClientHomePage = lazy(() => import("../pages/ClientHomePage/ClientHomePage").then((module) => ({ default: module.ClientHomePage })));
const ConfigWindowPage = lazy(() => import("../pages/ConfigWindowPage/ConfigWindowPage").then((module) => ({ default: module.ConfigWindowPage })));

export function App() {
  const windowLabel = currentWindowLabel();
  const configKind = configKindFromLabel(windowLabel);

  if (configKind) {
    return (
      <Suspense fallback={<WindowBootSurface />}>
        <ConfigWindowApp kind={configKind} />
      </Suspense>
    );
  }

  return (
    <Suspense fallback={<WindowBootSurface />}>
      <MainWindowApp />
    </Suspense>
  );
}

function ConfigWindowApp({ kind }: { kind: ConfigWindowKind }) {
  const providerStore = useProviderStore();

  return (
    <ConfigWindowPage
      kind={kind}
      connections={providerStore.connections}
      loading={providerStore.loading}
      workingConnectionId={providerStore.workingConnectionId}
      reports={providerStore.connectionReports}
      onSaveApiKey={providerStore.saveApiKey}
      onTestConnection={providerStore.testConnection}
      onFetchModels={providerStore.fetchModels}
      onSaveRouting={providerStore.saveRouting}
    />
  );
}

function MainWindowApp() {
  const providerStore = useProviderStore();
  const taskStore = useTaskStore(providerStore.connections);
  const environmentStore = useEnvironmentStore();
  const selectedTask = taskStore.activeTaskId
    ? taskStore.tasks.find((task) => task.id === taskStore.activeTaskId)
    : findTaskForDraftSource(taskStore.tasks, taskStore.draft?.input.path);
  const taskRunStore = useTaskRunStore(selectedTask?.id);
  const resultWorkspace = useResultWorkspaceStore(selectedTask?.id);
  const selectedTaskPresentation = useMemo(
    () => selectedTask
      ? taskToPresentation({
        task: selectedTask,
        taskRun: taskRunStore.currentRun,
        workspace: resultWorkspace,
      })
      : undefined,
    [resultWorkspace, selectedTask, taskRunStore.currentRun],
  );
  const openTaskPath = (path: string) => {
    void openPath(path);
  };
  const refreshAll = useCallback(
    () => Promise.all([providerStore.refresh(), environmentStore.refresh(), taskStore.refreshTasks(), taskRunStore.refresh()]).then(() => undefined),
    [environmentStore, providerStore, taskRunStore, taskStore],
  );
  const updateAsrSelection = useCallback((payload: AsrSelectionPayload) => {
    taskStore.updateDraft((draft) => ({
      ...draft,
      subtitleSource: payload.mode === "none"
        ? { mode: "auto" }
        : payload.mode === "cloud"
          ? { mode: "cloudAsr" }
          : payload.mode === "local"
            ? { mode: "localAsr" }
            : { mode: "auto" },
      speechRecognition: {
        ...draft.speechRecognition,
        mode: payload.mode,
        target: payload.providerName
          ? { providerName: payload.providerName, model: payload.model }
        : draft.speechRecognition.target,
      },
    }));
  }, [taskStore]);

  useConfigSync(refreshAll, updateAsrSelection);

  return (
    <ClientHomePage
      draft={taskStore.draft}
      loading={taskStore.loading || providerStore.loading || environmentStore.loading}
      starting={taskStore.starting}
      cancelingTaskId={taskStore.cancelingTaskId}
      activeTask={selectedTask}
      activeTaskPresentation={selectedTaskPresentation}
      currentRun={taskRunStore.currentRun}
      recentTasks={taskStore.tasks}
      serviceConnections={providerStore.connections}
      environmentChecks={environmentStore.checks}
      providerError={providerStore.error}
      environmentError={environmentStore.error}
      taskError={taskStore.error}
      workspaceError={resultWorkspace.error}
      onPickInput={taskStore.updateInputPath}
      onPickOutputDirectory={taskStore.updateOutputDirectory}
      onPatchDraft={taskStore.updateDraft}
      onStartTask={async () => {
        await taskStore.startDraftTask();
        await taskRunStore.refresh();
      }}
      onOpenPath={openTaskPath}
      onCancelTask={(taskId) => taskStore.cancelStoredTask(taskId).then(() => taskRunStore.refresh())}
      onResumeTask={(taskId) => taskStore.resumeStoredTask(taskId).then(() => taskRunStore.refresh())}
    />
  );
}

function findTaskForDraftSource(tasks: ReturnType<typeof useTaskStore>["tasks"], inputPath?: string) {
  if (!inputPath) return undefined;
  const normalizedInput = normalizePathForMatch(inputPath);
  return tasks.find((task) => {
    const taskInput = task.input.path ? normalizePathForMatch(task.input.path) : "";
    return taskInput === normalizedInput && ["starting", "running", "cancelRequested", "interrupted", "failedRecoverable", "completed"].includes(task.status);
  });
}

function normalizePathForMatch(path: string) {
  return path.replace(/\\/g, "/").toLowerCase();
}

function currentWindowLabel() {
  if (!("__TAURI_INTERNALS__" in window)) return "main";
  return getCurrentWindow().label;
}

function WindowBootSurface() {
  return <div style={{ width: "100%", height: "100%", background: "#fff7f0" }} />;
}

function useConfigSync(onRefresh: () => Promise<void>, onAsrSelection: (payload: AsrSelectionPayload) => void) {
  useEffect(() => {
    let alive = true;
    let unlistenConfig: (() => void) | undefined;
    let unlistenAsr: (() => void) | undefined;

    async function attach() {
      unlistenConfig = await listen(CONFIG_UPDATED_EVENT, () => {
        if (alive) void onRefresh();
      });
      unlistenAsr = await listen<AsrSelectionPayload>(ASR_SELECTION_EVENT, (event) => {
        if (!alive) return;
        onAsrSelection(event.payload);
      });
    }

    void attach();
    return () => {
      alive = false;
      unlistenConfig?.();
      unlistenAsr?.();
    };
  }, [onAsrSelection, onRefresh]);
}
