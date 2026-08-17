import type {
  ExtensionAPI,
  ExtensionContext,
  SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  commonInput,
  firstBlockReason,
  reportWarning,
} from "../hook-contract.ts";
import { clearNotificationTimer, type HookState } from "../state.ts";

export const runSessionEnd = async (
  pi: ExtensionAPI,
  state: HookState,
  event: SessionShutdownEvent,
  context: ExtensionContext,
): Promise<void> => {
  clearNotificationTimer(state);
  state.pendingPromptContext = undefined;
  if (event.reason === "reload") {
    return;
  }
  let reason: string;
  if (event.reason === "new") {
    reason = "clear";
  } else if (event.reason === "resume") {
    reason = "resume";
  } else if (event.reason === "fork") {
    reason = "other";
  } else {
    reason = context.isIdle() ? "prompt_input_exit" : "other";
  }
  const input = commonInput("SessionEnd", context);
  input["reason"] = reason;
  const results = await runHooks(pi, "SessionEnd", reason, input, context);
  const blockReason = firstBlockReason(results);
  if (blockReason !== undefined) {
    reportWarning(context, blockReason);
  }
};
