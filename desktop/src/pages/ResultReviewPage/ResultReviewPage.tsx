import type { ReactNode } from "react";
import { Captions, Download, ExternalLink, FileText, Gauge, RotateCcw, Save, Search, SkipBack, SkipForward, Tags } from "lucide-react";
import { useState } from "react";
import type { PresentationTone, TaskPresentation } from "../../adapters/taskPresentationAdapter";
import type { Segment } from "../../domain/segment";
import type { TaskRun } from "../../domain/taskRun";
import type { TermEntry } from "../../domain/term";
import type { ResultWorkspaceState } from "../../state/resultWorkspaceStore";
import { SegmentList, formatMs } from "../../components/subtitle/SegmentList";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type ResultReviewPageProps = {
  workspace: ResultWorkspaceState;
  presentation: TaskPresentation;
  terms: TermEntry[];
  taskRun?: TaskRun;
  onRefreshTask: () => Promise<void>;
  onOpenPath: (path: string) => void;
};

export function ResultReviewPage({ workspace, presentation, terms, taskRun, onRefreshTask, onOpenPath }: ResultReviewPageProps) {
  const [selectedSegmentId, setSelectedSegmentId] = useState(workspace.selectedSegmentId);
  const selectedSegment = workspace.segments.find((segment) => segment.id === selectedSegmentId) ?? workspace.segments[0];
  const workspaceView = presentation.workspace;
  const primaryOutput = presentation.delivery.primaryOutput;

  return (
    <div className="page-stack review-page">
      <PageHeader
        eyebrow="审片台"
        title={presentation.title}
        description={workspaceView?.description ?? presentation.subtitle}
        actions={
          <>
            <button className="tvx-btn" type="button" onClick={() => void workspace.refresh()}>
              <RotateCcw size={15} />
              刷新结果
            </button>
            <button className="tvx-btn" type="button" disabled={!presentation.actions.saveResult.enabled} onClick={() => void workspace.save()}>
              <Save size={15} />
              {presentation.actions.saveResult.label}
            </button>
            <button
              className="tvx-btn tvx-btn-primary"
              type="button"
              disabled={!presentation.actions.reexport.enabled}
              onClick={() => {
                void workspace.reexport(presentation.delivery.formatsForReexport).then(() => onRefreshTask());
              }}
            >
              <Download size={15} />
              {presentation.actions.reexport.label}
            </button>
            {presentation.actions.openPrimaryOutput.visible && primaryOutput ? (
              <button className="tvx-btn" type="button" disabled={!presentation.actions.openPrimaryOutput.enabled} onClick={() => onOpenPath(primaryOutput.path)}>
                <ExternalLink size={15} />
                {presentation.actions.openPrimaryOutput.label}
              </button>
            ) : null}
          </>
        }
      />

      <div className="review-toolbar">
        <div className="search-box">
          <Search size={15} />
          <input value="" readOnly placeholder="搜索字幕或术语" />
        </div>
        <button className="tvx-btn" type="button">
          <SkipBack size={15} />
          上一条问题
        </button>
        <button className="tvx-btn" type="button">
          <SkipForward size={15} />
          下一条问题
        </button>
        <StatusBadge tone={workspaceView?.saveStateTone ?? "neutral"} label={workspaceView?.saveStateLabel ?? "未打开结果"} />
      </div>

      {taskRun?.error ? (
        <div className="error-panel">
          <div>
            <strong>{taskRun.error.title}</strong>
            <p>{taskRun.error.impact}</p>
          </div>
        </div>
      ) : null}

      {workspace.error ? (
        <div className="error-panel">
          <div>
            <strong>{workspace.error.title}</strong>
            <p>{workspace.error.impact}</p>
          </div>
        </div>
      ) : null}

      <div className="review-signal-strip">
        <SignalItem icon={<Captions size={16} />} label="字幕行" value={`${workspaceView?.segmentCount ?? 0} 行`} />
        <SignalItem icon={<Gauge size={16} />} label="质量问题" value={`${workspaceView?.issueCount ?? 0} 个`} tone={(workspaceView?.issueCount ?? 0) > 0 ? "warning" : "success"} />
        <SignalItem icon={<Tags size={16} />} label="术语命中" value={`${selectedSegment?.termMatches.length ?? 0} 条`} />
        <SignalItem icon={<FileText size={16} />} label="输出状态" value={workspaceView?.outputStateLabel ?? presentation.delivery.stateLabel} tone={workspaceView?.outputStateTone ?? presentation.delivery.stateTone} />
      </div>

      <div className="review-layout">
        <SectionPanel title="字幕行工作区" subtitle="字幕行 · 时间轴 · 问题定位">
          {workspaceView?.isLoading ? (
            <div className="empty-state">正在读取任务结果。</div>
          ) : workspace.segments.length === 0 ? (
            <div className="empty-state">当前任务还没有可检查的字幕结果。</div>
          ) : (
            <>
              <SegmentList segments={workspace.segments} selectedSegmentId={selectedSegment?.id} onSelect={setSelectedSegmentId} />
              <TimelineOverview segments={workspace.segments} selectedSegmentId={selectedSegment?.id} />
            </>
          )}
        </SectionPanel>

        <aside className="review-side">
          <SectionPanel title="当前行">
            {selectedSegment ? <SegmentEditor segment={selectedSegment} onPatch={(patch) => workspace.updateSegment(selectedSegment.id, patch)} /> : <div className="empty-state">请选择字幕行。</div>}
          </SectionPanel>

          <SectionPanel title="质量与术语">
            {selectedSegment ? (
              <div className="issue-stack">
                {selectedSegment.issues.length === 0 ? <div className="empty-state">当前行没有质量问题。</div> : null}
                {selectedSegment.issues.map((issue) => (
                  <div className="issue-row" key={issue.id}>
                    <StatusBadge tone={issue.severity === "blocking" ? "danger" : "warning"} label={issue.title} />
                    {issue.description ? <p>{issue.description}</p> : null}
                  </div>
                ))}
                {selectedSegment.termMatches.map((match) => (
                  <div className="issue-row" key={`${selectedSegment.id}-${match.termId}`}>
                    <StatusBadge tone={match.status === "matched" ? "success" : "warning"} label="术语命中" />
                    <p>{match.source} → {match.expectedTarget}</p>
                  </div>
                ))}
              </div>
            ) : null}
          </SectionPanel>

          <SectionPanel title="相关术语">
            <div className="compact-list">
              {terms.slice(0, 4).map((term) => (
                <div className="compact-row" key={term.id}>
                  <strong>{term.source}</strong>
                  <span>{term.target}</span>
                </div>
              ))}
            </div>
          </SectionPanel>
        </aside>
      </div>
    </div>
  );
}

