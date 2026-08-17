import type {
  ExtensionAPI,
  ExtensionContext,
  SessionCompactEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  commonInput,
  firstBlockReason,
  reportWarning,
} from "../hook-contract.ts";

export const runPostCompact = async (
  pi: ExtensionAPI,
  event: SessionCompactEvent,
  context: ExtensionContext,
): Promise<void> => {
  const trigger = event.reason === "manual" ? "manual" : "auto";
  const input = commonInput("PostCompact", context);
  input["compact_summary"] = event.compactionEntry.summary;
  input["trigger"] = trigger;
  const results = await runHooks(pi, "PostCompact", trigger, input, context);
  const blockReason = firstBlockReason(results);
  if (blockReason !== undefined) {
    reportWarning(context, blockReason);
  }
};
