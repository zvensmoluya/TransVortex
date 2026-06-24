import { useMemo } from "react";
import { taskToPresentation } from "../adapters/taskPresentationAdapter";
import { ClientHomePage } from "../pages/ClientHomePage/ClientHomePage";
import { openPath } from "../services/fileService";
import { useEnvironmentStore } from "../state/environmentStore";
import { useProviderStore } from "../state/providerStore";
import { useResultWorkspaceStore } from "../state/resultWorkspaceStore";
import { useTaskRunStore } from "../state/taskRunStore";
import { useTaskStore } from "../state/taskStore";

export function App() {
  const providerStore = useProviderStore();
  const taskStore = useTaskStore(providerStore.connections);
  const environmentStore = useEnvironmentStore();
  const activeHomeTask = taskStore.activeTaskId
    ? taskStore.tasks.find((task) => task.id === taskStore.activeTaskId)
    : taskStore.tasks.find((task) => ["starting", "running", "cancelRequested", "failedRecoverable"].includes(task.status));
  const selectedTask = activeHomeTask;
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

  return (
    <ClientHomePage
      draft={taskStore.draft}
      loading={taskStore.loading || providerStore.loading || environmentStore.loading}
      starting={taskStore.starting}
      activeTask={selectedTask}
      activeTaskPresentation={selectedTaskPresentation}
      currentRun={taskRunStore.currentRun}
      serviceConnections={providerStore.connections}
      environmentChecks={environmentStore.checks}
      providerError={providerStore.error}
      environmentError={environmentStore.error}
      taskError={taskStore.error}
      workspaceError={resultWorkspace.error}
      onPickInput={taskStore.updateInputPath}
      onPickOutputDirectory={taskStore.updateOutputDirectory}
      onDraftChange={taskStore.updateDraft}
      onSaveApiKey={providerStore.saveApiKey}
      onStartTask={async () => {
        await taskStore.startDraftTask();
        await taskRunStore.refresh();
      }}
      onRefresh={() => Promise.all([providerStore.refresh(), environmentStore.refresh(), taskStore.refreshTasks(), taskRunStore.refresh()]).then(() => undefined)}
      onOpenPath={openTaskPath}
      onCancelTask={(taskId) => taskStore.cancelStoredTask(taskId).then(() => taskRunStore.refresh())}
    />
  );
}
