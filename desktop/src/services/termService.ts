import type { TermPresetExportRequest } from "../domain/term";
import { invokeCommand } from "./tauriClient";

export type TermPresetExportResult = {
  ok: boolean;
  path?: string;
  report?: {
    exported?: number;
    skipped?: unknown[];
    duplicates?: unknown[];
    conflicts?: unknown[];
  };
};

export async function exportTaskMemoryPreset(request: TermPresetExportRequest): Promise<TermPresetExportResult> {
  return invokeCommand<TermPresetExportResult>("export_memory_preset", request);
}
