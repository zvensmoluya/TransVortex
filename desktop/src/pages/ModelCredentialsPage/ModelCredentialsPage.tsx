import { ShieldCheck } from "lucide-react";
import type { CredentialBoundary } from "../../services/credentialService";
import type { ServiceConnection } from "../../domain/serviceConnection";
import { ServiceConnectionList } from "../../components/provider/ServiceConnectionList";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type ModelCredentialsPageProps = {
  connections: ServiceConnection[];
  credentialBoundary: CredentialBoundary;
};

export function ModelCredentialsPage({ connections, credentialBoundary }: ModelCredentialsPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="服务连接"
        title="模型服务接入台"
        description="翻译服务和 ASR 服务分开接入，凭据只显示保存状态。"
      />

      <SectionPanel title="凭据保存边界" subtitle="用户级凭据文件 · 服务配置不保存密钥">
        <div className="security-strip">
          <ShieldCheck size={18} />
          <div>
            <strong>默认保存到用户级凭据文件</strong>
            <span>{credentialBoundary.storageLabel}</span>
          </div>
        </div>
      </SectionPanel>

      <div className="page-stack">
        <SectionPanel title="翻译服务接入口">
          <ServiceConnectionList connections={connections} kind="translation" />
        </SectionPanel>
        <SectionPanel title="ASR 服务接入口">
          <ServiceConnectionList connections={connections} kind="asr" />
        </SectionPanel>
      </div>
    </div>
  );
}
