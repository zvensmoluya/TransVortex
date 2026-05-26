import { open } from "@tauri-apps/plugin-dialog";
import { invokeCommand } from "./tauriClient";

export async function pickInputFile(): Promise<string | null> {
  const selected = await open({
    multiple: false,
    directory: false,
    filters: [
      {
        name: "音视频与字幕",
        extensions: ["mp4", "mkv", "mov", "webm", "avi", "m4v", "mp3", "wav", "m4a", "srt"],
      },
    ],
  });

  return typeof selected === "string" ? selected : null;
}

export async function pickOutputDirectory(): Promise<string | null> {
  const selected = await open({
    multiple: false,
    directory: true,
  });

  return typeof selected === "string" ? selected : null;
}

export async function openPath(path: string): Promise<void> {
  await invokeCommand<void>("open_path", { path });
}
