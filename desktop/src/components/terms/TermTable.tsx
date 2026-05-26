import type { TermEntry } from "../../domain/term";
import { StatusBadge } from "../feedback/StatusBadge";

type TermTableProps = {
  terms: TermEntry[];
};

export function TermTable({ terms }: TermTableProps) {
  return (
    <div className="data-table" role="table" aria-label="项目术语">
      <div className="data-table-head" role="row">
        <span>源词</span>
        <span>译名</span>
        <span>状态</span>
        <span>范围</span>
        <span>关联字幕</span>
      </div>
      {terms.map((term) => (
        <div className={`data-table-row is-${term.status}`} role="row" key={term.id}>
          <strong>{term.source}</strong>
          <span>{term.target}</span>
          <span>
            <StatusBadge tone={termStatusTone(term.status)} label={termStatusLabel(term.status)} />
          </span>
          <span>{termScopeLabel(term.scope)}</span>
          <span>{term.relatedSegmentIds.length || "-"}</span>
        </div>
      ))}
    </div>
  );
}

function termStatusTone(status: TermEntry["status"]) {
  if (status === "locked") return "success" as const;
  if (status === "confirmed") return "info" as const;
  return "warning" as const;
}

function termStatusLabel(status: TermEntry["status"]): string {
  if (status === "locked") return "锁定术语";
  if (status === "confirmed") return "已确认";
  return "系统建议";
}

function termScopeLabel(scope: TermEntry["scope"]): string {
  if (scope === "global") return "全局";
  if (scope === "project") return "项目";
  return "当前任务";
}
