import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import { commonInput, reportError } from "../hook-contract.ts";
import { clearNotificationTimer, type HookState } from "../state.ts";

type NotificationType = "idle_prompt" | "permission_prompt";

export const runNotification = async (
  pi: ExtensionAPI,
  type: NotificationType,
  context: ExtensionContext,
): Promise<void> => {
  const input = commonInput("Notification", context);
  input["message"] =
    type === "permission_prompt"
      ? "Pi is waiting for permission"
      : "Pi is waiting for input";
  input["notification_type"] = type;
  input["title"] = "Pi";
  await runHooks(pi, "Notification", type, input, context);
};

export const scheduleNotification = (
  pi: ExtensionAPI,
  state: HookState,
  context: ExtensionContext,
): void => {
  clearNotificationTimer(state);
  state.notificationTimer = setTimeout(() => {
    state.notificationTimer = undefined;
    void runNotification(pi, "idle_prompt", context).catch((error: unknown) => {
      reportError(
        context,
        `Notification hook failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    });
  }, 60_000);
  state.notificationTimer.unref();
};
