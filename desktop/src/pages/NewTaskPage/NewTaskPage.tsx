import type { ReactNode } from "react";
import { useEffect, useState } from "react";
import { Captions, CheckCircle2, FileText, FileVideo, FolderOpen, Gauge, Languages, Play, RefreshCw, ShieldCheck, Tags } from "lucide-react";
import type { EnvironmentCheck } from "../../domain/environment";
import type { ExportFormat } from "../../domain/export";
import type { UserFacingError } from "../../domain/error";
import type { ServiceConnection } from "../../domain/serviceConnection";
import type { SubtitleStream, TaskDraft } from "../../domain/task";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";
import { pickInputFile, pickOutputDirectory } from "../../services/fileService";

type NewTaskPageProps = {
  draft?: TaskDraft;
  loading: boolean;
  starting: boolean;
  serviceConnections: ServiceConnection[];
  environmentChecks: EnvironmentCheck[];
  providerError?: UserFacingError;
  environmentError?: UserFacingError;
  taskError?: UserFacingError;
  onPickInput: (path: string) => void;
  onPickOutputDirectory: (path: string) => void;
  onDraftChange: (updater: (draft: TaskDraft) => TaskDraft) => void;
  onProbeSubtitleStreams: (input: string) => Promise<SubtitleStream[]>;
  onStartTask: () => Promise<void>;
  onRefresh: () => Promise<void>;
};

