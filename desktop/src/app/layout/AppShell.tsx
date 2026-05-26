import type { ReactNode } from "react";
import type { AppRouteId } from "../router";
import type { TaskRun } from "../../domain/taskRun";
import { MainNavigation } from "./MainNavigation";
import { TopTaskStatus } from "./TopTaskStatus";

type AppShellProps = {
  activeRouteId: AppRouteId;
  currentRun?: TaskRun;
  recentReviewTaskId?: string;
  onNavigate: (path: string) => void;
  children: ReactNode;
};

export function AppShell({ activeRouteId, currentRun, recentReviewTaskId, onNavigate, children }: AppShellProps) {
  return (
    <div className="app-shell">
      <aside className="app-sidebar">
        <div className="brand-lockup">
          <div className="brand-mark" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <div>
            <div className="brand-name">TransVortex</div>
            <div className="brand-subtitle">低光字幕制作工作台</div>
          </div>
        </div>
        <MainNavigation
          activeRouteId={activeRouteId}
          recentReviewTaskId={recentReviewTaskId}
          onNavigate={onNavigate}
        />
        <div className="sidebar-workbench-note" aria-label="工作台骨架">
          <div className="sidebar-note-row">
            <span>素材</span>
            <i />
            <span>字幕行</span>
          </div>
          <div className="sidebar-note-timeline">
            <span style={{ left: "8%", width: "24%" }} />
            <span style={{ left: "38%", width: "18%" }} />
            <span className="has-issue" style={{ left: "64%", width: "20%" }} />
          </div>
          <div className="sidebar-note-row">
            <span>质量检查</span>
            <i />
            <span>输出文件</span>
          </div>
        </div>
      </aside>
      <div className="app-workspace">
        <TopTaskStatus currentRun={currentRun} />
        <main className="app-main">{children}</main>
      </div>
    </div>
  );
}
