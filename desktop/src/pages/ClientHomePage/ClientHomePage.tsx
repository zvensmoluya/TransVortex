import { useEffect, useMemo, useState } from "react";
import type { PresentedOutputFile, TaskPresentation } from "../../adapters/taskPresentationAdapter";
import type { EnvironmentCheck } from "../../domain/environment";
import type { UserFacingError } from "../../domain/error";
import type { ExportFormat } from "../../domain/export";
import type { ServiceConnection } from "../../domain/serviceConnection";
import type { Task, TaskDraft } from "../../domain/task";
import type { TaskRun } from "../../domain/taskRun";
import { pickInputFile, pickOutputDirectory } from "../../services/fileService";
import "./clientHome.css";

type ClientHomePageProps = {
  draft?: TaskDraft;
  loading: boolean;
  starting: boolean;
  activeTask?: Task;
  activeTaskPresentation?: TaskPresentation;
  currentRun?: TaskRun;
  serviceConnections: ServiceConnection[];
  environmentChecks: EnvironmentCheck[];
  providerError?: UserFacingError;
  environmentError?: UserFacingError;
  taskError?: UserFacingError;
  workspaceError?: UserFacingError;
  onPickInput: (path: string) => void;
  onPickOutputDirectory: (path: string) => void;
  onDraftChange: (updater: (draft: TaskDraft) => TaskDraft) => void;
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>;
  onStartTask: () => Promise<void>;
  onRefresh: () => Promise<void>;
  onOpenPath: (path: string) => void;
  onCancelTask?: (taskId: string) => Promise<void>;
};

type LauncherMode = "empty" | "ready" | "needsSetup" | "running" | "completed" | "failed";
type CheckTone = "ready" | "attention" | "muted";

type LaunchCheck = {
  id: "translation" | "recognition" | "output";
  title: string;
  status: string;
  detail: string;
  tone: CheckTone;
  actionLabel?: string;
  action?: () => void;
};

type InspectorKind = "translation" | "recognition" | "output";
type InspectorLine = {
  label: string;
  value: string;
  tone: CheckTone;
};

const translationCheckKeys = ["routing", "route", "provider_protocol", "env_key", "missing_env", "翻译服务", "服务协议", "路由"];
const recognitionCheckKeys = ["asr", "faster_whisper", "识别", "ASR", "本地识别"];

