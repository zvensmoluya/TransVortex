import type { ReactNode } from "react";
import { Captions, Download, FileText, Gauge, Save, Search, SkipBack, SkipForward, Tags } from "lucide-react";
import { useState } from "react";
import type { Segment } from "../../domain/segment";
import type { Task } from "../../domain/task";
import type { TermEntry } from "../../domain/term";
import type { ResultWorkspaceState } from "../../state/resultWorkspaceStore";
import { SegmentList, formatMs } from "../../components/subtitle/SegmentList";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type ResultReviewPageProps = {
  task: Task;
  workspace: ResultWorkspaceState;
  terms: TermEntry[];
};

export function ResultReviewPage({ task, workspace, terms }: ResultReviewPageProps) {
  const [selectedSegmentId, setSelectedSegmentId] = useState(workspace.selectedSegmentId);
  const selectedSegment = workspace.segments.find((segment) => segment.id === selectedSegmentId) ?? workspace.segments[0];
  const issueCount = workspace.segments.reduce((total, segment) => total + segment.issues.length, 0);
  const dirtyCount = workspace.segments.filter((segment) => segment.dirtyState !== "clean").length;

  return (
    <div className="page-stack review-page">
      <PageHeader
        eyebrow="审片台"
        title={task.title}
        description={`${workspace.segments.length} 行字幕 · ${issueCount} 个质量问题 · ${dirtyCount} 行尚未交付到输出文件`}
        actions={
          <>
            <button className="tvx-btn" type="button">
              <Save size={15} />
              保存修改
            </button>
            <button className="tvx-btn tvx-btn-primary" type="button">
              <Download size={15} />
              重新导出
            </button>
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
        <StatusBadge tone={workspace.saveState === "savedPendingExport" ? "warning" : "success"} label={workspace.saveState === "savedPendingExport" ? "已保存，待重新导出" : "保存状态正常"} />
      </div>

      <div className="review-signal-strip">
        <SignalItem icon={<Captions size={16} />} label="字幕行" value={`${workspace.segments.length} 行`} />
        <SignalItem icon={<Gauge size={16} />} label="质量问题" value={`${issueCount} 个`} tone={issueCount > 0 ? "warning" : "success"} />
        <SignalItem icon={<Tags size={16} />} label="术语命中" value={`${selectedSegment?.termMatches.length ?? 0} 条`} />
        <SignalItem icon={<FileText size={16} />} label="输出状态" value={dirtyCount > 0 ? "待重新导出" : "已交付"} tone={dirtyCount > 0 ? "warning" : "success"} />
      </div>

      <div className="review-layout">
        <SectionPanel title="字幕行工作区" subtitle="字幕行 · 时间轴 · 问题定位">
          <SegmentList segments={workspace.segments} selectedSegmentId={selectedSegment?.id} onSelect={setSelectedSegmentId} />
          <TimelineOverview segments={workspace.segments} selectedSegmentId={selectedSegment?.id} />
        </SectionPanel>

        <aside className="review-side">
          <SectionPanel title="当前行">
            {selectedSegment ? <SegmentEditor segment={selectedSegment} /> : <div className="empty-state">请选择字幕行。</div>}
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

function SegmentEditor({ segment }: { segment: Segment }) {
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
        <textarea className="tvx-textarea" value={segment.sourceText} readOnly />
      </label>
      <label>
        <span>译文</span>
        <textarea className="tvx-textarea" value={segment.translatedText} readOnly />
      </label>
    </div>
  );
}

function SignalItem({ icon, label, value, tone = "neutral" }: { icon: ReactNode; label: string; value: string; tone?: "success" | "warning" | "neutral" }) {
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
