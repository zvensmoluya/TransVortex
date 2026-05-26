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

  return {
    id: stringValue(raw.id) || `segment-${index + 1}`,
    index: numberValue(raw.index) ?? index + 1,
    startMs,
    endMs,
    sourceText: stringValue(raw.text_src) || stringValue(raw.sourceText) || "",
    translatedText: stringValue(raw.text_tgt) || stringValue(raw.translatedText) || "",
    issues: normalizeIssueList(raw.issues, stringValue(raw.id) || `segment-${index + 1}`),
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