export function ClientHomePage({
  draft,
  loading,
  starting,
  activeTask,
  activeTaskPresentation,
  currentRun,
  serviceConnections,
  environmentChecks,
  providerError,
  environmentError,
  taskError,
  workspaceError,
  onPickInput,
  onPickOutputDirectory,
  onDraftChange,
  onSaveApiKey,
  onStartTask,
  onRefresh,
  onOpenPath,
  onCancelTask,
}: ClientHomePageProps) {
  const [setupPanel, setSetupPanel] = useState<InspectorKind | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    async function listenForDroppedFiles() {
      const appWindow = await getTauriWindow();
      if (!appWindow || cancelled) return;
      unlisten = await appWindow.onDragDropEvent((event) => {
        const payload = event.payload;
        if (payload.type === "enter" || payload.type === "over") {
          setDragOver(true);
        } else if (payload.type === "leave") {
          setDragOver(false);
        } else if (payload.type === "drop") {
          setDragOver(false);
          const path = payload.paths.find(isSupportedInputPath);
          if (path) {
            onPickInput(path);
            setNotice("");
          } else {
            setNotice("这个文件暂时不能做字幕。请投放视频、音频或 SRT 字幕。");
          }
        }
      });
    }

    void listenForDroppedFiles();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [onPickInput]);

  const translationConnections = serviceConnections.filter((connection) => connection.kind === "translation");
  const asrConnections = serviceConnections.filter((connection) => connection.kind === "asr");
  const selectedTranslation = selectedConnection(translationConnections, draft?.translation.target.providerName);
  const selectedAsr = selectedConnection(asrConnections, draft?.speechRecognition.target?.providerName);
  const primaryOutput = activeTaskPresentation?.delivery.primaryOutput;
  const taskStateApplies = Boolean(
    activeTask && (isRunning(currentRun) || primaryOutput || (draft?.input.path && activeTask.input.path === draft.input.path)),
  );
  const taskFlowError = draft?.input.path
    ? taskError ?? (taskStateApplies ? currentRun?.error ?? activeTask?.error : undefined)
    : undefined;
  const mode = launcherMode({ draft, starting, currentRun, primaryOutput, errors: [taskFlowError] });
  const checks = useMemo(
    () => buildChecks({
      draft,
      selectedTranslation,
      selectedAsr,
      environmentChecks,
      onOpenSetup: setSetupPanel,
    }),
    [draft, environmentChecks, selectedAsr, selectedTranslation],
  );
  const blockingCheck = draft?.input.path ? checks.find((check) => check.tone === "attention") : undefined;
  const firstError = taskFlowError ?? providerError ?? environmentError ?? workspaceError;
  const visibleError = blockingCheck ? undefined : firstError;
  const canStart = Boolean(draft?.input.path && mode !== "running" && !starting && !blockingCheck);
  const titlebarStatus = topStatus({ loading, mode, blockingCheck, currentRun });
  const source = sourceView(draft);
  const action = primaryAction({
    mode,
    draft,
    starting,
    canStart,
    primaryOutput,
    blockingCheck,
    firstError,
    onChooseSource: () => void chooseSource(onPickInput, setNotice),
    onStartTask,
    onOpenPath,
    onOpenSetup: setSetupPanel,
  });

  return (
    <div className={`client-home launcher-${mode}${dragOver ? " is-drag-over" : ""}`}>
      <header className="client-titlebar">
        <div
          className="client-titlebar-drag"
          data-tauri-drag-region
          onMouseDown={(event) => {
            if (event.button === 0) void startWindowDrag();
          }}
        >
          <AppMark />
          <div className="client-titlebar-copy">
            <strong>TransVortex</strong>
            <small>{titlebarStatus}</small>
          </div>
        </div>
        <div className="client-window-controls">
          <button type="button" aria-label="最小化" onClick={() => void minimizeWindow()}>
            <WindowMinusIcon />
          </button>
          <button className="is-close" type="button" aria-label="关闭" onClick={() => void closeWindow()}>
            <WindowCloseIcon />
          </button>
        </div>
      </header>

      <main className="launcher-shell" aria-label="字幕启动器">
        <div className="launcher-ornaments" aria-hidden="true">
          <span className="ornament-ribbon" />
          <span className="ornament-dot" />
          <span className="ornament-spark" />
        </div>

        <section className="source-bay" aria-label="片源投放">
          <div className="source-bay-rail" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <button className="source-drop-target" type="button" onClick={() => void chooseSource(onPickInput, setNotice)}>
            {source.hasFile ? <FileEnvelope kind={source.kind} /> : <DropTrayIcon />}
            <span className="source-copy">
              <strong>{source.title}</strong>
              <small>{source.detail}</small>
            </span>
          </button>
          <div className="source-hint">
            <span>拖进窗口也可以</span>
            <span>{source.hasFile ? "点击可更换片源" : "视频 / 音频 / SRT"}</span>
          </div>
        </section>

        <section className="preflight-panel" aria-label="开始前检查">
          <div className="preflight-heading">
            <StatusCharmIcon />
            <div>
              <strong>开始前检查</strong>
              <span>{setupPanel ? setupTitle(setupPanel) : "只看启动字幕需要的条件"}</span>
            </div>
          </div>

          {setupPanel ? (
            <SetupInspector
              kind={setupPanel}
              draft={draft}
              translation={selectedTranslation}
              asr={selectedAsr}
              asrConnections={asrConnections}
              checks={environmentChecks}
              onClose={() => setSetupPanel(null)}
              onRefresh={onRefresh}
              onDraftChange={onDraftChange}
              onPickOutputDirectory={onPickOutputDirectory}
              onSaveApiKey={onSaveApiKey}
            />
          ) : (
            <div className="check-list">
              {checks.map((check) => (
                <button className={`check-row is-${check.tone}`} type="button" key={check.id} onClick={check.action}>
                  <CheckGlyph id={check.id} tone={check.tone} />
                  <span>
                    <strong>{check.title}</strong>
                    <small>{check.status}</small>
                  </span>
                  <em>{check.actionLabel ?? "就绪"}</em>
                </button>
              ))}
            </div>
          )}
        </section>

        <section className="action-dock" aria-label="主操作">
          <p className={`launcher-notice ${firstError || notice ? "has-text" : ""}`}>
            {notice || userFacingMessage(visibleError) || action.hint}
          </p>
          <button className={`launch-button is-${action.tone}`} type="button" disabled={action.disabled} onClick={() => void action.onClick()}>
            <LaunchButtonIcon tone={action.tone} />
            <span>{action.label}</span>
          </button>
          <div className="action-secondary">
            {mode === "running" && activeTask && onCancelTask ? (
              <button type="button" onClick={() => void onCancelTask(activeTask.id)}>
                暂停这次生成
              </button>
            ) : primaryOutput ? (
              <button type="button" onClick={() => openFolder(primaryOutput, onOpenPath)}>
                打开所在文件夹
              </button>
            ) : (
              <button type="button" onClick={() => void onRefresh()}>
                重新检查
              </button>
            )}
          </div>
        </section>
      </main>
    </div>
  );
}

