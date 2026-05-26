import { useMemo } from "react";

export function useUiStore() {
  return useMemo(
    () => ({
      sidebarCollapsed: false,
      reviewPanelPinned: true,
    }),
    [],
  );
}
