import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import { commonInput, reportError } from "../hook-contract.ts";
import { clearNotificationTimer, type HookState } from "../state.ts";

type NotificationType =
  "idle_prompt" | "permission_prompt" | "elicitation_dialog";

export const runNotification = async (
  pi: ExtensionAPI,
  type: NotificationType,
  context: ExtensionContext,
  phase: "start" | "end" = "start",
  resumeState: "running" | "idle" = context.isIdle() ? "idle" : "running",
  input: Record<string, unknown> = commonInput("Notification", context),
): Promise<void> => {
  input["message"] =
    type === "permission_prompt"
      ? "Pi is waiting for permission"
      : "Pi is waiting for input";
  input["notification_type"] = type;
  input["phase"] = phase;
  input["resume_state"] = resumeState;
  input["title"] = "Pi";
  await runHooks(pi, "Notification", type, input, context);
};

export const scheduleNotification = (
  pi: ExtensionAPI,
  state: HookState,
  context: ExtensionContext,
  dispatch: () => Promise<void> = () =>
    runNotification(pi, "idle_prompt", context),
): void => {
  clearNotificationTimer(state);
  state.notificationTimer = setTimeout(() => {
    state.notificationTimer = undefined;
    void dispatch().catch((error: unknown) => {
      reportError(
        context,
        `Notification hook failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    });
  }, 60_000);
  state.notificationTimer.unref();
};
