import { useEffect, useMemo, useRef, useState, type CSSProperties, type DragEvent } from "react";
import asrCharmArt from "../../assets/transvortex/asr-config-charm.png";
import actionShellArt from "../../assets/transvortex/primary-action-shell.png";
import type { PresentedOutputFile, TaskPresentation } from "../../adapters/taskPresentationAdapter";
import type { EnvironmentCheck } from "../../domain/environment";
import type { UserFacingError } from "../../domain/error";
import type { ServiceConnection } from "../../domain/serviceConnection";
import type { Task, TaskDraft } from "../../domain/task";
import type { TaskRun } from "../../domain/taskRun";
import { pickInputFile, pickOutputDirectory } from "../../services/fileService";
import { openConfigWindow, type ConfigWindowKind } from "../../services/configWindowService";
import "./clientHome.css";

type ClientHomePageProps = {
  draft?: TaskDraft;
  loading: boolean;
  starting: boolean;
  cancelingTaskId?: string;
  activeTask?: Task;
  activeTaskPresentation?: TaskPresentation;
  currentRun?: TaskRun;
  recentTasks?: Task[];
  serviceConnections: ServiceConnection[];
  environmentChecks: EnvironmentCheck[];
  providerError?: UserFacingError;
  environmentError?: UserFacingError;
  taskError?: UserFacingError;
  workspaceError?: UserFacingError;
  onPickInput: (path: string) => void;
  onPickOutputDirectory?: (path: string) => void;
  onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void;
  onStartTask: () => Promise<void>;
  onOpenPath: (path: string) => void;
  onCancelTask?: (taskId: string) => Promise<void>;
  onResumeTask?: (taskId: string) => Promise<void>;
};

type LauncherMode = "empty" | "ready" | "running" | "canceling" | "completed" | "failed";
type CheckTone = "ready" | "attention" | "muted";
type LaunchTone = "start" | "busy" | "done" | "blocked";

type LaunchCheck = {
  id: "translation" | "recognition";
  title: string;
  status: string;
  detail: string;
  tone: CheckTone;
  actionLabel: string;
  action: () => void;
};

type PrimaryAction = {
  label: string;
  hint: string;
  disabled: boolean;
  tone: LaunchTone;
  onClick: () => Promise<void> | void;
};

const translationCheckKeys = ["routing", "route", "provider_protocol", "env_key", "missing_env", "翻译服务", "服务协议", "路由"];
const recognitionCheckKeys = ["asr", "faster_whisper", "识别", "ASR", "本地识别"];

