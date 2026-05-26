import { useMemo } from "react";
import { mockEnvironmentChecks } from "./mockData";

export function useEnvironmentStore() {
  return useMemo(
    () => ({
      checks: mockEnvironmentChecks,
    }),
    [],
  );
}
