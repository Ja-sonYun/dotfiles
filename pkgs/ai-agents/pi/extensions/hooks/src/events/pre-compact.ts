import type {
  ExtensionAPI,
  ExtensionContext,
  SessionBeforeCompactEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import { commonInput, firstBlockReason } from "../hook-contract.ts";

export const runPreCompact = async (
  pi: ExtensionAPI,
  event: SessionBeforeCompactEvent,
  context: ExtensionContext,
): Promise<{ readonly cancel: true } | undefined> => {
  const trigger = event.reason === "manual" ? "manual" : "auto";
  const input = commonInput("PreCompact", context);
  input["trigger"] = trigger;
  if (event.customInstructions !== undefined) {
    input["custom_instructions"] = event.customInstructions;
  }
  const results = await runHooks(pi, "PreCompact", trigger, input, context);
  return firstBlockReason(results) === undefined ? undefined : { cancel: true };
};