export function ClientHomePage({
  draft,
  loading,
  starting,
  cancelingTaskId,
  activeTask,
  activeTaskPresentation,
  currentRun,
  recentTasks = [],
  serviceConnections,
  environmentChecks,
  providerError,
  environmentError,
  taskError,
  workspaceError,
  onPickInput,
  onPickOutputDirectory,
  onPatchDraft,
  onStartTask,
  onOpenPath,
  onCancelTask,
  onResumeTask,
}: ClientHomePageProps) {
  const [dragOver, setDragOver] = useState(false);
  const [notice, setNotice] = useState("");
  const pickInputRef = useRef(onPickInput);

  useEffect(() => {
    pickInputRef.current = onPickInput;
  }, [onPickInput]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    let clearDragTimer: number | undefined;

    const clearDragOver = () => {
      if (clearDragTimer !== undefined) {
        window.clearTimeout(clearDragTimer);
        clearDragTimer = undefined;
      }
      setDragOver(false);
    };

    const keepDragOverAlive = () => {
      if (clearDragTimer !== undefined) window.clearTimeout(clearDragTimer);
      clearDragTimer = window.setTimeout(() => {
        setDragOver(false);
        clearDragTimer = undefined;
      }, 1200);
    };

    const handleWindowBlur = () => clearDragOver();
    const handleDragEnd = () => clearDragOver();

    window.addEventListener("blur", handleWindowBlur);
    window.addEventListener("dragend", handleDragEnd);

    async function listenForDroppedFiles() {
      const appWindow = await getTauriWindow();
      if (!appWindow || cancelled) return;
      unlisten = await appWindow.onDragDropEvent((event) => {
        const payload = event.payload;
        if (payload.type === "enter" || payload.type === "over") {
          setDragOver(true);
          keepDragOverAlive();
          return;
        }
        if (payload.type === "leave") {
          clearDragOver();
          return;
        }
        if (payload.type === "drop") {
          clearDragOver();
          const path = payload.paths.find(isSupportedInputPath);
          if (path) {
            pickInputRef.current(path);
            setNotice("");
          } else {
            setNotice("片源匣只接收音视频或 SRT");
          }
        }
      });
    }

    void listenForDroppedFiles();
    return () => {
      cancelled = true;
      clearDragOver();
      window.removeEventListener("blur", handleWindowBlur);
      window.removeEventListener("dragend", handleDragEnd);
      unlisten?.();
    };
  }, []);

  const handleDragEnter = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragOver(true);
  };
  const handleDragOver = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragOver(true);
  };
  const handleDragLeave = (event: DragEvent<HTMLDivElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    setDragOver(false);
  };
  const handleDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragOver(false);
    const path = filePathFromBrowserDrop(event);
    if (!path) return;
    if (isSupportedInputPath(path)) {
      pickInputRef.current(path);
      setNotice("");
    } else {
      setNotice("片源匣只接收音视频或 SRT");
    }
  };

  const translationConnections = serviceConnections.filter((connection) => connection.kind === "translation");
  const asrConnections = serviceConnections.filter((connection) => connection.kind === "asr");
  const selectedTranslation = selectedConnection(translationConnections, draft?.translation.target.providerName);
  const selectedAsr = selectedConnection(asrConnections, draft?.speechRecognition.target?.providerName);
  const taskStateApplies = taskMatchesDraftSource(activeTask, draft);
  const currentTaskRun = taskStateApplies ? currentRun : undefined;
  const primaryOutput = taskStateApplies ? activeTaskPresentation?.delivery.primaryOutput : undefined;
  const taskFlowError = draft?.input.path
    ? taskError ?? (taskStateApplies ? currentTaskRun?.error ?? activeTask?.error : undefined)
    : undefined;
  const canceling = taskStateApplies && isCancelingTask(activeTask, currentTaskRun, cancelingTaskId);
  const mode = launcherMode({ draft, starting, canceling, currentRun: currentTaskRun, primaryOutput, errors: [taskFlowError] });
  const checks = useMemo(
    () => buildChecks({
      draft,
      selectedTranslation,
      selectedAsr,
      environmentChecks,
      onOpenConfig: (kind) => void openConfigWindow(kind),
    }),
    [draft, environmentChecks, selectedAsr, selectedTranslation],
  );
  const blockingCheck = draft?.input.path ? checks.find((check) => check.tone === "attention") : undefined;
  const firstError = taskFlowError ?? providerError ?? environmentError ?? workspaceError;
  const visibleError = blockingCheck ? undefined : firstError;
  const canStart = Boolean(draft?.input.path && mode !== "running" && mode !== "canceling" && !starting && !blockingCheck);
  const statusLine = topStatus({ loading, mode, blockingCheck, currentRun: currentTaskRun });
  const source = sourceView(draft);
  const action = primaryAction({
    mode,
    draft,
    starting,
    canStart,
    primaryOutput,
    blockingCheck,
    firstError,
    onStartTask,
    onOpenPath,
    onOpenConfig: (kind) => void openConfigWindow(kind),
  });
  const progressPercent = progressFor(mode, currentTaskRun, primaryOutput);
  const caption = notice || userFacingMessage(visibleError) || action?.hint || statusLine;

  return (
    <div
      className={`client-home atelier-${mode}${dragOver ? " is-drag-over" : ""}`}
      onDragEnter={handleDragEnter}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <header className="client-titlebar">
        <div
          className="client-titlebar-drag"
          data-tauri-drag-region
        >
          <BrandSigil />
          <div className="client-titlebar-copy">
            <strong>TransVortex</strong>
            <small>{statusLine}</small>
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

      <main className="atelier-stage" aria-label="字幕工坊">
        <DecorativeLace />

        <section className="source-cradle" aria-label="片源匣">
          <SourceTrayArt />
          <button className="source-hotspot" type="button" onClick={() => void chooseSource(onPickInput, setNotice)}>
            <SourceGlyph kind={source.kind} />
            <span className="source-ticket">
              <strong>{source.title}</strong>
              <small>{source.detail}</small>
            </span>
          </button>
          <button className="source-swap" type="button" onClick={() => void chooseSource(onPickInput, setNotice)}>
            换片源
          </button>
        </section>

        <section className="service-charms" aria-label="能力接线">
          {checks.map((check) => (
            <button className={`service-charm is-${check.id} is-${check.tone}`} type="button" key={check.id} onClick={check.action}>
              {check.id === "translation" ? <TranslationCharmArt /> : <img className="asr-charm-art" src={asrCharmArt} alt="" draggable={false} />}
              <span className="service-lamp" />
              <span className="service-copy">
                <strong>{check.title}</strong>
                <small>{check.status}</small>
              </span>
              <span className="service-pin">{check.actionLabel}</span>
            </button>
          ))}
        </section>

        <section className="operation-core" aria-label="生成装置">
          <div className="progress-orbit" style={{ "--progress": `${progressPercent}%` } as CSSProperties}>
            <span className="orbit-disc">
              <ProgressGlyph mode={mode} tone={action?.tone ?? "start"} />
            </span>
          </div>
          <button className={`primary-shell is-${action?.tone ?? "start"}`} type="button" disabled={!action || action.disabled} onClick={() => void action?.onClick()}>
            <img src={actionShellArt} alt="" draggable={false} />
            <span>{action?.label ?? "等待片源"}</span>
          </button>
          <p className={caption ? "core-caption has-text" : "core-caption"}>{caption}</p>
          <div className="core-side-actions">
            {mode === "running" && activeTask && onCancelTask ? (
              <button type="button" onClick={() => void onCancelTask(activeTask.id)}>
                停下
              </button>
            ) : primaryOutput ? (
              <button type="button" onClick={() => openFolder(primaryOutput, onOpenPath)}>
                输出匣
              </button>
            ) : null}
          </div>
        </section>

        <section className="option-console" aria-label="制作拨片">
          <FormatSwitcher draft={draft} onPatchDraft={onPatchDraft} />
          <button className={`console-switch${draft?.output.bilingual ? " is-on" : ""}`} type="button" disabled={!draft || !onPatchDraft} onClick={() => toggleBilingual(onPatchDraft)}>
            <SwitchGlyph on={draft?.output.bilingual === true} />
            <span>双语</span>
          </button>
          <button className={`console-switch${draft?.terms.useProjectTerms ? " is-on" : ""}`} type="button" disabled={!draft || !onPatchDraft} onClick={() => toggleTerms(onPatchDraft)}>
            <MemoryGlyph on={draft?.terms.useProjectTerms === true} />
            <span>术语</span>
          </button>
          <button className="console-switch" type="button" disabled={!draft || !onPatchDraft} onClick={() => toggleQuality(onPatchDraft)}>
            <QualityGlyph conservative={draft?.advanced.qualityMode === "conservative"} />
            <span>{draft?.advanced.qualityMode === "conservative" ? "稳妥" : "均衡"}</span>
          </button>
          <button className="console-switch is-output" type="button" disabled={!draft || !onPickOutputDirectory} onClick={() => void chooseOutput(onPickOutputDirectory)}>
            <OutputGlyph />
            <span>{outputDirectoryLabel(draft)}</span>
          </button>
        </section>

        <section className="task-spool" aria-label="任务线轴">
          <div className="spool-ribbon" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          {recentTasks.slice(0, 3).map((task) => (
            <button className={`spool-ticket is-${task.status}`} type="button" key={task.id} onClick={() => openTaskShortcut(task, onOpenPath, onResumeTask)}>
              <TaskStatusGlyph status={task.status} />
              <span>
                <strong>{task.input.displayName}</strong>
                <small>{taskStatusLabel(task)}</small>
              </span>
            </button>
          ))}
          {recentTasks.length === 0 ? (
            <button className="spool-ticket is-empty" type="button" disabled>
              <TaskStatusGlyph status="draft" />
              <span>
                <strong>任务线轴</strong>
                <small>等待第一条字幕</small>
              </span>
            </button>
          ) : null}
        </section>
      </main>
    </div>
  );
}

