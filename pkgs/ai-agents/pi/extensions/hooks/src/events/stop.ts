import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  firstBlockReason,
  hiddenMessage,
  shouldStop,
  type AssistantResult,
} from "../hook-contract.ts";
import type { HookState } from "../state.ts";

export const runStop = async (
  pi: ExtensionAPI,
  state: HookState,
  assistant: AssistantResult,
  context: ExtensionContext,
): Promise<boolean> => {
  const input = commonInput("Stop", context);
  input["last_assistant_message"] = assistant.text;
  input["stop_hook_active"] = state.stopContinuations > 0;
  const results = await runHooks(pi, "Stop", "", input, context);
  if (shouldStop(results)) {
    return true;
  }
  const feedback = [collectContext(results), firstBlockReason(results)]
    .filter((value: string | undefined): value is string => value !== undefined)
    .join("\n");
  if (feedback === "" || state.stopContinuations >= 8) {
    return true;
  }
  state.stopContinuations += 1;
  pi.sendMessage(hiddenMessage(feedback), {
    deliverAs: "followUp",
    triggerTurn: true,
  });
  return false;
};
