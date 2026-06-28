import { emit } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useMemo, useState } from "react";
import asrCharmArt from "../../assets/transvortex/asr-config-charm.png";
import type { ServiceConnection } from "../../domain/serviceConnection";
import {
  ASR_SELECTION_EVENT,
  CONFIG_UPDATED_EVENT,
  type AsrSelectionPayload,
  type ConfigWindowKind,
} from "../../services/configWindowService";
import type { ProviderModelsPayload, ProviderTestPayload } from "../../types";
import "./configWindow.css";

type ConfigWindowPageProps = {
  kind: ConfigWindowKind;
  connections: ServiceConnection[];
  loading: boolean;
  workingConnectionId?: string;
  reports?: Record<string, ProviderTestPayload | ProviderModelsPayload>;
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onTestConnection: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>;
  onFetchModels: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>;
  onSaveRouting: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>;
};

export function ConfigWindowPage({
  kind,
  connections,
  loading,
  workingConnectionId,
  reports = {},
  onSaveApiKey,
  onTestConnection,
  onFetchModels,
  onSaveRouting,
}: ConfigWindowPageProps) {
  const windowCopy = kind === "translation"
    ? {
      title: "翻译魔导调校",
      subtitle: "模型、凭据、默认路线",
      mark: "翻",
      art: undefined,
    }
    : {
      title: "听写晶匣调校",
      subtitle: "本机、远端、旁路模式",
      mark: "听",
      art: asrCharmArt,
    };
  const visibleConnections = connections.filter((connection) => connection.kind === (kind === "translation" ? "translation" : "asr"));
  const readyCount = visibleConnections.filter((connection) => toneForConnection(connection) === "ready").length;

  return (
    <div className={`config-window tuner-${kind}`}>
      <header className="config-titlebar">
        <div className="config-titlebar-drag" data-tauri-drag-region>
          <span className="config-mark">{windowCopy.mark}</span>
          <div>
            <strong>{windowCopy.title}</strong>
            <small>{loading ? "读取中" : `${readyCount}/${visibleConnections.length} 接线可用`}</small>
          </div>
        </div>
        <button type="button" aria-label="关闭设置窗" onClick={() => void closeWindow()}>
          <WindowCloseIcon />
        </button>
      </header>

      <main className="tuner-stage" aria-label={windowCopy.title}>
        <TunerDecor />
        <section className="tuner-idol" aria-label="调校核心">
          {kind === "translation" ? <TunerTranslationArt /> : <img src={windowCopy.art} alt="" draggable={false} />}
          <div className="tuner-nameplate">
            <strong>{windowCopy.title}</strong>
            <small>{windowCopy.subtitle}</small>
          </div>
        </section>

        <section className="socket-rack" aria-label="服务插槽">
          {loading ? (
            <div className="socket-empty">
              <EmptyGlyph />
              <span>读取服务接线</span>
            </div>
          ) : visibleConnections.length ? (
            visibleConnections.map((connection) => (
              <ConfigConnectionItem
                key={connection.id}
                kind={kind}
                connection={connection}
                translationConnections={connections.filter((candidate) => candidate.kind === "translation")}
                working={workingConnectionId === connection.id}
                report={reports[connection.id]}
                onSaveApiKey={onSaveApiKey}
                onTestConnection={onTestConnection}
                onFetchModels={onFetchModels}
                onSaveRouting={onSaveRouting}
              />
            ))
          ) : (
            <div className="socket-empty">
              <EmptyGlyph />
              <span>{kind === "translation" ? "没有翻译服务" : "没有听写服务"}</span>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}

function ConfigConnectionItem({
  kind,
  connection,
  translationConnections,
  working,
  report,
  onSaveApiKey,
  onTestConnection,
  onFetchModels,
  onSaveRouting,
}: {
  kind: ConfigWindowKind;
  connection: ServiceConnection;
  translationConnections: ServiceConnection[];
  working: boolean;
  report?: ProviderTestPayload | ProviderModelsPayload;
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onTestConnection: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>;
  onFetchModels: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>;
  onSaveRouting: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>;
}) {
  const models = useMemo(
    () => connection.models.length > 0 ? connection.models : connection.model ? [connection.model] : [],
    [connection.model, connection.models],
  );
  const [apiKey, setApiKey] = useState("");
  const [selectedModel, setSelectedModel] = useState(connection.model ?? models[0] ?? "");
  const [fallbackModel, setFallbackModel] = useState(connection.fallbackTargets[0]?.model ?? "");
  const fallbackProvider = useMemo(
    () => translationConnections.find((candidate) => candidate.providerName !== connection.providerName) ?? translationConnections[0],
    [connection.providerName, translationConnections],
  );
  const canSaveKey = connection.credentialStatus.state !== "notRequired" && apiKey.trim().length > 0 && !working;
  const canTest = kind === "translation" ? selectedModel.length > 0 && !working : !working;
  const canSaveRouting = kind === "translation" && selectedModel.length > 0 && !working;
  const canFetchModels = kind === "translation" && !working;

  useEffect(() => {
    setSelectedModel(connection.model ?? models[0] ?? "");
  }, [connection.id, connection.model, models]);

  useEffect(() => {
    setFallbackModel(connection.fallbackTargets[0]?.model ?? "");
  }, [connection.fallbackTargets]);

  return (
    <article className={`socket-unit is-${toneForConnection(connection)}${working ? " is-working" : ""}`}>
      <div className="socket-meter" aria-hidden="true">
        <SocketGlyph kind={kind} tone={toneForConnection(connection)} />
      </div>
      <div className="socket-main">
        <div className="socket-head">
          <div>
            <strong>{connection.displayName}</strong>
            <small>{connection.isDefault ? "默认路线" : connection.providerName}</small>
          </div>
          <span>{working ? "调校中" : stateLabel(connection)}</span>
        </div>

        <div className="socket-fields">
          {kind === "translation" ? (
            models.length > 0 ? (
              <label className="socket-field is-wide">
                <span>模型</span>
                <select value={selectedModel} onChange={(event) => setSelectedModel(event.target.value)}>
                  {models.map((model) => <option key={model} value={model}>{model}</option>)}
                </select>
              </label>
            ) : (
              <label className="socket-field is-wide">
                <span>模型</span>
                <input value={selectedModel} onChange={(event) => setSelectedModel(event.target.value)} placeholder="model-name" />
              </label>
            )
          ) : (
            <div className="asr-mode-dial" aria-label="语音识别方式">
              {asrModeOptions(connection).map((option) => (
                <button
                  className={option.primary ? "is-primary-mode" : ""}
                  type="button"
                  key={option.id}
                  disabled={working}
                  onClick={() => void chooseAsrMode(option.payload)}
                >
                  <DialGlyph active={option.primary === true} />
                  <span>{option.label}</span>
                </button>
              ))}
            </div>
          )}

          {connection.credentialStatus.state !== "notRequired" ? (
            <label className="socket-field">
              <span>API key</span>
              <input
                type="password"
                value={apiKey}
                onChange={(event) => setApiKey(event.target.value)}
                placeholder={connection.credentialStatus.state === "saved" ? "已保存" : "粘贴后保存"}
              />
            </label>
          ) : null}

          {kind === "translation" && fallbackProvider && fallbackProvider.providerName !== connection.providerName ? (
            <label className="socket-field">
              <span>备用</span>
              <select value={fallbackModel} onChange={(event) => setFallbackModel(event.target.value)}>
                <option value="">无备用</option>
                {(fallbackProvider.models.length ? fallbackProvider.models : fallbackProvider.model ? [fallbackProvider.model] : []).map((model) => (
                  <option key={model} value={model}>{fallbackProvider.displayName} · {model}</option>
                ))}
              </select>
            </label>
          ) : null}
        </div>

        <div className="socket-actions">
          {connection.credentialStatus.state !== "notRequired" ? (
            <button type="button" disabled={!canSaveKey} onClick={() => void saveKeyAndNotify(connection, apiKey, setApiKey, onSaveApiKey)}>
              保存 key
            </button>
          ) : null}
          {kind === "translation" ? (
            <button type="button" disabled={!canFetchModels} onClick={() => void fetchModelsAndNotify(connection, apiKey, onFetchModels)}>
              拉模型
            </button>
          ) : null}
          <button type="button" disabled={!canTest} onClick={() => void testAndNotify(connection, selectedModel, apiKey, onTestConnection)}>
            测试
          </button>
          {kind === "translation" ? (
            <button
              className="is-primary"
              type="button"
              disabled={!canSaveRouting}
              onClick={() => void saveRoutingAndNotify(
                { providerName: connection.providerName, model: selectedModel },
                fallbackProvider && fallbackModel ? [{ providerName: fallbackProvider.providerName, model: fallbackModel }] : [],
                onSaveRouting,
              )}
            >
              设默认
            </button>
          ) : null}
        </div>
        {report ? <p className="socket-report">{reportHint(report)}</p> : null}
      </div>
    </article>
  );
}

async function saveKeyAndNotify(
  connection: ServiceConnection,
  apiKey: string,
  setApiKey: (value: string) => void,
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>,
) {
  await onSaveApiKey(connection, apiKey.trim());
  setApiKey("");
  await notifyConfigUpdated();
}

async function testAndNotify(
  connection: ServiceConnection,
  model: string,
  apiKey: string,
  onTestConnection: (connection: ServiceConnection, model?: string, apiKey?: string) => Promise<ProviderTestPayload | undefined>,
) {
  await onTestConnection(connection, model || undefined, apiKey.trim() || undefined);
  await notifyConfigUpdated();
}

async function fetchModelsAndNotify(
  connection: ServiceConnection,
  apiKey: string,
  onFetchModels: (connection: ServiceConnection, apiKey?: string) => Promise<ProviderModelsPayload | undefined>,
) {
  await onFetchModels(connection, apiKey.trim() || undefined);
  await notifyConfigUpdated();
}

async function saveRoutingAndNotify(
  primary: { providerName: string; model?: string },
  fallback: Array<{ providerName: string; model?: string }>,
  onSaveRouting: (primary: { providerName: string; model?: string }, fallback: Array<{ providerName: string; model?: string }>) => Promise<void>,
) {
  await onSaveRouting(primary, fallback);
  await notifyConfigUpdated();
}

async function notifyConfigUpdated() {
  await emit(CONFIG_UPDATED_EVENT, { at: new Date().toISOString() });
}

async function chooseAsrMode(payload: AsrSelectionPayload) {
  await emit(ASR_SELECTION_EVENT, payload);
  await notifyConfigUpdated();
}

function asrModeOptions(connection: ServiceConnection) {
  const rawKind = rawConnectionKind(connection);
  const providerPayload = {
    providerName: connection.providerName,
    model: connection.model ?? connection.models[0],
  };
  const serviceMode = rawKind === "remote" ? "cloud" : "local";
  const serviceLabel = rawKind === "remote" ? "远端" : "本机";
  return [
    { id: "auto", label: "自动", payload: { mode: "auto" as const } },
    { id: "service", label: serviceLabel, primary: true, payload: { mode: serviceMode as "local" | "cloud", ...providerPayload } },
    { id: "none", label: "旁路", payload: { mode: "none" as const } },
  ];
}

function rawConnectionKind(connection: ServiceConnection) {
  const raw = connection.rawConfig;
  return typeof raw === "object" && raw !== null && "kind" in raw && typeof raw.kind === "string" ? raw.kind : "";
}

function toneForConnection(connection: ServiceConnection) {
  if (connection.credentialStatus.state === "missing" || connection.connectionStatus.state === "failed") return "attention";
  if (connection.connectionStatus.state === "connected" || connection.credentialStatus.state === "saved" || connection.credentialStatus.state === "notRequired") return "ready";
  return "waiting";
}

function stateLabel(connection: ServiceConnection) {
  if (connection.credentialStatus.state === "missing") return "缺 key";
  if (connection.connectionStatus.state === "failed") return "待修";
  if (connection.connectionStatus.state === "connected") return "可用";
  if (connection.credentialStatus.state === "saved") return "已存";
  if (connection.credentialStatus.state === "notRequired") return "免 key";
  return "待测";
}

function reportHint(report: ProviderTestPayload | ProviderModelsPayload): string {
  if ("models" in report) {
    return report.models.length ? `已取回 ${report.models.length} 个模型` : report.hint_zh ?? report.message;
  }
  const first = report.checks.find((check) => check.status !== "PASS") ?? report.checks[0];
  return first?.hint_zh ?? first?.message ?? report.status;
}

function TunerDecor() {
  return (
    <svg className="tuner-decor" viewBox="0 0 680 478" aria-hidden="true">
      <path className="tuner-curve" d="M42 104c72-65 153-64 242 4s178 55 243-18 96-58 124-31" />
      <path className="tuner-curve low" d="M46 410c80-32 148-25 203 18s122 32 184-8 125-47 196-11" />
      <path className="tuner-spark" d="M604 102l6 11 11 5-11 5-6 11-6-11-11-5 11-5 6-11Z" />
      <path className="tuner-spark small" d="M74 146l4 8 8 4-8 4-4 8-4-8-8-4 8-4 4-8Z" />
    </svg>
  );
}

function TunerTranslationArt() {
  return (
    <svg className="tuner-translation-art" viewBox="0 0 156 138" aria-hidden="true">
      <defs>
        <linearGradient id="tunerTranslationShell" x1="25" y1="24" x2="130" y2="112" gradientUnits="userSpaceOnUse">
          <stop stopColor="#fff9ff" />
          <stop offset="0.52" stopColor="#ffeaf6" />
          <stop offset="1" stopColor="#e4faff" />
        </linearGradient>
        <filter id="tunerTranslationGlow" x="-22%" y="-24%" width="144%" height="148%">
          <feDropShadow dx="0" dy="12" stdDeviation="9" floodColor="#ff78ad" floodOpacity="0.18" />
          <feDropShadow dx="0" dy="3" stdDeviation="5" floodColor="#61c8de" floodOpacity="0.16" />
        </filter>
      </defs>
      <g filter="url(#tunerTranslationGlow)">
        <path className="tuner-wing left" d="M21 54c12-27 38-34 55-18-14 9-27 26-31 44-14 2-25-7-24-26Z" />
        <path className="tuner-wing right" d="M135 54c-12-27-38-34-55-18 14 9 27 26 31 44 14 2 25-7 24-26Z" />
        <path className="tuner-shell" d="M31 46c18-30 76-30 94 0 12 18 11 49 0 67-18 24-76 24-94 0-11-18-12-49 0-67Z" />
        <path className="tuner-screen" d="M43 61c13-16 57-16 70 0 8 10 8 28 0 38-13 16-57 16-70 0-8-10-8-28 0-38Z" />
        <path className="tuner-heart" d="M78 16c9-14 29-4 19 13L78 47 59 29c-10-17 10-27 19-13Z" />
        <path className="tuner-line" d="M58 77h40M60 91h28" />
        <circle className="tuner-port" cx="32" cy="109" r="9" />
        <circle className="tuner-port" cx="124" cy="109" r="9" />
      </g>
    </svg>
  );
}

function SocketGlyph({ kind, tone }: { kind: ConfigWindowKind; tone: string }) {
  return (
    <svg className={`socket-glyph is-${kind} is-${tone}`} viewBox="0 0 74 74" aria-hidden="true">
      <path className="socket-glyph-base" d="M15 22c8-13 36-13 44 0 5 8 5 29 0 37-8 13-36 13-44 0-5-8-5-29 0-37Z" />
      {kind === "translation" ? (
        <>
          <path className="socket-glyph-line" d="M25 35h24M25 45h17" />
          <path className="socket-glyph-star" d="M54 15l3 7 7 3-7 3-3 7-3-7-7-3 7-3 3-7Z" />
        </>
      ) : (
        <>
          <path className="socket-glyph-line" d="M37 20c6 0 10 5 10 12v7c0 7-4 12-10 12s-10-5-10-12v-7c0-7 4-12 10-12Z" />
          <path className="socket-glyph-line" d="M22 40c2 9 7 14 15 14s13-5 15-14M37 55v7" />
        </>
      )}
    </svg>
  );
}

function DialGlyph({ active }: { active: boolean }) {
  return (
    <svg className={`dial-glyph${active ? " is-active" : ""}`} viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="7" />
      <path d="M12 12l4-4" />
    </svg>
  );
}

function EmptyGlyph() {
  return (
    <svg className="empty-glyph" viewBox="0 0 76 76" aria-hidden="true">
      <path d="M18 28h40l5 28H13l5-28Z" />
      <path d="M27 28c2-9 20-9 22 0M29 44h18" />
    </svg>
  );
}

function WindowCloseIcon() {
  return (
    <svg className="config-window-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M7 7l10 10M17 7 7 17" />
    </svg>
  );
}

async function closeWindow() {
  await getCurrentWindow().close();
}