function SetupInspector({
  kind,
  draft,
  translation,
  asr,
  asrConnections,
  checks,
  onClose,
  onRefresh,
  onDraftChange,
  onPickOutputDirectory,
  onSaveApiKey,
}: {
  kind: InspectorKind;
  draft?: TaskDraft;
  translation?: ServiceConnection;
  asr?: ServiceConnection;
  asrConnections: ServiceConnection[];
  checks: EnvironmentCheck[];
  onClose: () => void;
  onRefresh: () => Promise<void>;
  onDraftChange: (updater: (draft: TaskDraft) => TaskDraft) => void;
  onPickOutputDirectory: (path: string) => void;
  onSaveApiKey: (connection: ServiceConnection, apiKey: string) => Promise<void>;
}) {
  const [apiKey, setApiKey] = useState("");
  const [savingApiKey, setSavingApiKey] = useState(false);
  const [localNotice, setLocalNotice] = useState("");
  const lines = inspectorLines({ kind, draft, translation, asr, checks });
  const apiKeyCanSave = Boolean(translation && apiKey.trim().length > 0 && !savingApiKey);

  async function saveTranslationKey() {
    if (!translation || !apiKeyCanSave) return;
    setSavingApiKey(true);
    setLocalNotice("");
    try {
      await onSaveApiKey(translation, apiKey.trim());
      setApiKey("");
      setLocalNotice("API key 已保存，正在重新检测。");
      await onRefresh();
    } finally {
      setSavingApiKey(false);
    }
  }

  return (
    <div className={`setup-inspector is-${kind}`}>
      <button className="inspector-back" type="button" onClick={onClose}>
        返回检查
      </button>
      <div className="inspector-lines">
        {lines.map((line) => (
          <div className={`inspector-line is-${line.tone}`} key={line.label}>
            <span>{line.label}</span>
            <strong>{line.value}</strong>
          </div>
        ))}
      </div>
      {kind === "translation" ? (
        <div className="inspector-tool">
          <input
            aria-label="翻译服务 API key"
            type="password"
            value={apiKey}
            placeholder={translation ? "粘贴 API key" : "没有可用翻译服务"}
            disabled={!translation || savingApiKey}
            onChange={(event) => setApiKey(event.target.value)}
          />
          <button className="is-primary" type="button" disabled={!apiKeyCanSave} onClick={() => void saveTranslationKey()}>
            {savingApiKey ? "保存中" : "保存 key"}
          </button>
        </div>
      ) : null}
      {kind === "recognition" ? (
        <div className="inspector-tool option-strip">
          {recognitionOptions(asrConnections).map((option) => (
            <button
              className={draft?.speechRecognition.mode === option.mode ? "is-selected" : ""}
              type="button"
              key={option.mode}
              disabled={!draft}
              onClick={() => onDraftChange((current) => setRecognitionMode(current, option.mode, option.connection))}
            >
              {option.label}
            </button>
          ))}
        </div>
      ) : null}
      {kind === "output" ? (
        <div className="inspector-tool output-tool">
          {(["srt", "ass", "vtt"] as ExportFormat[]).map((format) => (
            <button
              className={draft?.output.formats.includes(format) ? "is-selected" : ""}
              type="button"
              key={format}
              disabled={!draft}
              onClick={() => onDraftChange((current) => setOutputFormat(current, format))}
            >
              {outputShortLabel(format)}
            </button>
          ))}
          <button type="button" onClick={() => void chooseOutputDirectory(onPickOutputDirectory, setLocalNotice)}>
            保存位置
          </button>
        </div>
      ) : null}
      <div className="inspector-actions">
        <button type="button" onClick={() => void onRefresh()}>
          重新检测
        </button>
        <span>{localNotice}</span>
      </div>
    </div>
  );
}

