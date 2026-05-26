import { doctorPayloadToEnvironmentChecks } from "../adapters/environmentAdapter";
import type { EnvironmentCheck } from "../domain/environment";
import { invokeCommand } from "./tauriClient";

export async function runEnvironmentDoctor(): Promise<EnvironmentCheck[]> {
  const payload = await invokeCommand<unknown>("doctor");
  return doctorPayloadToEnvironmentChecks(payload);
}

export async function probeSubtitleStreams(input: string): Promise<unknown> {
  return invokeCommand<unknown>("probe_subtitle_streams", { input });
}