function buildChecks({
  draft,
  selectedTranslation,
  selectedAsr,
  environmentChecks,
  onOpenConfig,
}: {
  draft?: TaskDraft;
  selectedTranslation?: ServiceConnection;
  selectedAsr?: ServiceConnection;
  environmentChecks: EnvironmentCheck[];
  onOpenConfig: (kind: ConfigWindowKind) => void;
}): LaunchCheck[] {
  const translationReady = selectedTranslation?.credentialStatus.state === "saved" || selectedTranslation?.credentialStatus.state === "notRequired";
  const routeIssue = environmentChecks.find((check) => check.status === "fail" && checkMatches(check, translationCheckKeys));
  const hasInput = Boolean(draft?.input.path);
  const recognitionNeeded = hasInput && draft?.input.kind !== "subtitle" && draft?.speechRecognition.mode !== "none";
  const asrIssue = recognitionNeeded
    ? environmentChecks.find((check) => check.status === "fail" && checkMatches(check, recognitionCheckKeys))
    : undefined;

  return [
    {
      id: "translation",
      title: "翻译魔导",
      status: translationReady && !routeIssue ? "已接线" : translationReady ? "路线待校" : "缺少 key",
      detail: routeIssue?.impact ?? serviceReadableName(selectedTranslation),
      tone: translationReady && !routeIssue ? "ready" : "attention",
      actionLabel: translationReady && !routeIssue ? "调校" : "接线",
      action: () => onOpenConfig("translation"),
    },
    {
      id: "recognition",
      title: "听写晶匣",
      status: !hasInput ? "待片源" : recognitionNeeded ? asrIssue ? "待校准" : recognitionStatus(selectedAsr) : "已旁路",
      detail: !hasInput ? "视频/音频启用" : recognitionNeeded ? serviceReadableName(selectedAsr) : "字幕直送翻译",
      tone: recognitionNeeded && asrIssue ? "attention" : hasInput ? "ready" : "muted",
      actionLabel: recognitionNeeded ? "调校" : "设置",
      action: () => onOpenConfig("recognition"),
    },
  ];
}

