export type ExportFormat = "srt" | "ass" | "vtt";

export type ExportSettings = {
  formats: ExportFormat[];
  bilingual: boolean;
  bilingualOrder: "source_first" | "target_first";
  preferSingleLine: boolean;
  outputDirectory?: string;
};

export type ExportedFile = {
  id: string;
  format: ExportFormat;
  path: string;
  status: "notGenerated" | "ready" | "stale" | "failed";
  updatedAt?: string;
};

export type ExportJob = {
  id: string;
  taskId: string;
  formats: ExportFormat[];
  status: "idle" | "queued" | "exporting" | "exported" | "exportFailed";
  error?: string;
  updatedAt?: string;
};
