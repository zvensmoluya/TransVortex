import type { Segment } from "../domain/segment";
import type { SubtitleIssue } from "../domain/subtitleIssue";

type RawSegment = Record<string, unknown>;

export function resultWorkspaceToSegments(payload: unknown): Segment[] {
  const rawSegments = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { segments?: unknown[] })?.segments)
      ? (payload as { segments: unknown[] }).segments
      : [];

  return rawSegments.map((segment, index) => resultSegmentToSegment(segment, index));
}

export function resultSegmentToSegment(segment: unknown, index = 0): Segment {
  const raw = (segment ?? {}) as RawSegment;
  const startMs = secondsToMs(numberValue(raw.start));
  const endMs = secondsToMs(numberValue(raw.end));
  const segmentId = stringValue(raw.id) || `segment-${index + 1}`;
  const qualityIssues = normalizeQualityIssueList(raw.quality_issues, segmentId);

  return {
    id: segmentId,
    index: numberValue(raw.index) ?? index + 1,
    startMs,
    endMs,
    sourceText: stringValue(raw.text_src) || stringValue(raw.sourceText) || "",
    translatedText: stringValue(raw.text_tgt) || stringValue(raw.translatedText) || "",
    issues: [...normalizeIssueList(raw.issues, segmentId), ...qualityIssues],
    termMatches: [],
    diagnostics: {
      charactersPerSecond: calculateCps(stringValue(raw.text_tgt), startMs, endMs),
      lineCount: (stringValue(raw.text_tgt) || "").split("\n").length,
      maxLineLength: Math.max(...(stringValue(raw.text_tgt) || "").split("\n").map((line) => line.length), 0),
      overlapsPrevious: false,
    },
    dirtyState: "clean",
  };
}

export function segmentsToSavePayload(segments: Segment[]): unknown[] {
  return segments.map((segment) => ({
    id: segment.id,
    start: segment.startMs / 1000,
    end: segment.endMs / 1000,
    text_src: segment.sourceText,
    text_tgt: segment.translatedText,
  }));
}

function normalizeIssueList(value: unknown, segmentId: string): SubtitleIssue[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((issue, index) => ({
    id: `${segmentId}-issue-${index + 1}`,
    code: String(issue),
    severity: "warning",
    title: String(issue),
    segmentId,
    nextActions: [{ id: "review", label: "检查这一行", target: "segment" }],
  }));
}

function normalizeQualityIssueList(value: unknown, segmentId: string): SubtitleIssue[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((issue, index) => {
    const raw = issue && typeof issue === "object" ? (issue as RawSegment) : {};
    const code = stringValue(raw.code) || `quality-${index + 1}`;
    return {
      id: `${segmentId}-quality-${index + 1}`,
      code,
      severity: mapIssueSeverity(stringValue(raw.level)),
      title: issueTitle(code, stringValue(raw.message)),
      description: stringValue(raw.message),
      segmentId,
      nextActions: [{ id: "review", label: "检查这一行", target: "segment" }],
    };
  });
}

function mapIssueSeverity(level?: string): SubtitleIssue["severity"] {
  if (level === "error" || level === "blocking") return "blocking";
  if (level === "info") return "info";
  return "warning";
}

function issueTitle(code: string, fallback?: string): string {
  const titles: Record<string, string> = {
    empty_translation: "译文为空",
    invalid_time: "时间轴异常",
    overlap: "时间轴重叠",
    cps_high: "阅读速度过快",
    reading_speed_high: "阅读速度过快",
    line_too_long: "单行过长",
    too_many_lines: "行数过多",
    duration_too_short: "显示时间过短",
  };
  return titles[code] ?? fallback ?? code;
}

function secondsToMs(value: number | undefined): number {
  return Math.round((value ?? 0) * 1000);
}

function calculateCps(text: string | undefined, startMs: number, endMs: number): number {
  const seconds = Math.max((endMs - startMs) / 1000, 0.1);
  return Math.round(((text?.length ?? 0) / seconds) * 10) / 10;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
