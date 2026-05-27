import { Download, Filter, RefreshCw } from "lucide-react";
import { useMemo, useState } from "react";
import type { UserFacingError } from "../../domain/error";
import type { TermEntry } from "../../domain/term";
import { TermTable } from "../../components/terms/TermTable";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type TermsPageProps = {
  terms: TermEntry[];
  loading: boolean;
  savingTermId?: string;
  exportPath?: string;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
  onConfirm: (term: TermEntry) => Promise<void>;
  onLock: (term: TermEntry) => Promise<void>;
  onExportPreset: (request: { presetId: string; name?: string; description?: string; defaultStatus: TermEntry["status"]; overwrite?: boolean }) => Promise<unknown>;
};

export function TermsPage({ terms, loading, savingTermId, exportPath, error, onRefresh, onConfirm, onLock, onExportPreset }: TermsPageProps) {
  const [filter, setFilter] = useState<"all" | "task" | "suggestion" | "confirmed" | "locked">("all");
  const [presetId, setPresetId] = useState("");
  const confirmed = terms.filter((term) => term.status === "confirmed" || term.status === "locked").length;
  const proposed = terms.filter((term) => term.status === "proposed").length;
  const filteredTerms = useMemo(
    () => terms.filter((term) => {
      if (filter === "all") return true;
      if (filter === "task") return term.scope === "task";
      if (filter === "suggestion") return term.origin === "suggestion" || term.status === "proposed";
      return term.status === filter;
    }),
    [filter, terms],
  );

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="项目资产"
        title="项目术语资料"
        description={`${confirmed} 条已确认或锁定 · ${proposed} 条系统建议 · 与字幕行保持关联`}
        actions={
          <>
            <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
              <RefreshCw size={15} />
              刷新
            </button>
          </>
        }
      />

      <SectionPanel title="术语资料夹" subtitle="系统建议 · 已确认 · 锁定术语">
        <div className="review-toolbar">
          <Filter size={15} />
          <select className="tvx-input compact-select" value={filter} onChange={(event) => setFilter(event.target.value as typeof filter)}>
            <option value="all">全部术语</option>
            <option value="task">任务术语</option>
            <option value="suggestion">系统建议</option>
            <option value="confirmed">已确认</option>
            <option value="locked">锁定术语</option>
          </select>
          <input className="tvx-input" value={presetId} onChange={(event) => setPresetId(event.target.value)} placeholder="导出预设 id" />
          <button
            className="tvx-btn tvx-btn-primary"
            type="button"
            disabled={!presetId.trim() || loading}
            onClick={() => void onExportPreset({ presetId: presetId.trim(), defaultStatus: "confirmed" })}
          >
            <Download size={15} />
            导出为预设
          </button>
        </div>
        {exportPath ? <div className="success-panel">已导出到 {exportPath}</div> : null}
        {loading ? <div className="empty-state">正在读取真实术语资料。</div> : (
          <TermTable
            terms={filteredTerms}
            savingTermId={savingTermId}
            onConfirm={(term) => void onConfirm(term)}
            onLock={(term) => void onLock(term)}
          />
        )}
        {error ? <div className="empty-state">{error.impact}</div> : null}
      </SectionPanel>
    </div>
  );
}
