import type { EnvironmentCheck } from "../domain/environment";
import type { ExportJob } from "../domain/export";
import type { Segment } from "../domain/segment";
import type { ServiceConnection } from "../domain/serviceConnection";
import type { Task, TaskDraft } from "../domain/task";
import type { TaskRun } from "../domain/taskRun";
import type { TermEntry } from "../domain/term";

const now = "2026-05-26T14:40:00+08:00";

export const mockTaskDraft: TaskDraft = {
  input: {
    kind: "video",
    path: "D:/media/interview-cut.mp4",
    displayName: "interview-cut.mp4",
  },
  languages: {
    sourceLanguage: "ja",
    targetLanguage: "zh-CN",
  },
  subtitleSource: { mode: "auto" },
  translation: {
    target: { providerName: "openai", model: "gpt-4.1-mini" },
    style: "natural",
    projectContext: "访谈样片，人物语气克制，保留专有名词。",
    stylePrompt: "译文适合屏幕字幕，避免解释性长句。",
  },
  speechRecognition: {
    mode: "local",
    target: { providerName: "faster-whisper", model: "small" },
  },
  terms: {
    selectedTermBaseId: "project-documentary",
    useProjectTerms: true,
    allowSystemSuggestions: true,
    enforceLockedTerms: true,
  },
  output: {
    formats: ["srt", "ass", "vtt"],
    bilingual: true,
    bilingualOrder: "target_first",
    preferSingleLine: true,
    outputDirectory: "D:/openai/TransVortex/output",
  },
  advanced: {
    qualityMode: "balanced",
    compressionEnabled: true,
    reflowEnabled: true,
  },
};

export const mockTasks: Task[] = [
  {
    id: "task-20260526-interview",
    title: "访谈样片字幕制作",
    status: "running",
    input: {
      kind: "video",
      displayName: "interview-cut.mp4",
      path: "D:/media/interview-cut.mp4",
      durationLabel: "12:48",
    },
    languages: { sourceLanguage: "ja", targetLanguage: "zh-CN" },
    pipeline: [
      { id: "input", label: "输入素材", status: "completed" },
      { id: "subtitleSource", label: "获取源字幕", status: "completed" },
      { id: "translation", label: "翻译字幕", status: "active" },
      { id: "termConsistency", label: "术语一致性", status: "pending" },
      { id: "qualityReview", label: "质量检查", status: "pending" },
      { id: "export", label: "导出交付", status: "pending" },
    ],
    outputs: [
      { id: "srt", format: "srt", path: "output/interview-cut.zh.srt", status: "stale", updatedAt: now },
      { id: "ass", format: "ass", path: "output/interview-cut.zh.ass", status: "notGenerated" },
      { id: "vtt", format: "vtt", path: "output/interview-cut.zh.vtt", status: "notGenerated" },
    ],
    taskDirectory: "artifacts/task-20260526-interview",
    recoverability: { canResume: true, resumeLabel: "可从翻译步骤继续" },
    createdAt: "2026-05-26T14:10:00+08:00",
    updatedAt: now,
  },
  {
    id: "task-20260525-product-demo",
    title: "产品演示字幕复查",
    status: "completed",
    input: {
      kind: "subtitle",
      displayName: "product-demo.en.srt",
      path: "D:/media/product-demo.en.srt",
      durationLabel: "08:12",
    },
    languages: { sourceLanguage: "en", targetLanguage: "zh-CN" },
    pipeline: [
      { id: "input", label: "输入素材", status: "completed" },
      { id: "subtitleSource", label: "获取源字幕", status: "completed" },
      { id: "translation", label: "翻译字幕", status: "completed" },
      { id: "termConsistency", label: "术语一致性", status: "completed" },
      { id: "qualityReview", label: "质量检查", status: "completed" },
      { id: "export", label: "导出交付", status: "completed" },
    ],
    outputs: [
      { id: "srt", format: "srt", path: "output/product-demo.zh.srt", status: "ready", updatedAt: "2026-05-25T16:22:00+08:00" },
      { id: "ass", format: "ass", path: "output/product-demo.zh.ass", status: "ready", updatedAt: "2026-05-25T16:22:00+08:00" },
    ],
    taskDirectory: "artifacts/task-20260525-product-demo",
    recoverability: { canResume: false },
    createdAt: "2026-05-25T16:02:00+08:00",
    updatedAt: "2026-05-25T16:22:00+08:00",
  },
  {
    id: "task-20260525-course",
    title: "课程片段云端识别",
    status: "failedRecoverable",
    input: {
      kind: "video",
      displayName: "course-intro.mov",
      path: "D:/media/course-intro.mov",
      durationLabel: "21:05",
    },
    languages: { sourceLanguage: "en", targetLanguage: "zh-CN" },
    pipeline: [
      { id: "input", label: "输入素材", status: "completed" },
      { id: "subtitleSource", label: "获取源字幕", status: "failed" },
      { id: "translation", label: "翻译字幕", status: "pending" },
      { id: "qualityReview", label: "质量检查", status: "pending" },
      { id: "export", label: "导出交付", status: "pending" },
    ],
    outputs: [],
    recoverability: { canResume: true, resumeLabel: "切换 ASR 服务后继续" },
    error: {
      title: "云端识别服务未通过连接检查",
      impact: "任务还没有进入翻译步骤，当前没有可检查的目标字幕。",
      severity: "blocking",
      source: "asr",
      nextActions: [
        { id: "credentials", label: "检查 ASR 凭据", target: "/services" },
        { id: "local-asr", label: "改用本地识别" },
      ],
    },
    createdAt: "2026-05-25T10:18:00+08:00",
    updatedAt: "2026-05-25T10:27:00+08:00",
  },
];

