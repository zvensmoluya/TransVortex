import type { ExportFormat } from "../domain/export";
import type { TaskDraft } from "../domain/task";

export type StartTaskPayload = {
  request_version: 1;
  input: string;
  input_type?: string;
  output_dir?: string;
  source_lang: string;
  target_lang: string;
  bilingual: boolean;
  provider?: string;
  model?: string;
  overrides: {
    asr_provider?: string;
    asr_model?: string;
    source_mode?: string;
    subtitle_track?: string;
    output_format?: string;
    translation_style_preset?: string;
    translation_style_prompt?: string;
    subtitle_quality_mode?: string;
    subtitle_compression_enabled?: boolean;
    subtitle_reflow_enabled?: boolean;
    subtitle_ass_style?: {
      bilingual_order?: "target_source" | "source_target";
      prefer_single_line?: boolean;
    };
    memory_enabled?: boolean;
    memory_bootstrap_enabled?: boolean;
    memory_inject_enabled?: boolean;
    memory_patch_enabled?: boolean;
    memory_presets?: Array<{ id: string }>;
  };
};

export function taskDraftToStartTaskPayload(draft: TaskDraft): StartTaskPayload {
  const subtitleMapping = mapSubtitleSource(draft);

  return {
    request_version: 1,
    input: draft.input.path ?? "",
    input_type: mapInputType(draft),
    output_dir: draft.output.outputDirectory,
    source_lang: draft.languages.sourceLanguage,
    target_lang: draft.languages.targetLanguage,
    bilingual: draft.output.bilingual,
    provider: draft.translation.target.providerName,
    model: draft.translation.target.model,
    overrides: compactObject({
      asr_provider: draft.speechRecognition.target?.providerName,
      asr_model: draft.speechRecognition.target?.model,
      source_mode: subtitleMapping.sourceMode,
      subtitle_track: subtitleMapping.subtitleTrack,
      output_format: mapOutputFormats(draft.output.formats),
      translation_style_preset: draft.translation.style,
      translation_style_prompt: [draft.translation.projectContext, draft.translation.stylePrompt]
        .filter(Boolean)
        .join("\n\n"),
      subtitle_quality_mode: draft.advanced.qualityMode,
      subtitle_compression_enabled: draft.advanced.compressionEnabled,
      subtitle_reflow_enabled: draft.advanced.reflowEnabled,
      subtitle_ass_style: compactObject({
        bilingual_order: mapBilingualOrder(draft.output.bilingualOrder),
        prefer_single_line: draft.output.preferSingleLine,
      }),
      memory_enabled: draft.terms.allowSystemSuggestions,
      memory_bootstrap_enabled: draft.terms.allowSystemSuggestions,
      memory_inject_enabled: false,
      memory_patch_enabled: draft.terms.allowSystemSuggestions,
    }),
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

function compactObject<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) => {
      if (item === undefined || item === "") return false;
      if (Array.isArray(item) && item.length === 0) return false;
      if (item && typeof item === "object" && !Array.isArray(item) && Object.keys(item).length === 0) return false;
      return true;
    }),
  ) as T;
}