function buildChecks({
  draft,
  selectedTranslation,
  selectedAsr,
  environmentChecks,
  onOpenSetup,
}: {
  draft?: TaskDraft;
  selectedTranslation?: ServiceConnection;
  selectedAsr?: ServiceConnection;
  environmentChecks: EnvironmentCheck[];
  onOpenSetup: (kind: InspectorKind) => void;
}): LaunchCheck[] {
  const translationReady = selectedTranslation?.credentialStatus.state === "saved" || selectedTranslation?.credentialStatus.state === "notRequired";
  const routeIssue = environmentChecks.find((check) => check.status === "fail" && checkMatches(check, translationCheckKeys));
  const hasInput = Boolean(draft?.input.path);
  const recognitionNeeded = hasInput && draft?.input.kind !== "subtitle";
  const asrIssue = recognitionNeeded
    ? environmentChecks.find((check) => check.status === "fail" && checkMatches(check, recognitionCheckKeys))
    : undefined;
  const outputFormats = draft?.output.formats.length ? draft.output.formats : ["srt"];

  return [
    {
      id: "translation",
      title: "翻译服务",
      status: translationReady && !routeIssue ? "可以翻译字幕" : translationReady ? "翻译服务需要处理" : "需要保存 API key",
      detail: routeIssue?.impact ?? (translationReady ? serviceReadableName(selectedTranslation) : "缺少模型服务凭据"),
      tone: translationReady && !routeIssue ? "ready" : "attention",
      actionLabel: translationReady && !routeIssue ? "查看" : "设置",
      action: () => onOpenSetup("translation"),
    },
    {
      id: "recognition",
      title: "语音识别",
      status: !hasInput ? "选择片源后判断" : recognitionNeeded ? asrIssue ? "识别还不能用" : recognitionStatus(selectedAsr) : "字幕文件不需要识别",
      detail: !hasInput ? "视频/音频才需要听声音" : recognitionNeeded ? serviceReadableName(selectedAsr) : "会直接翻译现有字幕",
      tone: recognitionNeeded && asrIssue ? "attention" : hasInput ? "ready" : "muted",
      actionLabel: recognitionNeeded ? "查看" : hasInput ? "无需处理" : "待定",
      action: () => onOpenSetup("recognition"),
    },
    {
      id: "output",
      title: "输出字幕",
      status: outputLabel(outputFormats),
      detail: draft?.output.outputDirectory ? "会保存到你选择的位置" : "会保存到任务文件夹",
      tone: "ready",
      actionLabel: "查看",
      action: () => onOpenSetup("output"),
    },
  ];
}

function recognitionOptions(connections: ServiceConnection[]) {
  const localConnection = connections.find((connection) => rawKind(connection) === "local_inprocess" || rawKind(connection) === "local_server")
    ?? connections.find((connection) => rawKind(connection) !== "remote");
  const cloudConnection = connections.find((connection) => rawKind(connection) === "remote");
  return [
    { mode: "auto" as const, label: "自动", connection: localConnection ?? cloudConnection },
    { mode: "local" as const, label: "本机", connection: localConnection },
    { mode: "cloud" as const, label: "远端", connection: cloudConnection },
    { mode: "none" as const, label: "不识别", connection: undefined },
  ];
}

