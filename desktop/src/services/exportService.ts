import type { ExportFormat, ExportJob } from "../domain/export";
import { invokeCommand } from "./tauriClient";

export type ReexportTaskOptions = {
  formats: ExportFormat[];
  bilingual?: boolean;
  bilingualOrder?: "source_first" | "target_first";
  preferSingleLine?: boolean;
};

export async function reexportTask(taskId: string, options: ReexportTaskOptions): Promise<ExportJob> {
  return invokeCommand<ExportJob>("reexport_task", {
    taskId,
    outputFormat: mapReexportFormats(options.formats),
    bilingual: options.bilingual,
    subtitleBilingualOrder: options.bilingualOrder ? mapBilingualOrder(options.bilingualOrder) : undefined,
    subtitlePreferSingleLine: options.preferSingleLine,
  });
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