function primaryAction({
  mode,
  draft,
  starting,
  canStart,
  primaryOutput,
  blockingCheck,
  firstError,
  onStartTask,
  onOpenPath,
  onOpenConfig,
}: {
  mode: LauncherMode;
  draft?: TaskDraft;
  starting: boolean;
  canStart: boolean;
  primaryOutput?: PresentedOutputFile;
  blockingCheck?: LaunchCheck;
  firstError?: UserFacingError;
  onStartTask: () => Promise<void>;
  onOpenPath: (path: string) => void;
  onOpenConfig: (kind: ConfigWindowKind) => void;
}): PrimaryAction | undefined {
  if (mode === "completed" && primaryOutput?.canOpen) {
    return {
      label: "打开字幕",
      hint: "字幕已装入输出匣",
      disabled: false,
      tone: "done",
      onClick: () => onOpenPath(primaryOutput.path),
    };
  }
  if (mode === "canceling") {
    return {
      label: "收束中",
      hint: "正在让当前任务停稳",
      disabled: true,
      tone: "busy",
      onClick: async () => undefined,
    };
  }
  if (mode === "running" || starting) {
    return {
      label: "制作中",
      hint: "字幕炉正在运转",
      disabled: true,
      tone: "busy",
      onClick: async () => undefined,
    };
  }
  if (!draft?.input.path) {
    return undefined;
  }
  if (blockingCheck) {
    return {
      label: blockingCheck.id === "translation" ? "接好翻译" : "调好听写",
      hint: blockingCheck.detail,
      disabled: false,
      tone: "blocked",
      onClick: () => onOpenConfig(blockingCheck.id),
    };
  }
  if (firstError) {
    const targetKind: ConfigWindowKind = firstError.source === "asr" ? "recognition" : "translation";
    return {
      label: "修好再来",
      hint: firstError.impact,
      disabled: false,
      tone: "blocked",
      onClick: () => onOpenConfig(targetKind),
    };
  }
  return {
    label: canStart ? "开始炼字幕" : "准备中",
    hint: canStart ? "片源、模型和输出已就绪" : "正在读取设置",
    disabled: !canStart,
    tone: "start",
    onClick: onStartTask,
  };
}

function FormatSwitcher({ draft, onPatchDraft }: { draft?: TaskDraft; onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void }) {
  const formats = draft?.output.formats ?? [];
  return (
    <div className="format-wheel" aria-label="输出格式">
      {(["srt", "ass", "vtt"] as const).map((format) => (
        <button
          className={formats.includes(format) ? "is-on" : ""}
          type="button"
          key={format}
          disabled={!draft || !onPatchDraft}
          onClick={() => toggleFormat(format, onPatchDraft)}
        >
          <FormatGlyph active={formats.includes(format)} />
          <span>{format.toUpperCase()}</span>
        </button>
      ))}
    </div>
  );
}

