import type { ExportFormat } from "../domain/export";
import type { TaskDraft } from "../domain/task";

export type StartTaskPayload = {
  input: string;
  inputType?: string;
  outputDir?: string;
  sourceLang: string;
  targetLang: string;
  bilingual: boolean;
  provider?: string;
  model?: string;
  asrProvider?: string;
  asrModel?: string;
  sourceMode?: string;
  subtitleTrack?: string;
  outputFormat?: string;
  translationStylePreset?: string;
  translationStylePrompt?: string;
  subtitleQualityMode?: string;
  subtitleCompressionEnabled?: boolean;
  subtitleReflowEnabled?: boolean;
  subtitleBilingualOrder?: "target_source" | "source_target";
  subtitlePreferSingleLine?: boolean;
  memoryEnabled?: boolean;
  memoryBootstrapEnabled?: boolean;
  memoryInjectEnabled?: boolean;
  memoryPatchEnabled?: boolean;
  memoryPreset?: string;
};

export function taskDraftToStartTaskPayload(draft: TaskDraft): StartTaskPayload {
  const subtitleMapping = mapSubtitleSource(draft);

  return {
    input: draft.input.path ?? "",
    inputType: mapInputType(draft),
    outputDir: draft.output.outputDirectory,
    sourceLang: draft.languages.sourceLanguage,
    targetLang: draft.languages.targetLanguage,
    bilingual: draft.output.bilingual,
    provider: draft.translation.target.providerName,
    model: draft.translation.target.model,
    asrProvider: draft.speechRecognition.target?.providerName,
    asrModel: draft.speechRecognition.target?.model,
    sourceMode: subtitleMapping.sourceMode,
    subtitleTrack: subtitleMapping.subtitleTrack,
    outputFormat: mapOutputFormats(draft.output.formats),
    translationStylePreset: draft.translation.style,
    translationStylePrompt: [draft.translation.projectContext, draft.translation.stylePrompt]
      .filter(Boolean)
      .join("\n\n"),
    subtitleQualityMode: draft.advanced.qualityMode,
    subtitleCompressionEnabled: draft.advanced.compressionEnabled,
    subtitleReflowEnabled: draft.advanced.reflowEnabled,
    subtitleBilingualOrder: mapBilingualOrder(draft.output.bilingualOrder),
    subtitlePreferSingleLine: draft.output.preferSingleLine,
    memoryEnabled: draft.terms.useProjectTerms || draft.terms.allowSystemSuggestions,
    memoryBootstrapEnabled: draft.terms.allowSystemSuggestions,
    memoryInjectEnabled: draft.terms.useProjectTerms,
    memoryPatchEnabled: draft.terms.allowSystemSuggestions,
    memoryPreset: draft.terms.selectedTermBaseId,
  };
}

function mapSubtitleSource(draft: TaskDraft): { sourceMode?: string; subtitleTrack?: string } {
  if (draft.input.kind === "subtitle") {
    return { sourceMode: undefined };
  }

  switch (draft.subtitleSource.mode) {
    case "auto":
      return { sourceMode: "auto" };
    case "embedded":
      return { sourceMode: "embedded_subtitle", subtitleTrack: draft.subtitleSource.streamId };
    case "localAsr":
      return { sourceMode: "asr" };
    case "cloudAsr":
      return { sourceMode: "asr" };
    case "existingSubtitle":
      return { sourceMode: undefined };
  }
}

function mapInputType(draft: TaskDraft): "video" | "srt" {
  return draft.input.kind === "subtitle" ? "srt" : "video";
}

function mapOutputFormats(formats: ExportFormat[]): string | undefined {
  if (formats.length === 0) {
    return undefined;
  }
  if (formats.length === 1) {
    return formats[0];
  }
  if (formats.includes("srt") && formats.includes("ass") && formats.length === 2) {
    return "both";
  }
  if (formats.includes("srt") && formats.includes("ass")) {
    return "both";
  }
  return formats[0];
}

function mapBilingualOrder(order: TaskDraft["output"]["bilingualOrder"]): "target_source" | "source_target" {
  return order === "source_first" ? "source_target" : "target_source";
}
