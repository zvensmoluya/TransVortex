import type { ExportFormat } from "../domain/export";
import type { TaskDraft, TaskInputKind } from "../domain/task";
import type { ServiceConnection } from "../domain/serviceConnection";

type RawConfig = Record<string, unknown>;

export function configToTaskDraft(config: unknown, connections: ServiceConnection[], previousDraft?: TaskDraft): TaskDraft {
  const raw = isRecord(config) ? config : {};
  const pipeline = isRecord(raw.pipeline) ? raw.pipeline : {};
  const routing = isRecord(raw.routing) ? raw.routing : {};
  const primary = isRecord(routing.primary) ? routing.primary : {};
  const translation = isRecord(pipeline.translation) ? pipeline.translation : {};
  const subtitle = isRecord(pipeline.subtitle) ? pipeline.subtitle : {};
  const quality = isRecord(subtitle.quality) ? subtitle.quality : {};
  const memory = isRecord(pipeline.memory) ? pipeline.memory : {};
  const memoryInject = isRecord(memory.inject) ? memory.inject : {};
  const memoryBootstrap = isRecord(memory.bootstrap) ? memory.bootstrap : {};
  const memoryPatch = isRecord(memory.patch) ? memory.patch : {};
  const subtitleStyle = isRecord(pipeline.subtitle_ass_style) ? pipeline.subtitle_ass_style : {};
  const defaultConnection = connections.find((connection) => connection.kind === "translation" && connection.isDefault);
  const activeAsrProvider = stringValue(pipeline.asr_provider);
  const defaultAsrConnection = connections.find((connection) => connection.kind === "asr" && connection.isDefault)
    ?? connections.find((connection) => connection.kind === "asr");
  const selectedAsrConnection = connections.find((connection) => connection.kind === "asr" && connection.providerName === activeAsrProvider)
    ?? defaultAsrConnection;
  const outputFormats = outputFormatToList(stringValue(pipeline.output_format) ?? "srt");
  const selectedAsrRaw = isRecord(selectedAsrConnection?.rawConfig) ? selectedAsrConnection.rawConfig : {};
  const asrMode = asrKindToDraft(stringValue(selectedAsrRaw.kind));

  return {
    input: previousDraft?.input ?? {
      kind: "video",
      path: undefined,
      displayName: "选择本地素材",
    },
    languages: previousDraft?.languages ?? {
      sourceLanguage: "ja",
      targetLanguage: "zh-CN",
    },
    subtitleSource: previousDraft?.subtitleSource ?? { mode: sourceModeToDraft(stringValue(pipeline.source_mode)) },
    translation: {
      target: {
        providerName: stringValue(primary.provider) ?? defaultConnection?.providerName ?? "",
        model: stringValue(primary.model) ?? defaultConnection?.model,
      },
      style: "natural",
      projectContext: previousDraft?.translation.projectContext ?? "",
      stylePrompt: previousDraft?.translation.stylePrompt ?? stringValue(translation.style_prompt) ?? "",
    },
    speechRecognition: {
      mode: previousDraft?.speechRecognition.mode ?? asrMode,
      target: {
        providerName: previousDraft?.speechRecognition.target?.providerName
          ?? selectedAsrConnection?.providerName
          ?? "",
        model: previousDraft?.speechRecognition.target?.model
          ?? selectedAsrConnection?.model
          ?? selectedAsrConnection?.models[0],
      },
    },
    terms: {
      selectedTermBaseId: previousDraft?.terms.selectedTermBaseId,
      useProjectTerms: booleanValue(memoryInject.enabled, true),
      allowSystemSuggestions: booleanValue(memoryBootstrap.enabled, true),
      enforceLockedTerms: true,
    },
    output: {
      formats: outputFormats,
      bilingual: previousDraft?.output.bilingual ?? false,
      bilingualOrder: stringValue(subtitleStyle.bilingual_order) === "source_target" ? "source_first" : "target_first",
      preferSingleLine: booleanValue(subtitleStyle.prefer_single_line, true),
      outputDirectory: previousDraft?.output.outputDirectory,
    },
    advanced: {
      qualityMode: stringValue(quality.mode) === "conservative" ? "conservative" : "balanced",
      compressionEnabled: booleanValue(isRecord(subtitle.compression) ? subtitle.compression.enabled : undefined, false),
      reflowEnabled: booleanValue(isRecord(subtitle.reflow) ? subtitle.reflow.enabled : undefined, false),
    },
  };
}

export function updateDraftInput(draft: TaskDraft, path: string): TaskDraft {
  const displayName = path.split(/[\\/]/).pop() || path;
  return {
    ...draft,
    input: {
      kind: inputKindFromPath(path),
      path,
      displayName,
    },
  };
}

function outputFormatToList(format: string): ExportFormat[] {
  const normalized = format.toLowerCase();
  if (normalized === "both") return ["srt", "ass"];
  if (normalized === "ass") return ["ass"];
  if (normalized === "vtt" || normalized === "webvtt") return ["vtt"];
  return ["srt"];
}

function sourceModeToDraft(mode?: string): TaskDraft["subtitleSource"]["mode"] {
  if (mode === "embedded_subtitle") return "embedded";
  if (mode === "asr") return "localAsr";
  return "auto";
}

function asrKindToDraft(kind?: string): TaskDraft["speechRecognition"]["mode"] {
  if (kind === "remote") return "cloud";
  if (kind === "local_inprocess" || kind === "local_server") return "local";
  return "auto";
}

function inputKindFromPath(path: string): TaskInputKind {
  const extension = path.split(".").pop()?.toLowerCase();
  return extension === "srt" ? "subtitle" : "video";
}

function isRecord(value: unknown): value is RawConfig {
  return typeof value === "object" && value !== null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function booleanValue(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}