function launcherMode({
  draft,
  starting,
  canceling,
  currentRun,
  primaryOutput,
  errors,
}: {
  draft?: TaskDraft;
  starting: boolean;
  canceling: boolean;
  currentRun?: TaskRun;
  primaryOutput?: PresentedOutputFile;
  errors: Array<UserFacingError | undefined>;
}): LauncherMode {
  if (canceling) return "canceling";
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
      title: "把片源放进来",
      detail: "视频 / 音频 / SRT",
    };
  }
  return {
    hasFile: true,
    kind: draft.input.kind,
    title: draft.input.displayName,
    detail: inputReadableDetail(draft.input.kind),
  };
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
  if (loading) return "读取工坊设置";
  if (mode === "canceling") return "正在收束任务";
  if (mode === "running") return currentRun?.currentAction ?? "字幕制作中";
  if (mode === "completed") return "输出已完成";
  if (blockingCheck) return blockingCheck.status;
  if (mode === "ready") return "炉心待启动";
  if (mode === "failed") return "需要调校";
  return "等待片源";
}

function progressFor(mode: LauncherMode, currentRun?: TaskRun, primaryOutput?: PresentedOutputFile) {
  if (mode === "completed" || primaryOutput?.canOpen) return 100;
  if (currentRun?.progress.percent !== undefined) return Math.max(0, Math.min(100, currentRun.progress.percent));
  if (mode === "canceling") return 76;
  if (mode === "ready") return 12;
  if (mode === "failed") return 66;
  return 0;
}

async function chooseSource(onPickInput: (path: string) => void, setNotice: (message: string) => void) {
  const path = await pickInputFile();
  if (!path) return;
  onPickInput(path);
  setNotice("");
}

async function chooseOutput(onPickOutputDirectory?: (path: string) => void) {
  if (!onPickOutputDirectory) return;
  const path = await pickOutputDirectory();
  if (path) onPickOutputDirectory(path);
}

function toggleFormat(format: TaskDraft["output"]["formats"][number], onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void) {
  onPatchDraft?.((draft) => {
    const current = draft.output.formats;
    const next = current.includes(format)
      ? current.filter((item) => item !== format)
      : [...current, format];
    return {
      ...draft,
      output: {
        ...draft.output,
        formats: next.length > 0 ? next : current,
      },
    };
  });
}

function toggleBilingual(onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void) {
  onPatchDraft?.((draft) => ({
    ...draft,
    output: {
      ...draft.output,
      bilingual: !draft.output.bilingual,
    },
  }));
}

function toggleTerms(onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void) {
  onPatchDraft?.((draft) => ({
    ...draft,
    terms: {
      ...draft.terms,
      useProjectTerms: !draft.terms.useProjectTerms,
      allowSystemSuggestions: !draft.terms.useProjectTerms ? draft.terms.allowSystemSuggestions : false,
    },
  }));
}

function toggleQuality(onPatchDraft?: (updater: (draft: TaskDraft) => TaskDraft) => void) {
  onPatchDraft?.((draft) => ({
    ...draft,
    advanced: {
      ...draft.advanced,
      qualityMode: draft.advanced.qualityMode === "conservative" ? "balanced" : "conservative",
    },
  }));
}

function outputDirectoryLabel(draft?: TaskDraft) {
  if (!draft?.output.outputDirectory) return "输出匣";
  return draft.output.outputDirectory.split(/[\\/]/).pop() || "输出匣";
}

function openFolder(file: PresentedOutputFile, onOpenPath: (path: string) => void) {
  const directory = parentPath(file.path);
  onOpenPath(directory || file.path);
}

