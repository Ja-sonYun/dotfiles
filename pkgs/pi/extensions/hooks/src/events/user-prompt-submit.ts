import type {
  BeforeAgentStartEventResult,
  ExtensionAPI,
  ExtensionContext,
  InputEvent,
  InputEventResult,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  firstBlockReason,
  firstSessionTitle,
  getStopReason,
  hiddenMessage,
  shouldStop,
} from "../hook-contract.ts";
import { clearNotificationTimer, type HookState } from "../state.ts";

export const runUserPromptSubmit = async (
  pi: ExtensionAPI,
  state: HookState,
  event: InputEvent,
  context: ExtensionContext,
): Promise<InputEventResult> => {
  if (event.source === "extension") {
    return { action: "continue" };
  }
  clearNotificationTimer(state);
  state.pendingPromptContext = undefined;
  state.stopContinuations = 0;
  const input = commonInput("UserPromptSubmit", context);
  input["prompt"] = event.text;
  const results = await runHooks(pi, "UserPromptSubmit", "", input, context);
  const title = firstSessionTitle(results);
  if (title !== undefined) {
    pi.setSessionName(title);
  }
  const blockReason = firstBlockReason(results);
  const stopRequested = shouldStop(results);
  if (blockReason !== undefined || stopRequested) {
    context.ui.notify(
      blockReason ?? getStopReason(results) ?? "Hook stopped the prompt.",
      "warning",
    );
    return { action: "handled" };
  }
  const additionalContext = collectContext(results);
  if (additionalContext !== undefined && !context.isIdle()) {
    pi.sendMessage(hiddenMessage(additionalContext), {
      deliverAs: event.streamingBehavior ?? "followUp",
    });
  } else {
    state.pendingPromptContext = additionalContext;
  }
  return { action: "continue" };
};

export const takePromptContext = (
  state: HookState,
): BeforeAgentStartEventResult | undefined => {
  if (state.pendingPromptContext === undefined) {
    return undefined;
  }
  const content = state.pendingPromptContext;
  state.pendingPromptContext = undefined;
  return { message: hiddenMessage(content) };
};
