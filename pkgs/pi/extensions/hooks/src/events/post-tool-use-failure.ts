import type {
  ExtensionAPI,
  ExtensionContext,
  ToolResultEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  contentText,
  firstBlockReason,
  hiddenMessage,
  shouldStop,
} from "../hook-contract.ts";

export const runPostToolUseFailure = async (
  pi: ExtensionAPI,
  event: ToolResultEvent,
  context: ExtensionContext,
): Promise<void> => {
  const input = commonInput("PostToolUseFailure", context);
  input["tool_input"] = event.input;
  input["tool_name"] = event.toolName;
  input["tool_use_id"] = event.toolCallId;
  input["error"] = contentText(event.content) || JSON.stringify(event.content);
  const results = await runHooks(
    pi,
    "PostToolUseFailure",
    event.toolName,
    input,
    context,
  );
  const feedback = [collectContext(results), firstBlockReason(results)]
    .filter((value: string | undefined): value is string => value !== undefined)
    .join("\n");
  if (feedback !== "") {
    pi.sendMessage(hiddenMessage(feedback), { deliverAs: "steer" });
  }
  if (shouldStop(results)) {
    context.abort();
  }
};