function openTaskShortcut(task: Task, onOpenPath: (path: string) => void, onResumeTask?: (taskId: string) => Promise<void>) {
  if (task.recoverability.canResume && onResumeTask) {
    void onResumeTask(task.id);
    return;
  }
  const openable = task.outputs.find((output) => output.path && output.status !== "failed" && output.status !== "notGenerated");
  if (openable) {
    onOpenPath(openable.path);
    return;
  }
  if (task.taskDirectory) onOpenPath(task.taskDirectory);
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

function taskMatchesDraftSource(task?: Task, draft?: TaskDraft) {
  if (!task?.input.path || !draft?.input.path) return false;
  return normalizePathForMatch(task.input.path) === normalizePathForMatch(draft.input.path);
}

function isCancelingTask(task?: Task, currentRun?: TaskRun, cancelingTaskId?: string) {
  if (!task) return false;
  if (task.status === "cancelRequested" || task.id === cancelingTaskId) return true;
  return currentRun?.phase !== "failed" && currentRun?.currentAction === "正在取消任务";
}

function isRunning(currentRun?: TaskRun) {
  return Boolean(currentRun && currentRun.phase !== "idle" && currentRun.phase !== "completed" && currentRun.phase !== "failed");
}

function userFacingMessage(error?: UserFacingError) {
  if (!error) return "";
  const isTranslationIssue = error.source === "provider" || /provider|model|key|routing|route/i.test(`${error.title} ${error.impact}`);
  if (isTranslationIssue) return "翻译魔导需要调校";
  if (error.source === "asr") return "听写晶匣需要调校";
  return simplifyTechnicalWords(error.title || error.impact);
}

function serviceReadableName(connection?: ServiceConnection) {
  if (!connection) return "未接线";
  if (connection.credentialStatus.state === "missing") return "等待 key";
  if (connection.model) return connection.model;
  return connection.displayName;
}

function recognitionStatus(connection?: ServiceConnection) {
  const kind = rawKind(connection);
  if (kind === "local_inprocess") return "本机";
  if (kind === "local_server") return "本地服务";
  if (kind === "remote") return connection?.credentialStatus.state === "missing" ? "缺少 key" : "远端";
  return "自动";
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

function inputReadableDetail(kind: TaskDraft["input"]["kind"]) {
  if (kind === "subtitle") return "字幕直送";
  if (kind === "segments") return "片段直送";
  return "先听写再翻译";
}

function taskStatusLabel(task: Task) {
  switch (task.status) {
    case "completed":
      return "已完成";
    case "running":
      return "制作中";
    case "starting":
      return "启动中";
    case "cancelRequested":
      return "收束中";
    case "failedRecoverable":
      return "可恢复";
    case "failedFatal":
      return "失败";
    case "cancelled":
      return "已取消";
    case "ready":
      return "待处理";
    case "draft":
    default:
      return "草稿";
  }
}

function simplifyTechnicalWords(text: string) {
  return text
    .replace(/\bprovider\b/gi, "服务")
    .replace(/\bkey\b/gi, "API key")
    .replace(/\bmodel\b/gi, "模型")
    .replace(/\broute\b/gi, "路线")
    .replace(/\brouting\b/gi, "路线");
}

function isSupportedInputPath(path: string) {
  return /\.(mp4|mkv|mov|webm|avi|m4v|mp3|wav|m4a|srt)$/i.test(path);
}

function filePathFromBrowserDrop(event: DragEvent<HTMLDivElement>) {
  const file = event.dataTransfer.files?.[0] as (File & { path?: string }) | undefined;
  return file?.path || file?.webkitRelativePath || "";
}

function normalizePathForMatch(path: string) {
  return path.replace(/\\/g, "/").toLowerCase();
}

async function getTauriWindow() {
  if (!("__TAURI_INTERNALS__" in window)) return null;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow();
}

async function minimizeWindow() {
  const appWindow = await getTauriWindow();
  await appWindow?.minimize();
}

async function closeWindow() {
  const appWindow = await getTauriWindow();
  await appWindow?.close();
}

function BrandSigil() {
  return (
    <svg className="brand-sigil" viewBox="0 0 42 42" aria-hidden="true">
      <path className="sigil-bg" d="M8 14c6-9 20-9 26 0 4 6 4 19 0 25H8C4 33 4 20 8 14Z" />
      <path className="sigil-wave" d="M12 27c4-6 7-6 11 0s7 6 11 0" />
      <path className="sigil-spark" d="M21 5l4 7 7 3-7 3-4 7-4-7-7-3 7-3 4-7Z" />
    </svg>
  );
}

function SourceTrayArt() {
  return (
    <svg className="source-tray-art" viewBox="0 0 286 211" aria-hidden="true">
      <defs>
        <linearGradient id="sourceTrayBody" x1="42" y1="38" x2="239" y2="173" gradientUnits="userSpaceOnUse">
          <stop stopColor="#fff8e7" />
          <stop offset="0.48" stopColor="#ffe5f0" />
          <stop offset="1" stopColor="#e5faff" />
        </linearGradient>
        <linearGradient id="sourceTrayInside" x1="55" y1="50" x2="221" y2="144" gradientUnits="userSpaceOnUse">
          <stop stopColor="#ffd2e6" />
          <stop offset="1" stopColor="#fff4cc" />
        </linearGradient>
        <filter id="sourceTrayGlow" x="-20%" y="-22%" width="140%" height="150%">
          <feDropShadow dx="0" dy="16" stdDeviation="12" floodColor="#ff78ad" floodOpacity="0.18" />
          <feDropShadow dx="0" dy="4" stdDeviation="6" floodColor="#61c8de" floodOpacity="0.16" />
        </filter>
      </defs>
      <g filter="url(#sourceTrayGlow)">
        <path className="tray-base-shadow" d="M46 148c23 30 164 33 198 1-10 30-42 43-99 43-60 0-93-13-99-44Z" />
        <path className="tray-body" d="M36 74c22-30 66-45 122-45 51 0 84 13 101 38l-22 92c-30 24-143 24-177 1L36 74Z" />
        <path className="tray-inside" d="M58 80c24-22 58-32 103-31 35 1 60 10 75 25l-15 56c-24 18-121 19-145 0L58 80Z" />
        <path className="tray-front" d="M54 128c34 24 140 25 178 0l-10 37c-30 22-129 22-158 0l-10-37Z" />
        <path className="tray-left-fold" d="M59 81l59 49-43 1c-13-10-20-27-16-50Z" />
        <path className="tray-tab pink" d="M167 31c20 0 33 2 45 8l-5 19h-45l5-27Z" />
        <path className="tray-tab blue" d="M216 45c18 5 31 13 39 25l-8 20h-42l11-45Z" />
        <path className="tray-bow" d="M84 130c-30-20-49-15-58 7 10 23 31 27 61 8 12 27 34 36 57 21 3-25-17-37-60-36Z" />
        <circle className="tray-bow-knot" cx="84" cy="140" r="13" />
        <path className="tray-line" d="M61 165c32 19 126 19 159 0M52 76c45 35 100 53 173 1" />
        <path className="tray-spark" d="M39 56l5 11 11 5-11 5-5 11-5-11-11-5 11-5 5-11Z" />
        <path className="tray-spark small" d="M225 25l4 8 8 4-8 4-4 8-4-8-8-4 8-4 4-8Z" />
      </g>
    </svg>
  );
}

function TranslationCharmArt() {
  return (
    <svg className="translation-charm-art" viewBox="0 0 146 116" aria-hidden="true">
      <defs>
        <linearGradient id="translationCharmShell" x1="24" y1="20" x2="125" y2="94" gradientUnits="userSpaceOnUse">
          <stop stopColor="#fff9ff" />
          <stop offset="0.52" stopColor="#ffeaf6" />
          <stop offset="1" stopColor="#e4faff" />
        </linearGradient>
        <filter id="translationCharmGlow" x="-25%" y="-30%" width="150%" height="160%">
          <feDropShadow dx="0" dy="10" stdDeviation="9" floodColor="#ff78ad" floodOpacity="0.18" />
          <feDropShadow dx="0" dy="2" stdDeviation="5" floodColor="#61c8de" floodOpacity="0.14" />
        </filter>
      </defs>
      <g filter="url(#translationCharmGlow)">
        <path className="translation-wing left" d="M24 46c11-22 33-29 47-17-12 8-22 22-26 37-12 2-21-5-21-20Z" />
        <path className="translation-wing right" d="M122 46c-11-22-33-29-47-17 12 8 22 22 26 37 12 2 21-5 21-20Z" />
        <path className="translation-shell" d="M31 38c16-25 68-25 84 0 10 16 9 42 0 57-16 20-68 20-84 0-9-15-10-41 0-57Z" />
        <path className="translation-screen" d="M42 50c11-13 51-13 62 0 7 9 7 24 0 32-11 13-51 13-62 0-7-8-7-23 0-32Z" />
        <path className="translation-heart" d="M73 16c8-12 25-3 17 11l-17 15-17-15c-8-14 9-23 17-11Z" />
        <path className="translation-line" d="M54 63h38M56 75h28" />
        <path className="translation-cord left" d="M32 88c-15 9-18 22-6 24 12 2 18-8 9-16" />
        <path className="translation-cord right" d="M114 88c15 9 18 22 6 24-12 2-18-8-9-16" />
        <circle className="translation-port" cx="28" cy="92" r="8" />
        <circle className="translation-port" cx="118" cy="92" r="8" />
      </g>
    </svg>
  );
}

function DecorativeLace() {
  return (
    <svg className="decorative-lace" viewBox="0 0 820 518" aria-hidden="true">
      <path className="lace-arc" d="M34 90C114 18 251 17 330 88S546 163 620 78s139-53 165-22" />
      <path className="lace-rail" d="M66 440c92-30 174-27 254 9s169 28 250-11 142-35 197 5" />
      <path className="lace-star" d="M707 113l7 13 13 6-13 6-7 13-7-13-13-6 13-6 7-13Z" />
      <path className="lace-star small" d="M102 122l4 8 8 4-8 4-4 8-4-8-8-4 8-4 4-8Z" />
    </svg>
  );
}

function SourceGlyph({ kind }: { kind: TaskDraft["input"]["kind"] | "empty" }) {
  return (
    <svg className={`source-glyph is-${kind}`} viewBox="0 0 76 76" aria-hidden="true">
      <path className="source-glyph-bg" d="M14 20h34l14 14v28H14V20Z" />
      <path className="source-glyph-fold" d="M48 20v15h14" />
      {kind === "subtitle" ? (
        <>
          <path className="source-glyph-line" d="M23 42h31M23 52h24" />
          <path className="source-glyph-line thin" d="M23 33h15" />
        </>
      ) : kind === "empty" ? (
        <path className="source-glyph-play" d="M32 31l16 9-16 9Z" />
      ) : (
        <>
          <path className="source-glyph-play" d="M31 28l18 10-18 10Z" />
          <path className="source-glyph-line thin" d="M21 56h35" />
        </>
      )}
    </svg>
  );
}

function ProgressGlyph({ mode, tone }: { mode: LauncherMode; tone: LaunchTone }) {
  return (
    <svg className={`progress-glyph is-${mode} is-${tone}`} viewBox="0 0 92 92" aria-hidden="true">
      <path className="progress-glyph-body" d="M19 35c8-17 46-17 54 0 6 14 2 35-27 35S13 49 19 35Z" />
      <path className="progress-glyph-face" d="M32 45h1M58 45h1M36 55c5 5 15 5 20 0" />
      {mode === "running" || mode === "canceling" ? <path className="progress-glyph-motion" d="M22 24c15-10 33-10 48 0" /> : null}
      {tone === "blocked" ? <path className="progress-glyph-alert" d="M46 23v18M46 50v1" /> : null}
      {tone === "done" ? <path className="progress-glyph-alert" d="M33 45l9 9 18-22" /> : null}
    </svg>
  );
}

function FormatGlyph({ active }: { active: boolean }) {
  return (
    <svg className={`format-glyph${active ? " is-active" : ""}`} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M7 4h7l4 4v12H7V4Z" />
      <path d="M14 4v5h4M9 13h6M9 17h4" />
    </svg>
  );
}

function SwitchGlyph({ on }: { on: boolean }) {
  return (
    <svg className={`switch-glyph${on ? " is-on" : ""}`} viewBox="0 0 42 24" aria-hidden="true">
      <path d="M12 5h18c5 0 8 3 8 7s-3 7-8 7H12c-5 0-8-3-8-7s3-7 8-7Z" />
      <circle cx={on ? "29" : "13"} cy="12" r="5" />
    </svg>
  );
}

function MemoryGlyph({ on }: { on: boolean }) {
  return (
    <svg className={`memory-glyph${on ? " is-on" : ""}`} viewBox="0 0 32 32" aria-hidden="true">
      <path d="M8 7h16v19H8V7Z" />
      <path d="M12 12h8M12 17h6M11 7V4M16 7V4M21 7V4" />
    </svg>
  );
}

function QualityGlyph({ conservative }: { conservative: boolean }) {
  return (
    <svg className={`quality-glyph${conservative ? " is-conservative" : ""}`} viewBox="0 0 32 32" aria-hidden="true">
      <path d="M16 4l10 5v7c0 6-4 10-10 12C10 26 6 22 6 16V9l10-5Z" />
      <path d={conservative ? "M11 16l4 4 7-9" : "M10 18c5-7 7-7 12 0"} />
    </svg>
  );
}

function OutputGlyph() {
  return (
    <svg className="output-glyph" viewBox="0 0 32 32" aria-hidden="true">
      <path d="M5 12h22l-3 14H8L5 12Z" />
      <path d="M10 12l3-5h6l3 5M16 15v7M12 19l4 4 4-4" />
    </svg>
  );
}

function TaskStatusGlyph({ status }: { status: Task["status"] }) {
  return (
    <svg className={`task-status-glyph is-${status}`} viewBox="0 0 38 38" aria-hidden="true">
      <circle cx="19" cy="19" r="14" />
      {status === "completed" ? <path d="M12 20l5 5 10-13" /> : status === "failedRecoverable" || status === "failedFatal" ? <path d="M19 10v12M19 28v1" /> : <path d="M15 11l11 8-11 8Z" />}
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