function setRecognitionMode(
  draft: TaskDraft,
  mode: TaskDraft["speechRecognition"]["mode"],
  connection?: ServiceConnection,
): TaskDraft {
  const subtitleSource = mode === "none"
    ? { mode: "auto" as const }
    : mode === "cloud"
      ? { mode: "cloudAsr" as const }
      : mode === "local"
        ? { mode: "localAsr" as const }
        : { mode: "auto" as const };
  return {
    ...draft,
    subtitleSource,
    speechRecognition: {
      ...draft.speechRecognition,
      mode,
      target: connection
        ? { providerName: connection.providerName, model: connection.model ?? connection.models[0] }
        : draft.speechRecognition.target,
    },
  };
}

function setOutputFormat(draft: TaskDraft, format: ExportFormat): TaskDraft {
  return {
    ...draft,
    output: {
      ...draft.output,
      formats: [format],
    },
  };
}

async function chooseOutputDirectory(
  onPickOutputDirectory: (path: string) => void,
  setNotice: (message: string) => void,
) {
  const path = await pickOutputDirectory();
  if (!path) return;
  onPickOutputDirectory(path);
  setNotice("保存位置已更新。");
}

function primaryAction({
  mode,
  draft,
  starting,
  canStart,
  primaryOutput,
  blockingCheck,
  firstError,
  onChooseSource,
  onStartTask,
  onOpenPath,
  onOpenSetup,
}: {
  mode: LauncherMode;
  draft?: TaskDraft;
  starting: boolean;
  canStart: boolean;
  primaryOutput?: PresentedOutputFile;
  blockingCheck?: LaunchCheck;
  firstError?: UserFacingError;
  onChooseSource: () => void;
  onStartTask: () => Promise<void>;
  onOpenPath: (path: string) => void;
  onOpenSetup: (kind: InspectorKind) => void;
}) {
  if (mode === "completed" && primaryOutput?.canOpen) {
    return {
      label: "打开字幕文件",
      hint: "字幕已生成，可以直接打开。",
      disabled: false,
      tone: "done" as const,
      onClick: () => onOpenPath(primaryOutput.path),
    };
  }
  if (mode === "running" || starting) {
    return {
      label: "正在生成字幕",
      hint: "TransVortex 正在处理片源。",
      disabled: true,
      tone: "busy" as const,
      onClick: async () => undefined,
    };
  }
  if (!draft?.input.path) {
    return {
      label: "选择片源",
      hint: "先拖入视频、音频或 SRT 字幕。",
      disabled: false,
      tone: "idle" as const,
      onClick: async () => onChooseSource(),
    };
  }
  if (blockingCheck) {
    return {
      label: blockingCheck.id === "translation" ? "先设置翻译服务" : "先处理识别设置",
      hint: blockingCheck.status,
      disabled: false,
      tone: "blocked" as const,
      onClick: async () => onOpenSetup(blockingCheck.id === "output" ? "output" : blockingCheck.id),
    };
  }
  if (firstError) {
    return {
      label: "处理后重试",
      hint: firstError.impact,
      disabled: false,
      tone: "blocked" as const,
      onClick: async () => onOpenSetup(firstError.source === "asr" ? "recognition" : "translation"),
    };
  }
  return {
    label: canStart ? "开始生成字幕" : "等待准备完成",
    hint: canStart ? "会按当前准备项生成字幕文件。" : "正在读取配置。",
    disabled: !canStart,
    tone: "start" as const,
    onClick: onStartTask,
  };
}

function launcherMode({
  draft,
  starting,
  currentRun,
  primaryOutput,
  errors,
}: {
  draft?: TaskDraft;
  starting: boolean;
  currentRun?: TaskRun;
  primaryOutput?: PresentedOutputFile;
  errors: Array<UserFacingError | undefined>;
}): LauncherMode {
  if (starting || isRunning(currentRun)) return "running";
  if (primaryOutput?.canOpen || currentRun?.phase === "completed") return "completed";
  if (errors.some(Boolean)) return "failed";
  if (!draft?.input.path) return "empty";
  return "ready";
}

