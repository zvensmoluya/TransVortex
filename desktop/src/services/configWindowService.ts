import { WebviewWindow } from "@tauri-apps/api/webviewWindow";

export type ConfigWindowKind = "translation" | "recognition";

const CONFIG_WINDOW_LABELS: Record<ConfigWindowKind, string> = {
  translation: "translation-config",
  recognition: "recognition-config",
};

export const CONFIG_UPDATED_EVENT = "transvortex-config-updated";
export const ASR_SELECTION_EVENT = "transvortex-asr-selection";

export type AsrSelectionPayload = {
  mode: "auto" | "local" | "cloud" | "none";
  providerName?: string;
  model?: string;
};

export function configWindowLabel(kind: ConfigWindowKind): string {
  return CONFIG_WINDOW_LABELS[kind];
}

export function configKindFromLabel(label: string): ConfigWindowKind | undefined {
  if (label === CONFIG_WINDOW_LABELS.translation) return "translation";
  if (label === CONFIG_WINDOW_LABELS.recognition) return "recognition";
  return undefined;
}

export async function openConfigWindow(kind: ConfigWindowKind): Promise<void> {
  const label = configWindowLabel(kind);
  const existing = await WebviewWindow.getByLabel(label);
  if (existing) {
    await existing.show();
    await existing.setFocus();
    return;
  }

  const window = new WebviewWindow(label, {
    title: kind === "translation" ? "翻译模型设置" : "语音识别设置",
    width: 680,
    height: 520,
    minWidth: 680,
    minHeight: 520,
    maxWidth: 680,
    maxHeight: 520,
    resizable: false,
    maximizable: false,
    fullscreen: false,
    decorations: false,
    url: windowUrl(),
  });

  window.once("tauri://created", () => {
    void window.show().then(() => window.setFocus());
  });
}

function windowUrl(): string {
  const current = window.location.href;
  const hashIndex = current.indexOf("#");
  return hashIndex >= 0 ? current.slice(0, hashIndex) : current;
}
