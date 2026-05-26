import { AlertTriangle, FileSearch, PauseCircle, RotateCcw } from "lucide-react";
import type { UserFacingError } from "../../domain/error";
import type { Task } from "../../domain/task";
import type { TaskRun } from "../../domain/taskRun";
import { ExportFilesPanel } from "../../components/export/ExportFilesPanel";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";
import { PipelineBar } from "../../components/task/PipelineBar";
import { ProgressBar } from "../../components/task/ProgressBar";

type TaskDetailPageProps = {
  task: Task;
  taskRun?: TaskRun;
  loading: boolean;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
  onOpenReview: () => void;
};

export function TaskDetailPage({ task, taskRun, loading, error, onRefresh, onOpenReview }: TaskDetailPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="任务详情"
        title={task.title}
        description={`${task.input.displayName} · ${task.languages.sourceLanguage} → ${task.languages.targetLanguage} · ${task.recoverability.resumeLabel ?? "当前任务可查看工件和输出"}`}
        actions={
          <>
            <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
              <RotateCcw size={15} />
              刷新
            </button>
            <button className="tvx-btn" type="button" disabled={!task.recoverability.canResume}>
              <RotateCcw size={15} />
              恢复任务
            </button>
            <button className="tvx-btn" type="button" disabled={!taskRun?.canCancel}>
              <PauseCircle size={15} />
              取消
            </button>
            <button className="tvx-btn tvx-btn-primary" type="button" disabled={task.outputs.length === 0} onClick={onOpenReview}>
              <FileSearch size={15} />
              结果检查
            </button>
          </>
        }
      />

      <SectionPanel title="字幕制作流水线" subtitle="输入素材 → 源字幕 → 翻译 → 术语 → 质量检查 → 导出">
        <PipelineBar steps={task.pipeline} />
      </SectionPanel>

      <div className="workspace-grid is-wide-left">
        <SectionPanel title="当前制作状态">
          {loading ? (
            <div className="empty-state">正在读取真实任务状态。</div>
          ) : taskRun ? (
            <div className="status-panel">
              <div className="status-panel-title">
                <StatusBadge tone="info" label="运行中" />
                <strong>{taskRun.currentAction}</strong>
              </div>
              <ProgressBar value={taskRun.progress.percent} label={taskRun.progress.label} />
              {taskRun.warnings.map((warning) => (
                <div className="warning-strip" key={warning.title}>
                  <AlertTriangle size={16} />
                  <span>{warning.title}</span>
                </div>
              ))}
              {taskRun.error ? (
                <div className="error-panel">
                  <AlertTriangle size={18} />
                  <div>
                    <strong>{taskRun.error.title}</strong>
                    <p>{taskRun.error.impact}</p>
                  </div>
                </div>
              ) : null}
            </div>
          ) : task.error || error ? (
            <div className="error-panel">
              <AlertTriangle size={18} />
              <div>
                <strong>{task.error?.title ?? error?.title}</strong>
                <p>{task.error?.impact ?? error?.impact}</p>
                <div className="inline-actions">
                  {(task.error?.nextActions ?? error?.nextActions ?? []).map((action) => (
                    <button className="tvx-btn" type="button" key={action.id}>{action.label}</button>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <div className="empty-state">当前没有运行中的事件。</div>
          )}
        </SectionPanel>

        <SectionPanel title="制作事件">
          <div className="timeline-list">
            {(taskRun?.timeline ?? []).map((event) => (
              <div className={`timeline-event is-${event.severity}`} key={event.id}>
                <span>{event.at}</span>
                <div>
                  <strong>{event.title}</strong>
                  {event.detail ? <p>{event.detail}</p> : null}
                </div>
              </div>
            ))}
            {!taskRun ? <div className="empty-state">暂无事件。</div> : null}
          </div>
        </SectionPanel>
      </div>

      <ExportFilesPanel files={task.outputs} />
    </div>
  );
}