function sourceView(draft?: TaskDraft) {
  if (!draft?.input.path) {
    return {
      hasFile: false,
      kind: "empty" as const,
      title: "拖入视频、音频或字幕文件",
      detail: "也可以点击这里选择本地文件",
    };
  }
  return {
    hasFile: true,
    kind: draft.input.kind,
    title: draft.input.displayName,
    detail: inputReadableDetail(draft.input.kind),
  };
}

function inspectorLines({
  kind,
  draft,
  translation,
  asr,
  checks,
}: {
  kind: InspectorKind;
  draft?: TaskDraft;
  translation?: ServiceConnection;
  asr?: ServiceConnection;
  checks: EnvironmentCheck[];
}): InspectorLine[] {
  if (kind === "translation") {
    return [
      { label: "状态", value: translation?.credentialStatus.state === "saved" ? "API key 已保存" : "需要 API key", tone: translation?.credentialStatus.state === "saved" ? "ready" : "attention" },
      { label: "服务", value: serviceReadableName(translation), tone: "ready" },
      { label: "预检", value: checkSummary(checks, translationCheckKeys), tone: checkTone(checks, translationCheckKeys) },
    ];
  }
  if (kind === "recognition") {
    const needsRecognition = !draft?.input.path || draft.input.kind !== "subtitle";
    return [
      { label: "需求", value: needsRecognition ? "视频/音频需要识别声音" : "SRT 字幕不需要识别", tone: "ready" },
      { label: "方式", value: asrReadableName(asr), tone: "ready" },
      { label: "预检", value: checkSummary(checks, recognitionCheckKeys), tone: checkTone(checks, recognitionCheckKeys) },
    ];
  }
  return [
    { label: "字幕", value: outputLabel(draft?.output.formats ?? ["srt"]), tone: "ready" },
    { label: "双语", value: draft?.output.bilingual ? "生成双语字幕" : "只生成目标语言字幕", tone: "ready" },
    { label: "位置", value: draft?.output.outputDirectory ? "保存到你选择的位置" : "保存到任务文件夹", tone: "ready" },
  ];
}

function CheckGlyph({ id, tone }: { id: LaunchCheck["id"]; tone: CheckTone }) {
  if (id === "translation") return <TranslationDeviceIcon tone={tone} />;
  if (id === "recognition") return <RecognitionDeviceIcon tone={tone} />;
  return <SubtitleSheetIcon tone={tone} />;
}

function AppMark() {
  return (
    <svg className="app-mark" viewBox="0 0 38 38" aria-hidden="true">
      <rect x="3" y="3" width="32" height="32" rx="10" />
      <path d="M12 25V15" />
      <path d="M19 25V10" />
      <path d="M26 25V18" />
    </svg>
  );
}

function DropTrayIcon() {
  return (
    <svg className="drop-tray-icon" viewBox="0 0 160 126" aria-hidden="true">
      <path className="tray-shadow" d="M24 83c15 18 94 19 112 0 5 23-10 32-56 32S19 106 24 83Z" />
      <path className="tray-back" d="M34 41h92l12 43c-10 19-105 19-116 0l12-43Z" />
      <path className="tray-front" d="M21 73c10 20 108 20 118 0l-6 22c-9 22-97 23-106 0l-6-22Z" />
      <path className="tray-line" d="M48 58h64M57 72h46" />
      <path className="tray-star" d="M79 16l5 11 11 5-11 5-5 11-5-11-11-5 11-5 5-11Z" />
    </svg>
  );
}

function FileEnvelope({ kind }: { kind: TaskDraft["input"]["kind"] | "empty" }) {
  return (
    <svg className={`file-envelope is-${kind}`} viewBox="0 0 150 112" aria-hidden="true">
      <path className="envelope-back" d="M22 26h88l18 18v48H22V26Z" />
      <path className="envelope-fold" d="M22 44l52 28 54-28" />
      <path className="envelope-tab" d="M93 26v22h35" />
      <path className="envelope-label" d="M38 82h50" />
      <circle className="envelope-seal" cx="112" cy="76" r="13" />
      <path className="envelope-seal-mark" d={kind === "subtitle" ? "M105 73h14M105 79h10" : "M108 69l10 7-10 7Z"} />
    </svg>
  );
}

