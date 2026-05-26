import { invoke } from "@tauri-apps/api/core";

export type TauriCommandArgs = Record<string, unknown>;

export function invokeCommand<TResponse>(command: string, args?: TauriCommandArgs): Promise<TResponse> {
  return invoke<TResponse>(command, args);
}
