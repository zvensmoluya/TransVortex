import { useEffect, useState } from "react";

export type AppRouteId =
  | "client-home"
  | "new-task"
  | "tasks"
  | "task-detail"
  | "result-review"
  | "terms"
  | "services"
  | "diagnostics"
  | "settings";

export type RouteMatch = {
  id: AppRouteId;
  path: string;
  params: {
    taskId?: string;
  };
};

export type NavigationTarget = {
  id: AppRouteId;
  label: string;
  path: string;
};

export const staticNavigationTargets: NavigationTarget[] = [
  { id: "client-home", label: "首页", path: "/home" },
  { id: "new-task", label: "新建任务", path: "/new-task" },
  { id: "tasks", label: "任务历史", path: "/tasks" },
  { id: "terms", label: "术语表", path: "/terms" },
  { id: "services", label: "模型与凭据", path: "/services" },
  { id: "diagnostics", label: "环境诊断", path: "/diagnostics" },
  { id: "settings", label: "设置", path: "/settings" },
];

export function getTaskDetailPath(taskId: string): string {
  return `/tasks/${encodeURIComponent(taskId)}`;
}

export function getTaskReviewPath(taskId: string): string {
  return `/tasks/${encodeURIComponent(taskId)}/review`;
}

export function matchRoute(pathname: string): RouteMatch {
  const path = pathname === "/" ? "/home" : pathname;
  const taskReviewMatch = path.match(/^\/tasks\/([^/]+)\/review$/);
  if (taskReviewMatch) {
    return {
      id: "result-review",
      path,
      params: { taskId: decodeURIComponent(taskReviewMatch[1]) },
    };
  }

  const taskDetailMatch = path.match(/^\/tasks\/([^/]+)$/);
  if (taskDetailMatch) {
    return {
      id: "task-detail",
      path,
      params: { taskId: decodeURIComponent(taskDetailMatch[1]) },
    };
  }

  const staticTarget = staticNavigationTargets.find((target) => target.path === path);
  if (staticTarget) {
    return {
      id: staticTarget.id,
      path,
      params: {},
    };
  }

  return {
    id: "client-home",
    path: "/home",
    params: {},
  };
}

export function useAppRouter() {
  const [route, setRoute] = useState<RouteMatch>(() => matchRoute(window.location.pathname));

  useEffect(() => {
    const handlePopState = () => setRoute(matchRoute(window.location.pathname));
    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  const navigate = (path: string) => {
    window.history.pushState(null, "", path);
    setRoute(matchRoute(path));
  };

  return { route, navigate };
}
