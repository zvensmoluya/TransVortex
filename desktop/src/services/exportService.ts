import type { ExportFormat, ExportJob } from "../domain/export";
import { invokeCommand } from "./tauriClient";

export type ReexportTaskOptions = {
  formats: ExportFormat[];
  bilingual?: boolean;
  bilingualOrder?: "source_first" | "target_first";
  preferSingleLine?: boolean;
};

export async function reexportTask(taskId: string, options: ReexportTaskOptions): Promise<ExportJob> {
  const payload = await invokeCommand<unknown>("reexport_task", {
    taskId,
    outputFormat: mapReexportFormats(options.formats),
    bilingual: options.bilingual,
    subtitleBilingualOrder: options.bilingualOrder ? mapBilingualOrder(options.bilingualOrder) : undefined,
    subtitlePreferSingleLine: options.preferSingleLine,
  });
  return reexportPayloadToExportJob(taskId, options.formats, payload);
}

function mapReexportFormats(formats: ExportFormat[]): string {
  if (formats.length === 1) {
    return formats[0];
  }
  if (formats.includes("srt") && formats.includes("ass")) {
    return "both";
  }
  return formats[0] ?? "srt";
}

function mapBilingualOrder(order: NonNullable<ReexportTaskOptions["bilingualOrder"]>): "target_source" | "source_target" {
  return order === "source_first" ? "source_target" : "target_source";
}

function reexportPayloadToExportJob(taskId: string, formats: ExportFormat[], payload: unknown): ExportJob {
  const raw = payload && typeof payload === "object" ? (payload as Record<string, unknown>) : {};
  const outputPaths = raw.output_paths && typeof raw.output_paths === "object" ? raw.output_paths as Record<string, unknown> : {};
  const exportedFormats = Object.keys(outputPaths).filter((format): format is ExportFormat =>
    format === "srt" || format === "ass" || format === "vtt",
  );

  return {
    id: `export-${taskId}-${Date.now()}`,
    taskId,
    formats: exportedFormats.length > 0 ? exportedFormats : formats,
    status: "exported",
    updatedAt: new Date().toISOString(),
  };
}
