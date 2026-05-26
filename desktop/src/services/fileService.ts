import { open } from "@tauri-apps/plugin-dialog";
import { invokeCommand } from "./tauriClient";

export async function pickInputFile(): Promise<string | null> {
  const selected = await open({
    multiple: false,
    directory: false,
  });

  return typeof selected === "string" ? selected : null;
}

export async function openPath(path: string): Promise<void> {
  await invokeCommand<void>("open_path", { path });
}
