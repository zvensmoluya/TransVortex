import { providerConfigsToServiceConnections } from "../adapters/providerAdapter";
import { taskRecordsToTasks } from "../adapters/taskRecordAdapter";
import { doctorPayloadToEnvironmentChecks } from "../adapters/environmentAdapter";
import type { EnvironmentCheck } from "../domain/environment";
import type { ServiceConnection } from "../domain/serviceConnection";
import type { Task } from "../domain/task";
import { invokeCommand } from "./tauriClient";

export type DesktopSnapshot = {
  config: unknown;
  serviceConnections: ServiceConnection[];
  tasks: Task[];
  runtime: unknown;
  environmentChecks: EnvironmentCheck[];
};

export async function getDesktopSnapshot(): Promise<DesktopSnapshot> {
  const payload = await invokeCommand<unknown>("desktop_snapshot");
  return desktopSnapshotFromPayload(payload);
}

export function desktopSnapshotFromPayload(payload: unknown): DesktopSnapshot {
  const raw = isRecord(payload) ? payload : {};
  const config = raw.config;
  return {
    config,
    serviceConnections: [
      ...providerConfigsToServiceConnections(config, "translation"),
      ...providerConfigsToServiceConnections(config, "asr"),
    ],
    tasks: taskRecordsToTasks(Array.isArray(raw.tasks) ? raw.tasks : []),
    runtime: raw.runtime,
    environmentChecks: doctorPayloadToEnvironmentChecks(raw.environment),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
