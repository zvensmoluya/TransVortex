import { ShieldCheck } from "lucide-react";
import type { UserFacingError } from "../../domain/error";
import type { CredentialBoundary } from "../../services/credentialService";
import type { ServiceConnection } from "../../domain/serviceConnection";
import { ServiceConnectionList } from "../../components/provider/ServiceConnectionList";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";
import type { ProviderModelsPayload, ProviderTestPayload } from "../../types";

type ModelCredentialsPageProps = {
  connections: ServiceConnection[];
  credentialBoundary: CredentialBoundary;
  loading: boolean;
  workingConnectionId?: string;
  reports?: Record<string, ProviderTestPayload | ProviderModelsPayload>;
  error?: UserFacingError;
  onRefresh: () => Promise<void>;
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onTestConnection: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>;
  onFetchModels: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>;
  onSaveRouting: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>;
};

export function ModelCredentialsPage({
  connections,
  credentialBoundary,
  loading,
  workingConnectionId,
  reports,
  error,
  onRefresh,
  onSaveApiKey,
  onTestConnection,
  onFetchModels,
  onSaveRouting,
}: ModelCredentialsPageProps) {
  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="接入台"
        title="模型服务接入台"
        description="翻译服务和 ASR 服务分开接入，凭据只显示保存状态"
        actions={
          <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
            <ShieldCheck size={15} />
            刷新
          </button>
        }
      />

      <SectionPanel title="凭据边界" subtitle="用户级凭据文件 · 服务配置不保存密钥">
        <div className="security-strip">
          <ShieldCheck size={18} />
          <div>
            <strong>默认保存到用户级凭据文件</strong>
            <span>{credentialBoundary.storageLabel}</span>
          </div>
        </div>
      </SectionPanel>

      <div className="page-stack">
        <SectionPanel title="翻译服务插口">
          {loading ? <div className="empty-state">正在读取真实服务连接。</div> : (
            <ServiceConnectionList
              connections={connections}
              kind="translation"
              workingConnectionId={workingConnectionId}
              reports={reports}
              onSaveApiKey={onSaveApiKey}
              onTestConnection={onTestConnection}
              onFetchModels={onFetchModels}
              onSaveRouting={onSaveRouting}
            />
          )}
        </SectionPanel>
        <SectionPanel title="ASR 服务插口">
          {loading ? <div className="empty-state">正在读取真实服务连接。</div> : (
            <ServiceConnectionList
              connections={connections}
              kind="asr"
              workingConnectionId={workingConnectionId}
              reports={reports}
              onSaveApiKey={onSaveApiKey}
              onTestConnection={onTestConnection}
            />
          )}
        </SectionPanel>
        {error ? <SectionPanel title="连接状态"><div className="empty-state">{error.impact}</div></SectionPanel> : null}
      </div>
    </div>
  );
}
