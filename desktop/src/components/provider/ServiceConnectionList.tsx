import { KeyRound, Network, PlugZap, Settings2 } from "lucide-react";
import type { ServiceConnection, ServiceKind } from "../../domain/serviceConnection";
import { StatusBadge, type StatusTone } from "../feedback/StatusBadge";

type ServiceConnectionListProps = {
  connections: ServiceConnection[];
  kind: ServiceKind;
};

export function ServiceConnectionList({ connections, kind }: ServiceConnectionListProps) {
  const filtered = connections.filter((connection) => connection.kind === kind);
  const title = kind === "translation" ? "翻译服务" : "ASR 服务";

  return (
    <div className="connection-group">
      <div className="connection-group-title">
        <Network size={16} />
        <h3>{title}</h3>
      </div>
      <div className="object-list">
        {filtered.map((connection) => (
          <div className={`object-row connection-row is-${connection.connectionStatus.state}`} key={connection.id}>
            <PlugZap size={18} />
            <div className="object-row-main">
              <strong>
                {connection.displayName}
                {connection.isDefault ? <span className="inline-tag">默认</span> : null}
              </strong>
              <span>{connection.model ? `模型 ${connection.model}` : "未选择模型"}</span>
            </div>
            <StatusBadge tone={credentialTone(connection.credentialStatus.state)} label={connection.credentialStatus.label} />
            <StatusBadge tone={connectionTone(connection.connectionStatus.state)} label={connection.connectionStatus.label} />
            <button className="icon-button" type="button" title="测试连接" aria-label="测试连接">
              <KeyRound size={15} />
            </button>
            {connection.expertConfigAvailable ? (
              <button className="icon-button" type="button" title="专家配置" aria-label="专家配置">
                <Settings2 size={15} />
              </button>
            ) : null}
          </div>
        ))}
      </div>
    </div>
  );
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