export const mockTaskRun: TaskRun = {
  taskId: "task-20260526-interview",
  phase: "translation",
  currentAction: "正在翻译字幕，第 7 / 12 个片段",
  progress: {
    percent: 62,
    completedUnits: 7,
    totalUnits: 12,
    label: "翻译 62%",
  },
  timeline: [
    {
      id: "event-1",
      at: "14:11",
      phase: "input",
      title: "已读取输入素材",
      detail: "视频时长 12:48，音轨正常。",
      severity: "success",
    },
    {
      id: "event-2",
      at: "14:16",
      phase: "asr",
      title: "已完成本地识别",
      detail: "生成 186 条源字幕。",
      severity: "success",
    },
    {
      id: "event-3",
      at: "14:33",
      phase: "translation",
      title: "正在翻译字幕",
      detail: "当前模型 gpt-4.1-mini，已完成 7 个片段。",
      severity: "info",
    },
  ],
  warnings: [
    {
      title: "发现部分片段阅读速度偏高",
      impact: "质量检查会在结果页标出这些字幕行。",
      severity: "warning",
      nextActions: [{ id: "review", label: "进入结果检查" }],
    },
  ],
  canCancel: true,
  canResume: true,
  lastEventAt: "2026-05-26T14:40:00+08:00",
};

export const mockSegments: Segment[] = [
  {
    id: "seg-001",
    index: 1,
    startMs: 1260,
    endMs: 4120,
    sourceText: "今日は、字幕制作の流れを確認します。",
    translatedText: "今天我们先确认字幕制作的整体流程。",
    issues: [],
    termMatches: [{ termId: "term-2", source: "字幕制作", expectedTarget: "字幕制作", status: "matched" }],
    diagnostics: { charactersPerSecond: 12.6, lineCount: 1, maxLineLength: 18, overlapsPrevious: false },
    dirtyState: "clean",
  },
  {
    id: "seg-002",
    index: 2,
    startMs: 4860,
    endMs: 7180,
    sourceText: "TransVortex は、作業を段階ごとに保存します。",
    translatedText: "TransVortex 会按步骤保存任务状态。",
    issues: [],
    termMatches: [{ termId: "term-1", source: "TransVortex", expectedTarget: "TransVortex", status: "matched" }],
    diagnostics: { charactersPerSecond: 14.2, lineCount: 1, maxLineLength: 20, overlapsPrevious: false },
    dirtyState: "clean",
  },
  {
    id: "seg-003",
    index: 3,
    startMs: 7320,
    endMs: 8500,
    sourceText: "品質確認は後でまとめて行えます。",
    translatedText: "质量检查可以在后续集中处理。",
    issues: [
      {
        id: "issue-cps-003",
        code: "reading_speed_high",
        severity: "warning",
        title: "阅读速度过快",
        description: "当前行显示时间较短，建议压缩译文或调整时间。",
        segmentId: "seg-003",
        nextActions: [{ id: "compress", label: "压缩译文", target: "segment" }],
      },
    ],
    termMatches: [],
    diagnostics: { charactersPerSecond: 22.8, lineCount: 1, maxLineLength: 15, overlapsPrevious: false },
    dirtyState: "dirty",
  },
  {
    id: "seg-004",
    index: 4,
    startMs: 8940,
    endMs: 11220,
    sourceText: "用語表はプロジェクト資産として扱います。",
    translatedText: "术语表会作为项目资料管理。",
    issues: [
      {
        id: "issue-term-004",
        code: "term_target_conflict",
        severity: "warning",
        title: "术语译名不一致",
        description: "项目术语建议使用“项目术语表”。",
        segmentId: "seg-004",
        nextActions: [{ id: "apply-term", label: "使用确认译名", target: "terms" }],
      },
    ],
    termMatches: [{ termId: "term-3", source: "用語表", expectedTarget: "项目术语表", status: "conflict" }],
    diagnostics: { charactersPerSecond: 13.2, lineCount: 1, maxLineLength: 13, overlapsPrevious: false },
    dirtyState: "savedPendingExport",
  },
  {
    id: "seg-005",
    index: 5,
    startMs: 12080,
    endMs: 14260,
    sourceText: "接続状態を確認してから処理を始めます。",
    translatedText: "",
    issues: [
      {
        id: "issue-empty-005",
        code: "empty_translation",
        severity: "blocking",
        title: "译文为空",
        description: "这一行不能直接交付，需要补齐译文后再导出。",
        segmentId: "seg-005",
        nextActions: [{ id: "edit", label: "补齐译文", target: "segment" }],
      },
    ],
    termMatches: [],
    diagnostics: { charactersPerSecond: 0, lineCount: 1, maxLineLength: 0, overlapsPrevious: false },
    dirtyState: "dirty",
  },
];

