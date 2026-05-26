import { useMemo } from "react";
import { mockTerms } from "./mockData";

export function useTermStore() {
  return useMemo(
    () => ({
      terms: mockTerms,
    }),
    [],
  );
}
