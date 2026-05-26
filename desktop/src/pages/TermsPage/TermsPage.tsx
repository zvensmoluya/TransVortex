import { FilePlus2, Filter } from "lucide-react";
import type { UserFacingError } from "../../domain/error";
import type { TermEntry } from "../../domain/term";
import { TermTable } from "../../components/terms/TermTable";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type TermsPageProps = {
  terms: TermEntry[];
  loading: boolean;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
};

export function TermsPage({ terms, loading, error, onRefresh }: TermsPageProps) {
  const confirmed = terms.filter((term) => term.status === "confirmed" || term.status === "locked").length;
  const proposed = terms.filter((term) => term.status === "proposed").length;

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="项目资产"
        title="项目术语资料"
        description={`${confirmed} 条已确认或锁定 · ${proposed} 条系统建议 · 与字幕行保持关联`}
        actions={
          <>
            <button className="tvx-btn" type="button">
              <Filter size={15} />
              筛选
            </button>
            <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
              <Filter size={15} />
              刷新
            </button>
            <button className="tvx-btn tvx-btn-primary" type="button">
              <FilePlus2 size={15} />
              新建术语
            </button>
          </>
        }
      />

      <SectionPanel title="术语资料夹" subtitle="系统建议 · 已确认 · 锁定术语">
        {loading ? <div className="empty-state">正在读取真实术语资料。</div> : <TermTable terms={terms} />}
        {error ? <div className="empty-state">{error.impact}</div> : null}
      </SectionPanel>
    </div>
  );
}