function TranslationDeviceIcon({ tone }: { tone: CheckTone }) {
  return (
    <svg className={`check-icon is-${tone}`} viewBox="0 0 42 42" aria-hidden="true">
      <rect x="7" y="10" width="28" height="22" rx="8" />
      <path d="M14 20h14M14 25h9" />
      <circle cx="30" cy="15" r="4" />
    </svg>
  );
}

function RecognitionDeviceIcon({ tone }: { tone: CheckTone }) {
  return (
    <svg className={`check-icon is-${tone}`} viewBox="0 0 42 42" aria-hidden="true">
      <path d="M21 8c5 0 8 4 8 10v5c0 6-3 10-8 10s-8-4-8-10v-5c0-6 3-10 8-10Z" />
      <path d="M9 22c1 8 5 12 12 12s11-4 12-12M21 34v4" />
      <path d="M17 18h8M17 23h8" />
    </svg>
  );
}

function SubtitleSheetIcon({ tone }: { tone: CheckTone }) {
  return (
    <svg className={`check-icon is-${tone}`} viewBox="0 0 42 42" aria-hidden="true">
      <path d="M12 7h14l6 7v21H12V7Z" />
      <path d="M26 7v8h6M16 22h12M16 28h9" />
    </svg>
  );
}

function StatusCharmIcon() {
  return (
    <svg className="status-charm" viewBox="0 0 38 38" aria-hidden="true">
      <path d="M19 4l5 8 9 2-6 7 1 10-9-4-9 4 1-10-6-7 9-2 5-8Z" />
      <circle cx="19" cy="19" r="4" />
    </svg>
  );
}

function LaunchButtonIcon({ tone }: { tone: "idle" | "start" | "busy" | "done" | "blocked" }) {
  return (
    <svg className={`launch-icon is-${tone}`} viewBox="0 0 42 42" aria-hidden="true">
      <circle cx="21" cy="21" r="17" />
      {tone === "done" ? <path d="M13 22l5 5 11-13" /> : tone === "blocked" ? <path d="M21 11v13M21 30v1" /> : <path d="M17 13l12 8-12 8Z" />}
    </svg>
  );
}

function WindowMinusIcon() {
  return (
    <svg className="window-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 13h12" />
    </svg>
  );
}

function WindowCloseIcon() {
  return (
    <svg className="window-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M7 7l10 10M17 7 7 17" />
    </svg>
  );
}

async function chooseSource(onPickInput: (path: string) => void, setNotice: (message: string) => void) {
  const path = await pickInputFile();
  if (!path) return;
  onPickInput(path);
  setNotice("");
}

function openFolder(file: PresentedOutputFile, onOpenPath: (path: string) => void) {
  const directory = parentPath(file.path);
  onOpenPath(directory || file.path);
}

function parentPath(path: string) {
  const index = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
  return index > 0 ? path.slice(0, index) : "";
}

function selectedConnection(connections: ServiceConnection[], providerName?: string) {
  return connections.find((connection) => connection.providerName === providerName)
    ?? connections.find((connection) => connection.isDefault)
    ?? connections[0];
}

function isRunning(currentRun?: TaskRun) {
  return Boolean(currentRun && currentRun.phase !== "idle" && currentRun.phase !== "completed" && currentRun.phase !== "failed");
}

function topStatus({
  loading,
  mode,
  blockingCheck,
  currentRun,
}: {
  loading: boolean;
  mode: LauncherMode;
  blockingCheck?: LaunchCheck;
  currentRun?: TaskRun;
}) {
  if (loading) return "正在读取配置";
  if (mode === "running") return currentRun?.currentAction ?? "正在生成字幕";
  if (mode === "completed") return "字幕已生成";
  if (blockingCheck) return blockingCheck.status;
  if (mode === "ready") return "可以开始";
  return "等待片源";
}

function userFacingMessage(error?: UserFacingError) {
  if (!error) return "";
  const isTranslationIssue = error.source === "provider" || /provider|model|key|routing|route/i.test(`${error.title} ${error.impact}`);
  const impact = isTranslationIssue
    ? "翻译服务还没准备好，请检查网络和翻译账号。"
    : error.source === "asr"
      ? "语音识别还不能使用，请检查本机识别或远端识别设置。"
      : simplifyTechnicalWords(error.impact);
  const title = isTranslationIssue ? "翻译服务遇到问题" : simplifyTechnicalWords(error.title);
  return `${title}：${impact}`;
}

