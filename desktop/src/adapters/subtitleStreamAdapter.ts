import type { SubtitleStream } from "../domain/task";

type RawSubtitleStream = Record<string, unknown>;

export function subtitleStreamsToDomain(payload: unknown): SubtitleStream[] {
  const streams = Array.isArray(payload)
    ? payload
    : Array.isArray((payload as { streams?: unknown[] })?.streams)
      ? (payload as { streams: unknown[] }).streams
      : [];

  return streams.map((stream, index) => rawSubtitleStreamToDomain(stream, index));
}

export function rawSubtitleStreamToDomain(stream: unknown, index = 0): SubtitleStream {
  const raw = (stream ?? {}) as RawSubtitleStream;
  return {
    id: stringValue(raw.id) || `subtitle-stream-${index + 1}`,
    index: numberValue(raw.index) ?? index + 1,
    codecName: stringValue(raw.codecName) || stringValue(raw.codec_name) || "",
    language: stringValue(raw.language) || "",
    title: stringValue(raw.title) || "",
    default: booleanValue(raw.default),
    forced: booleanValue(raw.forced),
    supported: booleanValue(raw.supported),
  };
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function booleanValue(value: unknown): boolean {
  return value === true || value === 1 || value === "1" || value === "true";
}
