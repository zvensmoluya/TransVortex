import { FileSearch, FolderOpen, RefreshCw } from "lucide-react";
import { taskToPresentation } from "../../adapters/taskPresentationAdapter";
import type { UserFacingError } from "../../domain/error";
import type { Task } from "../../domain/task";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type TaskHistoryPageProps = {
  tasks: Task[];
  loading: boolean;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
  onOpenTask: (taskId: string) => void;
  onOpenReview: (taskId: string) => void;
};

export function TaskHistoryPage({ tasks, loading, error, onRefresh, onOpenTask, onOpenReview }: TaskHistoryPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="任务"
        title="项目任务台"
        description={`${tasks.length} 个字幕项目 · 从这里恢复制作、进入结果检查或查看输出文件`}
        actions={
          <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
            <RefreshCw size={15} />
            刷新
          </button>
        }
      />

      <SectionPanel title="最近字幕项目" subtitle="素材 · 流水线 · 结果检查 · 输出文件">
        {loading ? <div className="empty-state">正在读取真实任务列表。</div> : null}
        {error ? <div className="empty-state">{error.impact}</div> : null}
        <div className="task-list">
          {tasks.map((task) => {
            const presentation = taskToPresentation({ task });
            return (
              <article className="task-row" key={task.id}>
                <div className="task-rail" aria-hidden="true">
                  {task.pipeline.map((step) => (
                    <span className={`is-${step.status}`} key={step.id} />
                  ))}
                </div>
                <div className="task-row-main">
                  <div className="task-title-line">
                    <h3>{presentation.title}</h3>
                    <StatusBadge tone={presentation.statusTone} label={presentation.statusLabel} />
                  </div>
                  <div className="task-meta">
                    <span>{task.input.displayName}</span>
                    <span>{task.languages.sourceLanguage} → {task.languages.targetLanguage}</span>
                    <span>{task.updatedAt}</span>
                  </div>
                </div>
                <div className="task-actions">
                  <button className="tvx-btn" type="button" onClick={() => onOpenTask(task.id)}>
                    <FolderOpen size={15} />
                    查看任务
                  </button>
                  <button className="tvx-btn" type="button" disabled={!presentation.actions.reviewResult.enabled} onClick={() => onOpenReview(task.id)}>
                    <FileSearch size={15} />
                    {presentation.actions.reviewResult.label}
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      </SectionPanel>
    </div>
  );
}
