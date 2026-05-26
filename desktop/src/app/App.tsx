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
import { useEnvironmentStore } from "../state/environmentStore";
import { useProviderStore } from "../state/providerStore";
import { useResultWorkspaceStore } from "../state/resultWorkspaceStore";
import { useTaskRunStore } from "../state/taskRunStore";
import { useTaskStore } from "../state/taskStore";
import { useTermStore } from "../state/termStore";

export function App() {
  const { route, navigate } = useAppRouter();
  const taskStore = useTaskStore();
  const recentReviewTask = taskStore.recentReviewTask ?? taskStore.tasks[0];
  const selectedTask = taskStore.tasks.find((task) => task.id === route.params.taskId) ?? recentReviewTask;
  const taskRunStore = useTaskRunStore(selectedTask?.id);
  const resultWorkspace = useResultWorkspaceStore(selectedTask?.id);
  const termStore = useTermStore();
  const providerStore = useProviderStore();
  const environmentStore = useEnvironmentStore();

  const renderPage = () => {
    switch (route.id) {
      case "new-task":
        return (
          <NewTaskPage
            draft={taskStore.draft}
            serviceConnections={providerStore.connections}
            environmentChecks={environmentStore.checks}
          />
        );
      case "tasks":
        return (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "task-detail":
        return selectedTask ? (
          <TaskDetailPage
            task={selectedTask}
            taskRun={taskRunStore.currentRun}
            onOpenReview={() => navigate(getTaskReviewPath(selectedTask.id))}
          />
        ) : (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "result-review":
        return selectedTask ? (
          <ResultReviewPage
            task={selectedTask}
            workspace={resultWorkspace}
            terms={termStore.terms}
          />
        ) : (
          <TaskHistoryPage
            tasks={taskStore.tasks}
            onOpenTask={(taskId) => navigate(getTaskDetailPath(taskId))}
            onOpenReview={(taskId) => navigate(getTaskReviewPath(taskId))}
          />
        );
      case "terms":
        return <TermsPage terms={termStore.terms} />;
      case "services":
        return <ModelCredentialsPage connections={providerStore.connections} credentialBoundary={providerStore.credentialBoundary} />;
      case "diagnostics":
        return <EnvironmentDiagnosticsPage checks={environmentStore.checks} />;
      case "settings":
        return <SettingsPage />;
    }
  };

  return (
    <AppShell
      activeRouteId={route.id}
      currentRun={taskRunStore.currentRun}
      recentReviewTaskId={recentReviewTask?.id}
      onNavigate={navigate}
    >
      {renderPage()}
    </AppShell>
  );
}
