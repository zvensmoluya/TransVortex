import { FilePlus2, Filter } from "lucide-react";
import type { TermEntry } from "../../domain/term";
import { TermTable } from "../../components/terms/TermTable";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type TermsPageProps = {
  terms: TermEntry[];
};

export function TermsPage({ terms }: TermsPageProps) {
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
            <button className="tvx-btn tvx-btn-primary" type="button">
              <FilePlus2 size={15} />
              新建术语
            </button>
          </>
        }
      />

      <SectionPanel title="术语资料夹" subtitle="系统建议 · 已确认 · 锁定术语">
        <TermTable terms={terms} />
      </SectionPanel>
    </div>
  );
}
