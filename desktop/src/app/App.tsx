import { useMemo } from "react";
import { taskToPresentation } from "../adapters/taskPresentationAdapter";
import { AppShell } from "./layout/AppShell";
import { getTaskDetailPath, getTaskReviewPath, useAppRouter } from "./router";
import { EnvironmentDiagnosticsPage } from "../pages/EnvironmentDiagnosticsPage/EnvironmentDiagnosticsPage";
import { ModelCredentialsPage } from "../pages/ModelCredentialsPage/ModelCredentialsPage";
import { NewTaskPage } from "../pages/NewTaskPage/NewTaskPage";
import { ResultReviewPage } from "../pages/ResultReviewPage/ResultReviewPage";
import { SettingsPage } from "../pages/SettingsPage/SettingsPage";
import { TaskDetailPage } from "../pages/TaskDetailPage/TaskDetailPage";
import { TaskHistoryPage } from "../pages/TaskHistoryPage/TaskHistoryPage";
import { TermsPage } from "../pages/TermsPage/TermsPage";
import { openPath } from "../services/fileService";
import { useEnvironmentStore } from "../state/environmentStore";
import { useProviderStore } from "../state/providerStore";
import { useResultWorkspaceStore } from "../state/resultWorkspaceStore";
import { useTaskRunStore } from "../state/taskRunStore";
import { useTaskStore } from "../state/taskStore";
import { useTermStore } from "../state/termStore";

export function App() {
  const { route, navigate } = useAppRouter();
  const providerStore = useProviderStore();
  const taskStore = useTaskStore(providerStore.connections);
  const environmentStore = useEnvironmentStore();
  const recentReviewTask = taskStore.recentReviewTask ?? taskStore.tasks[0];
  const selectedTask = route.params.taskId
    ? taskStore.tasks.find((task) => task.id === route.params.taskId)
    : recentReviewTask;
  const taskRunStore = useTaskRunStore(selectedTask?.id);
  const resultWorkspace = useResultWorkspaceStore(selectedTask?.id);
  const termStore = useTermStore(selectedTask?.id);
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

  const page = useMemo(() => {
    switch (route.id) {
      case "new-task":
        return (
          <NewTaskPage
            draft={taskStore.draft}
            loading={taskStore.loading || providerStore.loading || environmentStore.loading}
            starting={taskStore.starting}
            serviceConnections={providerStore.connections}
            environmentChecks={environmentStore.checks}
            providerError={providerStore.error}
            environmentError={environmentStore.error}
            taskError={taskStore.error}
            onPickInput={taskStore.updateInputPath}
            onPickOutputDirectory={taskStore.updateOutputDirectory}
            onStartTask={async () => {
              const taskId = await taskStore.startDraftTask();
              if (taskId) {
                navigate(getTaskDetailPath(taskId));
              }
            }}
            onRefresh={() => Promise.all([providerStore.refresh(), environmentStore.refresh(), taskStore.refreshTasks()]).then(() => undefined)}
          />
        );
      case "tasks":
        return (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            loading={taskStore.loading}
            error={taskStore.error}
            onRefresh={() => taskStore.refreshTasks().then(() => undefined)}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "task-detail":
        return selectedTask ? (
          <TaskDetailPage
            task={selectedTask}
            taskRun={taskRunStore.currentRun}
            presentation={selectedTaskPresentation ?? taskToPresentation({ task: selectedTask, taskRun: taskRunStore.currentRun })}
            loading={taskRunStore.loading}
            error={taskRunStore.error}
            onRefresh={() => Promise.all([taskRunStore.refresh(), taskStore.refreshTasks()]).then(() => undefined)}
            onCancel={() => taskStore.cancelStoredTask(selectedTask.id).then(() => taskRunStore.refresh())}
            onResume={async () => {
              const taskId = await taskStore.resumeStoredTask(selectedTask.id);
              if (taskId) {
                navigate(getTaskDetailPath(taskId));
              }
            }}
            onOpenPath={openTaskPath}
            onReexport={() => navigate(getTaskReviewPath(selectedTask.id))}
            onOpenReview={() => navigate(getTaskReviewPath(selectedTask.id))}
          />
        ) : (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            loading={taskStore.loading}
            error={taskStore.error}
            onRefresh={() => taskStore.refreshTasks().then(() => undefined)}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "result-review":
        return selectedTask ? (
          <ResultReviewPage
            workspace={resultWorkspace}
            presentation={selectedTaskPresentation ?? taskToPresentation({ task: selectedTask, taskRun: taskRunStore.currentRun, workspace: resultWorkspace })}
            terms={termStore.terms}
            taskRun={taskRunStore.currentRun}
            onRefreshTask={() => taskStore.refreshTasks().then(() => undefined)}
            onOpenPath={openTaskPath}
          />
        ) : (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            loading={taskStore.loading}
            error={taskStore.error}
            onRefresh={() => taskStore.refreshTasks().then(() => undefined)}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "terms":
        return <TermsPage terms={termStore.terms} loading={termStore.loading} error={termStore.error} onRefresh={termStore.refresh} />;
      case "services":
        return <ModelCredentialsPage connections={providerStore.connections} credentialBoundary={providerStore.credentialBoundary} loading={providerStore.loading} error={providerStore.error} onRefresh={providerStore.refresh} />;
      case "diagnostics":
        return <EnvironmentDiagnosticsPage checks={environmentStore.checks} loading={environmentStore.loading} error={environmentStore.error} onRefresh={environmentStore.refresh} />;
      case "settings":
        return <SettingsPage />;
    }
  }, [environmentStore, navigate, providerStore, resultWorkspace, route.id, selectedTask, selectedTaskPresentation, taskRunStore, taskStore, termStore]);

  return (
    <AppShell
      activeRouteId={route.id}
      currentRun={taskRunStore.currentRun}
      recentReviewTaskId={recentReviewTask?.id}
      onNavigate={navigate}
    >
      {page}
    </AppShell>
  );
}
