import { invokeCommand } from "./tauriClient";

export type DesktopNotificationRequest = {
  title: string;
  body?: string;
};

export async function showDesktopNotification(request: DesktopNotificationRequest): Promise<void> {
  await invokeCommand<void>("show_desktop_notification", {
    title: request.title,
    body: request.body ?? null,
  });
}
