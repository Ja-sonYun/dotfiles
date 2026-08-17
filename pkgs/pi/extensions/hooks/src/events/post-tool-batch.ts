import type {
  ExtensionAPI,
  ExtensionContext,
  TurnEndEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  firstBlockReason,
  hiddenMessage,
  shouldStop,
} from "../hook-contract.ts";
import type { HookState } from "../state.ts";

export const runPostToolBatch = async (
  pi: ExtensionAPI,
  state: HookState,
  event: TurnEndEvent,
  context: ExtensionContext,
): Promise<void> => {
  if (event.toolResults.length === 0) {
    return;
  }
  const input = commonInput("PostToolBatch", context);
  input["tool_calls"] = event.toolResults.map((result) => {
    const record = state.toolRecords.get(result.toolCallId);
    const call: Record<string, unknown> = {
      tool_name: result.toolName,
      tool_response: result.content,
      tool_use_id: result.toolCallId,
    };
    if (record !== undefined) {
      call["tool_input"] = record.input;
    }
    return call;
  });
  const results = await runHooks(pi, "PostToolBatch", "", input, context);
  state.toolRecords.clear();
  const additionalContext = collectContext(results);
  if (additionalContext !== undefined) {
    pi.sendMessage(hiddenMessage(additionalContext), { deliverAs: "steer" });
  }
  const blockReason = firstBlockReason(results);
  if (blockReason !== undefined) {
    pi.sendMessage(hiddenMessage(blockReason), { deliverAs: "steer" });
  }
  if (blockReason !== undefined || shouldStop(results)) {
    context.abort();
  }
};
