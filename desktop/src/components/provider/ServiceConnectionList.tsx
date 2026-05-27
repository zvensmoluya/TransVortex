import { DownloadCloud, KeyRound, Network, PlugZap, Save, ShieldCheck } from "lucide-react";
import { useMemo, useState } from "react";
import type { ServiceConnection, ServiceKind } from "../../domain/serviceConnection";
import { StatusBadge, type StatusTone } from "../feedback/StatusBadge";
import type { ProviderModelsPayload, ProviderTestPayload } from "../../types";

type ServiceConnectionListProps = {
  connections: ServiceConnection[];
  kind: ServiceKind;
  workingConnectionId?: string;
  reports?: Record<string, ProviderTestPayload | ProviderModelsPayload>;
  onSaveApiKey?: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onTestConnection?: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>;
  onFetchModels?: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>;
  onSaveRouting?: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>;
};

export function ServiceConnectionList({
  connections,
  kind,
  workingConnectionId,
  reports = {},
  onSaveApiKey,
  onTestConnection,
  onFetchModels,
  onSaveRouting,
}: ServiceConnectionListProps) {
  const filtered = connections.filter((connection) => connection.kind === kind);
  const title = kind === "translation" ? "翻译服务" : "ASR 服务";
  const translationConnections = connections.filter((connection) => connection.kind === "translation");

  return (
    <div className="connection-group">
      <div className="connection-group-title">
        <Network size={16} />
        <h3>{title}</h3>
      </div>
      <div className="object-list">
        {filtered.map((connection) => (
          <ConnectionRow
            key={connection.id}
            connection={connection}
            allTranslationConnections={translationConnections}
            working={workingConnectionId === connection.id}
            report={reports[connection.id]}
            onSaveApiKey={onSaveApiKey}
            onTestConnection={onTestConnection}
            onFetchModels={onFetchModels}
            onSaveRouting={onSaveRouting}
          />
        ))}
        {filtered.length === 0 ? <div className="empty-state">当前没有已配置的{title}。</div> : null}
      </div>
    </div>
  );
}

function ConnectionRow({
  connection,
  allTranslationConnections,
  working,
  report,
  onSaveApiKey,
  onTestConnection,
  onFetchModels,
  onSaveRouting,
}: {
  connection: ServiceConnection;
  allTranslationConnections: ServiceConnection[];
  working: boolean;
  report?: ProviderTestPayload | ProviderModelsPayload;
  onSaveApiKey?: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onTestConnection?: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>;
  onFetchModels?: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>;
  onSaveRouting?: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>;
}) {
  const [apiKey, setApiKey] = useState("");
  const [selectedModel, setSelectedModel] = useState(connection.model ?? connection.models[0] ?? "");
  const [fallbackModel, setFallbackModel] = useState(connection.fallbackTargets[0]?.model ?? "");
  const fallbackProvider = useMemo(
    () => allTranslationConnections.find((candidate) => candidate.providerName !== connection.providerName) ?? allTranslationConnections[0],
    [allTranslationConnections, connection.providerName],
  );
  const models = connection.models.length > 0 ? connection.models : connection.model ? [connection.model] : [];
  const canSaveRouting = connection.kind === "translation" && selectedModel.length > 0 && onSaveRouting;
  const canUseNetworkActions = connection.kind === "translation" && selectedModel.length > 0;

  return (
    <div className={`object-row connection-row is-${connection.connectionStatus.state}`}>
      <PlugZap size={18} />
      <div className="object-row-main">
        <strong>
          {connection.displayName}
          {connection.isDefault ? <span className="inline-tag">默认</span> : null}
        </strong>
        <span>{connection.model ? `模型 ${connection.model}` : connection.kind === "asr" && connection.providerName === "faster-whisper" ? "本地识别模型 small" : "未选择模型"}</span>
        <div className="connection-controls">
          {models.length > 0 ? (
            <select className="tvx-input" value={selectedModel} onChange={(event) => setSelectedModel(event.target.value)}>
              {models.map((model) => <option key={model} value={model}>{model}</option>)}
            </select>
          ) : connection.kind === "translation" ? (
            <input className="tvx-input" value={selectedModel} onChange={(event) => setSelectedModel(event.target.value)} placeholder="填写模型名" />
          ) : null}
          {connection.credentialStatus.state !== "notRequired" && onSaveApiKey ? (
            <input
              className="tvx-input"
              type="password"
              value={apiKey}
              onChange={(event) => setApiKey(event.target.value)}
              placeholder={`保存到 ${connection.credentialId ?? connection.providerName}`}
            />
          ) : null}
          {connection.kind === "translation" && fallbackProvider && fallbackProvider.providerName !== connection.providerName ? (
            <select className="tvx-input" value={fallbackModel} onChange={(event) => setFallbackModel(event.target.value)}>
              <option value="">无备用模型</option>
              {(fallbackProvider.models.length ? fallbackProvider.models : fallbackProvider.model ? [fallbackProvider.model] : []).map((model) => (
                <option key={model} value={model}>{fallbackProvider.displayName} · {model}</option>
              ))}
            </select>
          ) : null}
          {report ? <small>{reportHint(report)}</small> : null}
        </div>
      </div>
      <StatusBadge tone={credentialTone(connection.credentialStatus.state)} label={connection.credentialStatus.label} />
      <StatusBadge tone={connectionTone(connection.connectionStatus.state)} label={connection.connectionStatus.label} />
      {connection.credentialStatus.state !== "notRequired" && onSaveApiKey ? (
        <button className="icon-button" type="button" title="保存 API key" aria-label="保存 API key" disabled={!apiKey || working} onClick={() => void onSaveApiKey(connection, apiKey).then(() => setApiKey(""))}>
          <Save size={15} />
        </button>
      ) : null}
      {connection.kind === "translation" && onFetchModels ? (
        <button className="icon-button" type="button" title="拉取模型" aria-label="拉取模型" disabled={working} onClick={() => void onFetchModels(connection, apiKey || undefined)}>
          <DownloadCloud size={15} />
        </button>
      ) : null}
      {onTestConnection ? (
        <button className="icon-button" type="button" title="测试连接" aria-label="测试连接" disabled={working || !canUseNetworkActions} onClick={() => void onTestConnection(connection, selectedModel, apiKey || undefined)}>
          <KeyRound size={15} />
        </button>
      ) : null}
      {canSaveRouting ? (
        <button
          className="icon-button"
          type="button"
          title="保存默认和备用模型"
          aria-label="保存默认和备用模型"
          disabled={working}
          onClick={() => void onSaveRouting(
            { providerName: connection.providerName, model: selectedModel },
            fallbackProvider && fallbackModel ? [{ providerName: fallbackProvider.providerName, model: fallbackModel }] : [],
          )}
        >
          <ShieldCheck size={15} />
        </button>
      ) : null}
    </div>
  );
}

function reportHint(report: ProviderTestPayload | ProviderModelsPayload): string {
  if ("models" in report) {
    return report.models.length ? `已获取 ${report.models.length} 个模型` : report.hint_zh ?? report.message;
  }
  const first = report.checks.find((check) => check.status !== "PASS") ?? report.checks[0];
  return first?.hint_zh ?? first?.message ?? report.status;
}

function credentialTone(state: ServiceConnection["credentialStatus"]["state"]): StatusTone {
  if (state === "saved" || state === "notRequired") return "success";
  if (state === "invalid") return "danger";
  return "warning";
}

function connectionTone(state: ServiceConnection["connectionStatus"]["state"]): StatusTone {
  if (state === "connected") return "success";
  if (state === "failed") return "danger";
  if (state === "checking") return "info";
  return "neutral";
}
