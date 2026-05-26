import type { Segment } from "../../domain/segment";
import { StatusBadge } from "../feedback/StatusBadge";

type SegmentListProps = {
  segments: Segment[];
  selectedSegmentId?: string;
  onSelect: (segmentId: string) => void;
};

export function SegmentList({ segments, selectedSegmentId, onSelect }: SegmentListProps) {
  return (
    <div className="segment-list" role="listbox" aria-label="字幕行">
      {segments.map((segment) => {
        const primaryIssue = segment.issues[0];
        return (
          <button
            key={segment.id}
            className={`segment-row ${segment.id === selectedSegmentId ? "is-selected" : ""} ${primaryIssue ? "has-issue" : ""} is-${segment.dirtyState}`}
            type="button"
            onClick={() => onSelect(segment.id)}
          >
            <span className="segment-index">{String(segment.index).padStart(3, "0")}</span>
            <span className="segment-time">
              {formatMs(segment.startMs)} - {formatMs(segment.endMs)}
            </span>
            <span className="segment-text">
              <strong>{segment.sourceText}</strong>
              <span>{segment.translatedText || "未填写译文"}</span>
            </span>
            <span className="segment-state">
              {primaryIssue ? (
                <StatusBadge tone={primaryIssue.severity === "blocking" ? "danger" : "warning"} label={primaryIssue.title} />
              ) : segment.dirtyState === "savedPendingExport" ? (
                <StatusBadge tone="warning" label="待导出" />
              ) : segment.dirtyState === "dirty" ? (
                <StatusBadge tone="info" label="已修改" />
              ) : (
                <StatusBadge tone="success" label="正常" />
              )}
            </span>
          </button>
        );
      })}
    </div>
  );
}

export function formatMs(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const millis = ms % 1000;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}.${String(millis).padStart(3, "0")}`;
}
