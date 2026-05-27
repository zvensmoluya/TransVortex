import type { TermEntry } from "../../domain/term";
import { StatusBadge } from "../feedback/StatusBadge";

type TermTableProps = {
  terms: TermEntry[];
  savingTermId?: string;
  onConfirm?: (term: TermEntry) => void;
  onLock?: (term: TermEntry) => void;
};

export function TermTable({ terms, savingTermId, onConfirm, onLock }: TermTableProps) {
  return (
    <div className="data-table" role="table" aria-label="项目术语">
      <div className="data-table-head" role="row">
        <span>源词</span>
        <span>译名</span>
        <span>状态</span>
        <span>范围</span>
        <span>关联字幕</span>
        <span>动作</span>
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
          <span className="table-actions">
            {term.editable && term.status === "proposed" && onConfirm ? (
              <button className="tvx-btn tvx-btn-quiet" type="button" disabled={savingTermId === term.id} onClick={() => onConfirm(term)}>确认</button>
            ) : null}
            {term.editable && term.status !== "locked" && onLock ? (
              <button className="tvx-btn tvx-btn-quiet" type="button" disabled={savingTermId === term.id} onClick={() => onLock(term)}>锁定</button>
            ) : null}
            {!term.editable ? <small>来自预设</small> : null}
          </span>
        </div>
      ))}
      {terms.length === 0 ? <div className="empty-state">当前任务还没有术语资料。</div> : null}
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