export const mockTerms: TermEntry[] = [
  {
    id: "term-1",
    source: "TransVortex",
    target: "TransVortex",
    type: "title",
    status: "locked",
    scope: "project",
    note: "产品名固定不翻译。",
    relatedSegmentIds: ["seg-002"],
  },
  {
    id: "term-2",
    source: "字幕制作",
    target: "字幕制作",
    type: "term",
    status: "confirmed",
    scope: "project",
    relatedSegmentIds: ["seg-001"],
  },
  {
    id: "term-3",
    source: "用語表",
    target: "项目术语表",
    type: "term",
    status: "confirmed",
    scope: "project",
    relatedSegmentIds: ["seg-004"],
  },
  {
    id: "term-4",
    source: "ローカル認識",
    target: "本地识别",
    type: "term",
    status: "proposed",
    scope: "task",
    relatedSegmentIds: [],
  },
];

export const mockServiceConnections: ServiceConnection[] = [
  {
    id: "translation-openai",
    kind: "translation",
    providerName: "openai",
    displayName: "OpenAI 翻译服务",
    model: "gpt-4.1-mini",
    credentialStatus: { state: "saved", source: "user_auth_file", label: "凭据已保存" },
    connectionStatus: { state: "connected", label: "连接正常", checkedAt: now },
    isDefault: true,
    fallbackTargets: [{ providerName: "compatible-gateway", model: "qwen-plus" }],
    expertConfigAvailable: true,
  },
  {
    id: "translation-compatible",
    kind: "translation",
    providerName: "compatible-gateway",
    displayName: "兼容网关",
    model: "qwen-plus",
    credentialStatus: { state: "missing", label: "缺少凭据" },
    connectionStatus: { state: "untested", label: "尚未测试" },
    isDefault: false,
    fallbackTargets: [],
    expertConfigAvailable: true,
  },
  {
    id: "asr-local",
    kind: "asr",
    providerName: "faster-whisper",
    displayName: "本地识别",
    model: "small",
    credentialStatus: { state: "notRequired", label: "无需凭据" },
    connectionStatus: { state: "connected", label: "本地可用", checkedAt: now },
    isDefault: true,
    fallbackTargets: [],
    expertConfigAvailable: false,
  },
  {
    id: "asr-openai",
    kind: "asr",
    providerName: "openai-transcriptions",
    displayName: "OpenAI 云端识别",
    model: "whisper-1",
    credentialStatus: { state: "missing", label: "缺少凭据" },
    connectionStatus: { state: "failed", label: "未连接", message: "需要保存 ASR 服务凭据。" },
    isDefault: false,
    fallbackTargets: [],
    expertConfigAvailable: true,
  },
];

export const mockEnvironmentChecks: EnvironmentCheck[] = [
  {
    id: "python",
    label: "任务运行环境",
    status: "pass",
    category: "blocking",
    impact: "可以启动字幕任务。",
    nextActions: [{ id: "none", label: "无需处理" }],
  },
  {
    id: "ffmpeg",
    label: "ffmpeg / ffprobe",
    status: "pass",
    category: "blocking",
    impact: "可以读取媒体信息并提取音频。",
    nextActions: [{ id: "none", label: "无需处理" }],
  },
  {
    id: "faster-whisper",
    label: "本地识别模型",
    status: "warn",
    category: "quality_risk",
    impact: "本地识别可运行，但模型缓存不完整，首次任务会更慢。",
    nextActions: [{ id: "prepare", label: "预热本地模型", target: "/diagnostics" }],
  },
  {
    id: "asr-credential",
    label: "云端 ASR 凭据",
    status: "warn",
    category: "optional",
    impact: "云端识别不可用，但可以继续使用本地识别。",
    nextActions: [{ id: "services", label: "配置 ASR 服务", target: "/services" }],
  },
];

export const mockExportJob: ExportJob = {
  id: "export-job-demo",
  taskId: "task-20260526-interview",
  formats: ["srt", "ass", "vtt"],
  status: "exporting",
  updatedAt: now,
};
