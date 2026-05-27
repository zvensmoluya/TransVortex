import { Activity, CircleAlert, CircleCheck } from "lucide-react";
import { taskRunToTopStatusPresentation } from "../../adapters/taskPresentationAdapter";
import type { TaskRun } from "../../domain/taskRun";
import { ProgressBar } from "../../components/task/ProgressBar";

type TopTaskStatusProps = {
  currentRun?: TaskRun;
};

export function TopTaskStatus({ currentRun }: TopTaskStatusProps) {
  const status = taskRunToTopStatusPresentation(currentRun);

  if (!currentRun) {
    return (
      <header className="top-status">
        <div className="top-status-main">
          <CircleCheck size={16} />
          <span>{status.label}</span>
        </div>
        <div className="top-status-meta">
          {status.meta.map((item) => <span key={item}>{item}</span>)}
        </div>
      </header>
    );
  }

  return (
    <header className="top-status">
      <div className="top-status-main">
        {status.failed ? <CircleAlert size={16} /> : <Activity size={16} />}
        <span>{status.label}</span>
      </div>
      <div className="top-status-meta">
        {status.meta.map((item) => <span key={item}>{item}</span>)}
      </div>
      {status.progress ? (
        <div className="top-status-progress">
          <ProgressBar value={status.progress.percent} label={status.progress.label} compact />
        </div>
      ) : null}
    </header>
  );
}