function SegmentEditor({ segment, onPatch }: { segment: Segment; onPatch: (patch: Partial<Pick<Segment, "sourceText" | "translatedText" | "startMs" | "endMs">>) => void }) {
  return (
    <div className="segment-editor">
      <div className="segment-meter">
        <div>
          <span>开始</span>
          <strong>{formatMs(segment.startMs)}</strong>
        </div>
        <div>
          <span>结束</span>
          <strong>{formatMs(segment.endMs)}</strong>
        </div>
        <div>
          <span>阅读速度</span>
          <strong>{segment.diagnostics.charactersPerSecond} CPS</strong>
        </div>
      </div>
      <label>
        <span>原文</span>
        <textarea className="tvx-textarea" value={segment.sourceText} onChange={(event) => onPatch({ sourceText: event.target.value })} />
      </label>
      <label>
        <span>译文</span>
        <textarea className="tvx-textarea" value={segment.translatedText} onChange={(event) => onPatch({ translatedText: event.target.value })} />
      </label>
    </div>
  );
}

function SignalItem({ icon, label, value, tone = "neutral" }: { icon: ReactNode; label: string; value: string; tone?: PresentationTone }) {
  return (
    <div className={`signal-item is-${tone}`}>
      <span>{icon}</span>
      <div>
        <strong>{value}</strong>
        <small>{label}</small>
      </div>
    </div>
  );
}

function TimelineOverview({ segments, selectedSegmentId }: { segments: Segment[]; selectedSegmentId?: string }) {
  if (segments.length === 0) {
    return null;
  }

  const lastEnd = Math.max(...segments.map((segment) => segment.endMs), 1);

  return (
    <div className="timeline-overview" aria-label="时间轴概览">
      <div className="timeline-ruler">
        <span>00:00</span>
        <span>{formatMs(lastEnd)}</span>
      </div>
      {segments.map((segment) => {
        const left = (segment.startMs / lastEnd) * 100;
        const width = Math.max(((segment.endMs - segment.startMs) / lastEnd) * 100, 2);
        return (
          <span
            key={segment.id}
            className={`timeline-chip ${segment.id === selectedSegmentId ? "is-selected" : ""} ${segment.issues.length ? "has-issue" : ""}`}
            style={{ left: `${left}%`, width: `${width}%` }}
          />
        );
      })}
      <FileText size={14} />
    </div>
  );
}
