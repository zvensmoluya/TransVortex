import { Activity, CircleAlert, CircleCheck, Square } from "lucide-react";
import type { TaskRun } from "../../domain/taskRun";
import { ProgressBar } from "../../components/task/ProgressBar";

type TopTaskStatusProps = {
  currentRun?: TaskRun;
};

export function TopTaskStatus({ currentRun }: TopTaskStatusProps) {
  if (!currentRun) {
    return (
      <header className="top-status">
        <div className="top-status-main">
          <CircleCheck size={16} />
          <span>工作台已就绪</span>
        </div>
        <div className="top-status-meta">
          <span>字幕行</span>
          <span>时间轴</span>
          <span>质量检查</span>
          <span>输出文件</span>
        </div>
      </header>
    );
  }

  const isFailed = currentRun.phase === "failed";

  return (
    <header className="top-status">
      <div className="top-status-main">
        {isFailed ? <CircleAlert size={16} /> : <Activity size={16} />}
        <span>{currentRun.currentAction}</span>
      </div>
      <div className="top-status-progress">
        <ProgressBar value={currentRun.progress.percent} label={currentRun.progress.label} compact />
      </div>
      {currentRun.canCancel ? (
        <button className="icon-button" type="button" title="取消当前任务" aria-label="取消当前任务">
          <Square size={15} />
        </button>
      ) : null}
    </header>
  );
}