function setupTitle(kind: InspectorKind) {
  if (kind === "translation") return "翻译服务是必备启动设置";
  if (kind === "recognition") return "识别方式只在需要听声音时使用";
  return "首轮直接生成字幕文件";
}

function serviceReadableName(connection?: ServiceConnection) {
  if (!connection) return "还没有可用服务";
  if (connection.credentialStatus.state === "missing") return "等待保存 API key";
  return connection.model ? "已选择可用模型" : "服务配置已读取";
}

function asrReadableName(connection?: ServiceConnection) {
  if (!connection) return "还没有识别方式";
  const kind = rawKind(connection);
  if (kind === "local_inprocess") return "本机识别";
  if (kind === "local_server") return "本地识别服务";
  if (kind === "remote") return "远端识别服务";
  return "自动识别";
}

function recognitionStatus(connection?: ServiceConnection) {
  const kind = rawKind(connection);
  if (kind === "local_inprocess") return "可识别视频声音";
  if (kind === "local_server") return "会连接本地识别服务";
  if (kind === "remote") return connection?.credentialStatus.state === "missing" ? "远端识别需要 key" : "会使用远端识别";
  return "会自动选择识别方式";
}

function rawKind(connection?: ServiceConnection) {
  const raw = connection?.rawConfig;
  return typeof raw === "object" && raw !== null && "kind" in raw && typeof raw.kind === "string" ? raw.kind : "";
}

function checkMatches(check: EnvironmentCheck, keys: string[]) {
  const detail = check.technicalDetail ?? "";
  const haystack = `${check.id} ${check.label} ${detail}`.toLowerCase();
  return keys.some((key) => haystack.includes(key.toLowerCase()));
}

function checkSummary(checks: EnvironmentCheck[], ids: string[]) {
  const relevant = checks.filter((check) => checkMatches(check, ids));
  const fail = relevant.find((check) => check.status === "fail");
  if (fail) return fail.impact;
  const warn = relevant.find((check) => check.status === "warn");
  if (warn) return warn.impact;
  return "预检没有发现阻塞";
}

function checkTone(checks: EnvironmentCheck[], ids: string[]): CheckTone {
  return checks.some((check) => checkMatches(check, ids) && check.status === "fail") ? "attention" : "ready";
}

function inputReadableDetail(kind: TaskDraft["input"]["kind"]) {
  if (kind === "subtitle") return "字幕文件 · 会直接翻译成中文字幕";
  if (kind === "segments") return "字幕片段 · 会直接进入翻译";
  return "音视频文件 · 会先获取或识别源字幕";
}

function outputLabel(formats: string[]) {
  if (formats.includes("ass")) return "生成可样式化字幕";
  if (formats.includes("vtt")) return "生成网页字幕";
  return "生成普通 SRT 字幕";
}

function outputShortLabel(format: ExportFormat) {
  if (format === "ass") return "ASS";
  if (format === "vtt") return "VTT";
  return "SRT";
}

function simplifyTechnicalWords(text: string) {
  return text
    .replace(/\bprovider\b/gi, "服务")
    .replace(/\bkey\b/gi, "API key")
    .replace(/\bmodel\b/gi, "模型")
    .replace(/\broute\b/gi, "服务路线")
    .replace(/\brouting\b/gi, "服务路线");
}

function isSupportedInputPath(path: string) {
  return /\.(mp4|mkv|mov|webm|avi|m4v|mp3|wav|m4a|srt)$/i.test(path);
}

async function getTauriWindow() {
  if (!("__TAURI_INTERNALS__" in window)) return null;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow();
}

async function startWindowDrag() {
  const appWindow = await getTauriWindow();
  await appWindow?.startDragging();
}

async function minimizeWindow() {
  const appWindow = await getTauriWindow();
  await appWindow?.minimize();
}

async function closeWindow() {
  const appWindow = await getTauriWindow();
  await appWindow?.close();
}
