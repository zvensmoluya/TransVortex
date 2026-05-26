import { RefreshCw } from "lucide-react";
import type { UserFacingError } from "../../domain/error";
import type { EnvironmentCheck } from "../../domain/environment";
import { EnvironmentCheckList } from "../../components/diagnostics/EnvironmentCheckList";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type EnvironmentDiagnosticsPageProps = {
  checks: EnvironmentCheck[];
  loading: boolean;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
};

export function EnvironmentDiagnosticsPage({ checks, loading, error, onRefresh }: EnvironmentDiagnosticsPageProps) {
  const blocking = checks.filter((check) => check.status === "fail").length;
  const warnings = checks.filter((check) => check.status === "warn").length;

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="修复面板"
        title="制作环境"
        description={`${blocking} 个阻塞项 · ${warnings} 个质量风险或可选项 · 影响素材读取、识别和导出`}
        actions={
          <button className="tvx-btn tvx-btn-primary" type="button" onClick={() => void onRefresh()}>
            <RefreshCw size={15} />
            重新检测
          </button>
        }
      />

      <SectionPanel title="检查灯" subtitle="阻塞项 · 质量风险 · 可选能力">
        {loading ? <div className="empty-state">正在读取真实环境检查。</div> : <EnvironmentCheckList checks={checks} />}
        {error ? <div className="empty-state">{error.impact}</div> : null}
      </SectionPanel>
    </div>
  );
}
