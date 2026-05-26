import { FileSearch, FolderOpen } from "lucide-react";
import type { Task, TaskStatus } from "../../domain/task";
import { StatusBadge, type StatusTone } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type TaskHistoryPageProps = {
  tasks: Task[];
  onOpenTask: (taskId: string) => void;
  onOpenReview: (taskId: string) => void;
};

export function TaskHistoryPage({ tasks, onOpenTask, onOpenReview }: TaskHistoryPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="任务"
        title="项目任务台"
        description={`${tasks.length} 个字幕项目 · 从这里恢复制作、进入结果检查或查看输出文件`}
      />

      <SectionPanel title="最近字幕项目" subtitle="素材 · 流水线 · 结果检查 · 输出文件">
        <div className="task-list">
          {tasks.map((task) => (
            <article className="task-row" key={task.id}>
              <div className="task-rail" aria-hidden="true">
                {task.pipeline.map((step) => (
                  <span className={`is-${step.status}`} key={step.id} />
                ))}
              </div>
              <div className="task-row-main">
                <div className="task-title-line">
                  <h3>{task.title}</h3>
                  <StatusBadge tone={taskTone(task.status)} label={taskLabel(task.status)} />
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
                <button className="tvx-btn" type="button" disabled={task.outputs.length === 0} onClick={() => onOpenReview(task.id)}>
                  <FileSearch size={15} />
                  结果检查
                </button>
              </div>
            </article>
          ))}
        </div>
      </SectionPanel>
    </div>
  );
}

function taskTone(status: TaskStatus): StatusTone {
  if (status === "completed") return "success";
  if (status === "running" || status === "starting") return "info";
  if (status === "failedRecoverable" || status === "cancelled") return "warning";
  if (status === "failedFatal") return "danger";
  return "neutral";
}

function taskLabel(status: TaskStatus): string {
  if (status === "completed") return "已完成";
  if (status === "running") return "运行中";
  if (status === "starting") return "启动中";
  if (status === "failedRecoverable") return "可恢复失败";
  if (status === "failedFatal") return "失败";
  if (status === "cancelled") return "已取消";
  return "待处理";
}