export function NewTaskPage({
  draft,
  loading,
  starting,
  serviceConnections,
  environmentChecks,
  providerError,
  environmentError,
  taskError,
  onPickInput,
  onPickOutputDirectory,
  onDraftChange,
  onProbeSubtitleStreams,
  onStartTask,
  onRefresh,
}: NewTaskPageProps) {
  const [subtitleStreams, setSubtitleStreams] = useState<SubtitleStream[]>([]);
  const [probingStreams, setProbingStreams] = useState(false);
  const [streamProbeMessage, setStreamProbeMessage] = useState("");
  const translationConnection = serviceConnections.find((connection) => connection.kind === "translation" && connection.isDefault);
  const asrConnection = serviceConnections.find((connection) => connection.kind === "asr" && connection.isDefault);
  const translationConnections = serviceConnections.filter((connection) => connection.kind === "translation");
  const asrConnections = serviceConnections.filter((connection) => connection.kind === "asr");
  const blockingChecks = environmentChecks.filter((check) => check.status === "fail");
  const canStart = Boolean(draft?.input.path) && blockingChecks.length === 0 && !starting;
  const supportedStreams = subtitleStreams.filter((stream) => stream.supported);

  useEffect(() => {
    setSubtitleStreams([]);
    setStreamProbeMessage("");
  }, [draft?.input.path]);

  const probeStreams = async () => {
    if (!draft?.input.path) return;
    setProbingStreams(true);
    try {
      const streams = await onProbeSubtitleStreams(draft.input.path);
      setSubtitleStreams(streams);
      const supported = streams.filter((stream) => stream.supported);
      setStreamProbeMessage(supported.length > 0 ? `检测到 ${supported.length} 条可用文本字幕轨。` : "没有可用文本字幕轨，可以切换到 ASR。");
      if (supported.length > 0) {
        onDraftChange((current) => ({ ...current, subtitleSource: { mode: "embedded", streamId: String(supported[0].index) } }));
      }
    } catch (err) {
      setSubtitleStreams([]);
      setStreamProbeMessage(err instanceof Error ? err.message : String(err));
    } finally {
      setProbingStreams(false);
    }
  };

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="制作台"
        title="准备字幕任务"
        description={draft ? `${draft.input.displayName} · ${draft.languages.sourceLanguage} → ${draft.languages.targetLanguage} · 输出 ${draft.output.formats.map((format) => format.toUpperCase()).join(" / ")}` : "正在读取真实配置与任务状态"}
        actions={
          <>
            <button className="tvx-btn" type="button" onClick={() => void onRefresh()}>
              <RefreshCw size={15} />
              刷新
            </button>
            <button className="tvx-btn tvx-btn-primary" type="button" disabled={!canStart} onClick={() => void onStartTask()}>
              <Play size={15} />
              {starting ? "正在启动" : "开始任务"}
            </button>
          </>
        }
      />

      <div className="workspace-grid">
        <SectionPanel title="素材台面" subtitle="输入素材 · 字幕来源 · 语言">
          <div className="input-dock">
            <FileVideo size={24} />
            <div>
              <strong>{draft?.input.displayName ?? "未选择素材"}</strong>
              <span>{draft?.input.path ?? "选择本地音视频或字幕文件"}</span>
            </div>
            <button
              className="tvx-btn"
              type="button"
              onClick={async () => {
                const path = await pickInputFile();
                if (path) onPickInput(path);
              }}
            >
              <FolderOpen size={15} />
              选择文件
            </button>
          </div>
          <div className="subtitle-stage-preview" aria-label="字幕任务预览">
            <div className="video-rail">
              <span />
              <span />
              <span />
              <span />
              <span />
            </div>
            <div className="subtitle-sample-lines">
              <span>今天我们先确认字幕制作的整体流程。</span>
              <strong>先选择素材，再检查服务状态，然后开始任务。</strong>
            </div>
          </div>
          <div className="form-grid">
            <label>
              <span>源语言</span>
              <input
                className="tvx-input"
                value={draft?.languages.sourceLanguage ?? ""}
                onChange={(event) => onDraftChange((current) => ({ ...current, languages: { ...current.languages, sourceLanguage: event.target.value } }))}
                placeholder="ja"
              />
            </label>
            <label>
              <span>目标语言</span>
              <input
                className="tvx-input"
                value={draft?.languages.targetLanguage ?? ""}
                onChange={(event) => onDraftChange((current) => ({ ...current, languages: { ...current.languages, targetLanguage: event.target.value } }))}
                placeholder="zh-CN"
              />
            </label>
          </div>
          <div className="form-grid">
            <label>
              <span>输出目录</span>
              <input className="tvx-input" value={draft?.output.outputDirectory ?? "自动保存到任务目录"} readOnly />
            </label>
            <label>
              <span>字幕格式</span>
              <div className="checkbox-row">
                {(["srt", "ass", "vtt"] as ExportFormat[]).map((format) => (
                  <label key={format}>
                    <input
                      type="checkbox"
                      checked={draft?.output.formats.includes(format) ?? false}
                      onChange={(event) => {
                        onDraftChange((current) => {
                          const next = event.target.checked
                            ? [...current.output.formats, format]
                            : current.output.formats.filter((item) => item !== format);
                          return { ...current, output: { ...current.output, formats: next.length > 0 ? next : ["srt"] } };
                        });
                      }}
                    />
                    {format.toUpperCase()}
                  </label>
                ))}
              </div>
            </label>
          </div>
          <div className="form-grid">
            <label>
              <span>字幕来源</span>
              <select
                className="tvx-input"
                value={draft?.subtitleSource.mode ?? "auto"}
                onChange={(event) => {
                  const mode = event.target.value as TaskDraft["subtitleSource"]["mode"];
                  onDraftChange((current) => ({ ...current, subtitleSource: mode === "embedded" ? { mode, streamId: supportedStreams[0] ? String(supportedStreams[0].index) : undefined } : { mode } as TaskDraft["subtitleSource"] }));
                }}
              >
                <option value="auto">自动选择</option>
                <option value="embedded" disabled={supportedStreams.length === 0}>使用内置字幕轨</option>
                <option value="localAsr">本地/自托管 ASR</option>
                <option value="cloudAsr">远端 ASR</option>
              </select>
            </label>
            <label>
              <span>内置字幕轨</span>
              <select
                className="tvx-input"
                disabled={supportedStreams.length === 0 || draft?.subtitleSource.mode !== "embedded"}
                value={draft?.subtitleSource.mode === "embedded" ? draft.subtitleSource.streamId ?? "" : ""}
                onChange={(event) => onDraftChange((current) => ({ ...current, subtitleSource: { mode: "embedded", streamId: event.target.value } }))}
              >
                <option value="">{supportedStreams.length ? "选择字幕轨" : "未检测到可用文本字幕轨"}</option>
                {supportedStreams.map((stream) => (
                  <option key={stream.id} value={String(stream.index)}>
                    #{stream.index} {stream.language || "und"} {stream.title || stream.codecName}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="inline-actions">
            <button className="tvx-btn" type="button" disabled={!draft?.input.path || probingStreams} onClick={() => void probeStreams()}>
              <Captions size={15} />
              {probingStreams ? "正在检测" : "检测内置字幕"}
            </button>
            {streamProbeMessage ? <span className="helper-text">{streamProbeMessage}</span> : null}
          </div>
        </SectionPanel>

        <SectionPanel title="启动前接线" subtitle="翻译服务 · ASR 服务 · 运行环境">
          {draft ? (
            <div className="form-grid">
              <label>
                <span>翻译 provider</span>
                <select
                  className="tvx-input"
                  value={draft.translation.target.providerName}
                  onChange={(event) => {
                    const next = translationConnections.find((connection) => connection.providerName === event.target.value);
                    onDraftChange((current) => ({ ...current, translation: { ...current.translation, target: { providerName: event.target.value, model: next?.model ?? next?.models[0] } } }));
                  }}
                >
                  {translationConnections.map((connection) => (
                    <option key={connection.id} value={connection.providerName}>{connection.displayName}</option>
                  ))}
                </select>
              </label>
              <label>
                <span>翻译模型</span>
                <select
                  className="tvx-input"
                  value={draft.translation.target.model ?? ""}
                  onChange={(event) => onDraftChange((current) => ({ ...current, translation: { ...current.translation, target: { ...current.translation.target, model: event.target.value } } }))}
                >
                  {(translationConnections.find((connection) => connection.providerName === draft.translation.target.providerName)?.models ?? []).map((model) => (
                    <option key={model} value={model}>{model}</option>
                  ))}
                </select>
              </label>
            </div>
          ) : null}
          {draft ? (
            <div className="form-grid">
              <label>
                <span>ASR 模式</span>
                <select
                  className="tvx-input"
                  value={draft.speechRecognition.mode}
                  onChange={(event) => {
                    const mode = event.target.value as TaskDraft["speechRecognition"]["mode"];
                    const target = mode === "cloud"
                      ? asrConnections.find((connection) => asrConnectionKind(connection) === "remote")
                      : asrConnections.find((connection) => asrConnectionKind(connection) !== "remote");
                    onDraftChange((current) => ({ ...current, speechRecognition: { ...current.speechRecognition, mode, target: target ? { providerName: target.providerName, model: target.model ?? target.models[0] } : current.speechRecognition.target } }));
                  }}
                >
                  <option value="auto">自动</option>
                  <option value="local">本地进程/本地服务</option>
                  <option value="cloud">远端服务</option>
                  <option value="none">不识别</option>
                </select>
              </label>
              <label>
                <span>ASR 服务/模型</span>
                <select
                  className="tvx-input"
                  value={draft.speechRecognition.target?.providerName ?? ""}
                  onChange={(event) => {
                    const target = asrConnections.find((connection) => connection.providerName === event.target.value);
                    onDraftChange((current) => ({ ...current, speechRecognition: { ...current.speechRecognition, target: target ? { providerName: target.providerName, model: target.model ?? target.models[0] } : undefined } }));
                  }}
                >
                  {asrConnections.map((connection) => (
                    <option key={connection.id} value={connection.providerName}>{connection.displayName} · {connection.model ?? connection.models[0] ?? "默认"}</option>
                  ))}
                </select>
              </label>
            </div>
          ) : null}
          <div className="connection-rack">
            <ReadinessRow
              icon={<Languages size={18} />}
              label="翻译服务"
              detail={translationConnection ? `${translationConnection.displayName} · ${translationConnection.model ?? "未选择模型"}` : "未配置"}
              ok={translationConnection?.connectionStatus.state === "connected"}
            />
            <ReadinessRow
              icon={<ShieldCheck size={18} />}
              label="ASR 服务"
              detail={asrConnection ? `${asrConnection.displayName} · ${asrConnection.model ?? "未选择模型"}` : "未配置"}
              ok={asrConnection?.connectionStatus.state === "connected" || asrConnection?.connectionStatus.state === "untested"}
            />
            <ReadinessRow
              icon={<CheckCircle2 size={18} />}
              label="环境状态"
              detail={blockingChecks.length === 0 ? "没有阻塞项" : `${blockingChecks.length} 个阻塞项`}
              ok={blockingChecks.length === 0}
            />
          </div>
          <ErrorList error={taskError || providerError || environmentError} />
        </SectionPanel>
      </div>

      <div className="workspace-grid is-wide-left">
        <SectionPanel title="制作流水线" subtitle="输入素材 → 源字幕 → 翻译 → 术语 → 质量 → 导出">
          <div className="production-lane">
            <FlowStep icon={<FileVideo size={16} />} label="输入素材" detail={draft?.input.displayName ?? "等待选择"} active />
            <FlowStep icon={<Captions size={16} />} label="获取源字幕" detail={draft?.subtitleSource.mode === "embedded" ? "使用内置字幕" : "自动选择或识别"} />
            <FlowStep icon={<Languages size={16} />} label="翻译字幕" detail={translationConnection?.model ?? "待选择模型"} />
            <FlowStep icon={<Tags size={16} />} label="术语一致性" detail={draft?.terms.selectedTermBaseId ?? "未选择"} />
            <FlowStep icon={<Gauge size={16} />} label="质量检查" detail={draft?.advanced.qualityMode === "balanced" ? "均衡处理" : "保守处理"} />
            <FlowStep icon={<FileText size={16} />} label="导出交付" detail={draft ? draft.output.formats.map((format) => format.toUpperCase()).join(" / ") : "SRT"} />
          </div>
        </SectionPanel>

        <SectionPanel title="交付托盘" subtitle="输出文件 · 字幕类型 · 项目术语 · 质量模式">
          <div className="delivery-tray">
            <SummaryItem label="输出格式" value={draft ? draft.output.formats.map((format) => format.toUpperCase()).join(" / ") : "SRT"} icon={<FileText size={16} />} />
            <SummaryItem label="字幕类型" value={draft?.output.bilingual ? "双语字幕" : "单语字幕"} icon={<Captions size={16} />} />
            <SummaryItem label="术语表" value={draft?.terms.selectedTermBaseId ?? "未选择"} icon={<Tags size={16} />} />
            <SummaryItem label="质量模式" value={draft?.advanced.qualityMode === "balanced" ? "均衡处理" : "保守处理"} icon={<Gauge size={16} />} />
          </div>
          {draft ? (
            <div className="form-grid">
              <label>
                <span>双语设置</span>
                <select
                  className="tvx-input"
                  value={draft.output.bilingual ? draft.output.bilingualOrder : "off"}
                  onChange={(event) => {
                    const value = event.target.value;
                    onDraftChange((current) => ({
                      ...current,
                      output: {
                        ...current.output,
                        bilingual: value !== "off",
                        bilingualOrder: value === "source_first" ? "source_first" : "target_first",
                      },
                    }));
                  }}
                >
                  <option value="off">单语字幕</option>
                  <option value="target_first">双语 · 译文在上</option>
                  <option value="source_first">双语 · 原文在上</option>
                </select>
              </label>
              <label>
                <span>术语表</span>
                <input
                  className="tvx-input"
                  value={draft.terms.selectedTermBaseId ?? ""}
                  onChange={(event) => onDraftChange((current) => ({ ...current, terms: { ...current.terms, selectedTermBaseId: event.target.value || undefined } }))}
                  placeholder="preset id，例如 nold 或 rezero:locked"
                />
              </label>
            </div>
          ) : null}
          {draft ? (
            <div className="checkbox-row">
              <label>
                <input
                  type="checkbox"
                  checked={draft.terms.useProjectTerms}
                  onChange={(event) => onDraftChange((current) => ({ ...current, terms: { ...current.terms, useProjectTerms: event.target.checked } }))}
                />
                使用项目术语
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={draft.terms.allowSystemSuggestions}
                  onChange={(event) => onDraftChange((current) => ({ ...current, terms: { ...current.terms, allowSystemSuggestions: event.target.checked } }))}
                />
                允许系统建议
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={draft.output.preferSingleLine}
                  onChange={(event) => onDraftChange((current) => ({ ...current, output: { ...current.output, preferSingleLine: event.target.checked } }))}
                />
                尽量单行
              </label>
            </div>
          ) : null}
          <div className="inline-actions">
            <button
              className="tvx-btn"
              type="button"
              onClick={async () => {
                const dir = await pickOutputDirectory();
                if (dir) {
                  onPickOutputDirectory(dir);
                }
              }}
              disabled={!draft}
            >
              <FolderOpen size={15} />
              选择输出目录
            </button>
          </div>
        </SectionPanel>
      </div>
    </div>
  );
}

function ErrorList({ error }: { error?: UserFacingError }) {
  if (!error) {
    return null;
  }

  return (
    <div className="error-panel">
      <div>
        <strong>{error.title}</strong>
        <p>{error.impact}</p>
      </div>
    </div>
  );
}

function asrConnectionKind(connection?: ServiceConnection): string {
  const raw = connection?.rawConfig;
  if (typeof raw === "object" && raw !== null && "kind" in raw && typeof raw.kind === "string") {
    return raw.kind;
  }
  return "remote";
}

function ReadinessRow({ icon, label, detail, ok }: { icon: ReactNode; label: string; detail: string; ok: boolean }) {
  return (
    <div className="readiness-row">
      {icon}
      <div>
        <strong>{label}</strong>
        <span>{detail}</span>
      </div>
      <StatusBadge tone={ok ? "success" : "warning"} label={ok ? "可用" : "需处理"} />
    </div>
  );
}

function FlowStep({ icon, label, detail, active = false }: { icon: ReactNode; label: string; detail: string; active?: boolean }) {
  return (
    <div className={`flow-step ${active ? "is-active" : ""}`}>
      <span className="flow-step-icon">{icon}</span>
      <strong>{label}</strong>
      <span>{detail}</span>
    </div>
  );
}

function SummaryItem({ label, value, icon }: { label: string; value: string; icon: ReactNode }) {
  return (
    <div className="summary-item">
      <span className="summary-item-icon">{icon}</span>
      <div>
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
    </div>
  );
}
