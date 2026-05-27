import { doctorPayloadToEnvironmentChecks } from "../adapters/environmentAdapter";
import { subtitleStreamsToDomain } from "../adapters/subtitleStreamAdapter";
import type { EnvironmentCheck } from "../domain/environment";
import type { SubtitleStream } from "../domain/task";
import { invokeCommand } from "./tauriClient";

export async function runEnvironmentDoctor(): Promise<EnvironmentCheck[]> {
  const payload = await invokeCommand<unknown>("doctor");
  return doctorPayloadToEnvironmentChecks(payload);
}

export async function probeSubtitleStreams(input: string): Promise<SubtitleStream[]> {
  const payload = await invokeCommand<unknown>("probe_subtitle_streams", { input });
  return subtitleStreamsToDomain(payload);
}
