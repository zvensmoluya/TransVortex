import { RefreshCw } from "lucide-react";
import type { EnvironmentCheck } from "../../domain/environment";
import { EnvironmentCheckList } from "../../components/diagnostics/EnvironmentCheckList";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type EnvironmentDiagnosticsPageProps = {
  checks: EnvironmentCheck[];
};

export function EnvironmentDiagnosticsPage({ checks }: EnvironmentDiagnosticsPageProps) {
  const blocking = checks.filter((check) => check.status === "fail").length;
  const warnings = checks.filter((check) => check.status === "warn").length;

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="运行环境"
        title="制作环境检查"
        description={`${blocking} 个阻塞项 · ${warnings} 个质量风险或可选项 · 影响素材读取、识别和导出`}
        actions={
          <button className="tvx-btn tvx-btn-primary" type="button">
            <RefreshCw size={15} />
            重新检测
          </button>
        }
      />

      <SectionPanel title="检查灯面板" subtitle="阻塞项 · 质量风险 · 可选能力">
        <EnvironmentCheckList checks={checks} />
      </SectionPanel>
    </div>
  );
}
