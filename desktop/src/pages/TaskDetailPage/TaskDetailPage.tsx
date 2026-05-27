import { AlertTriangle, FolderOpen, FileSearch, PauseCircle, PlayCircle, RotateCcw } from "lucide-react";
import type { TaskPresentation } from "../../adapters/taskPresentationAdapter";
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
  presentation: TaskPresentation;
  loading: boolean;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
  onCancel: () => Promise<void>;
  onResume: () => Promise<void>;
  onOpenPath: (path: string) => void;
  onReexport: () => void;
  onOpenReview: () => void;
};

export function TaskDetailPage({
  task,
  taskRun,
  presentation,
  loading,
  error,
  onRefresh,
  onCancel,
  onResume,
  onOpenPath,
  onReexport,
  onOpenReview,
}: TaskDetailPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="任务详情"
        title={presentation.title}
        description={presentation.subtitle}
        actions={
          <>
            <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
              <RotateCcw size={15} />
              刷新
            </button>
            {presentation.actions.openTaskDirectory.visible ? (
              <button className="tvx-btn" type="button" onClick={() => task.taskDirectory ? onOpenPath(task.taskDirectory) : undefined}>
                <FolderOpen size={15} />
                {presentation.actions.openTaskDirectory.label}
              </button>
            ) : null}
            {presentation.actions.resume.visible ? (
              <button className="tvx-btn" type="button" disabled={!presentation.actions.resume.enabled} onClick={() => void onResume()}>
                <PlayCircle size={15} />
                {presentation.actions.resume.label}
              </button>
            ) : null}
            {presentation.actions.cancel.visible ? (
              <button className="tvx-btn" type="button" disabled={!presentation.actions.cancel.enabled} onClick={() => void onCancel()}>
                <PauseCircle size={15} />
                {presentation.actions.cancel.label}
              </button>
            ) : null}
            <button className="tvx-btn tvx-btn-primary" type="button" disabled={!presentation.actions.reviewResult.enabled} onClick={onOpenReview}>
              <FileSearch size={15} />
              {presentation.actions.reviewResult.label}
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
                <StatusBadge tone={presentation.stage.tone} label={presentation.statusLabel} />
                <strong>{presentation.stage.label}</strong>
              </div>
              <ProgressBar value={presentation.stage.progress.percent} label={presentation.stage.progress.label} />
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

      <ExportFilesPanel
        delivery={presentation.delivery}
        canReexport={presentation.actions.reexport.enabled}
        onOpenFile={onOpenPath}
        onReexport={onReexport}
      />
    </div>
  );
}
