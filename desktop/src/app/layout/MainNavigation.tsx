import {
  ClipboardList,
  FileSearch,
  FolderClock,
  KeyRound,
  ListChecks,
  Settings,
  Tags,
} from "lucide-react";
import type { AppRouteId } from "../router";
import { getTaskReviewPath, staticNavigationTargets } from "../router";

type MainNavigationProps = {
  activeRouteId: AppRouteId;
  recentReviewTaskId?: string;
  onNavigate: (path: string) => void;
};

const iconByRoute: Partial<Record<AppRouteId, typeof ClipboardList>> = {
  "new-task": ClipboardList,
  tasks: FolderClock,
  terms: Tags,
  services: KeyRound,
  diagnostics: ListChecks,
  settings: Settings,
};

export function MainNavigation({ activeRouteId, recentReviewTaskId, onNavigate }: MainNavigationProps) {
  const reviewPath = recentReviewTaskId ? getTaskReviewPath(recentReviewTaskId) : "/tasks";
  const targets = [
    ...staticNavigationTargets.slice(0, 2),
    { id: "result-review" as const, label: "结果检查", path: reviewPath },
    ...staticNavigationTargets.slice(2),
  ];

  return (
    <nav className="main-nav" aria-label="主要导航">
      {targets.map((target) => {
        const Icon = target.id === "result-review" ? FileSearch : iconByRoute[target.id] ?? ClipboardList;
        const active = isNavigationActive(activeRouteId, target.id);
        return (
          <button
            key={target.id}
            className={`nav-item ${active ? "is-active" : ""}`}
            type="button"
            onClick={() => onNavigate(target.path)}
          >
            <Icon size={17} />
            <span>{target.label}</span>
          </button>
        );
      })}
    </nav>
  );
}

function isNavigationActive(activeRouteId: AppRouteId, targetId: AppRouteId): boolean {
  if (targetId === "tasks") {
    return activeRouteId === "tasks" || activeRouteId === "task-detail";
  }
  return activeRouteId === targetId;
}
