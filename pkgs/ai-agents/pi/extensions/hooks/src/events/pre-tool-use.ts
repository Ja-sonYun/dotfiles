import type {
  ExtensionAPI,
  ExtensionContext,
  ToolCallEvent,
  ToolCallEventResult,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  getSpecific,
  getStopReason,
  getString,
  hiddenMessage,
  isRecord,
  reportError,
  shouldStop,
} from "../hook-contract.ts";
import type { HookState } from "../state.ts";

const permissionPriority: Readonly<Record<string, number>> = {
  allow: 1,
  ask: 2,
  defer: 3,
  deny: 4,
};

export const runPreToolUse = async (
  pi: ExtensionAPI,
  state: HookState,
  event: ToolCallEvent,
  context: ExtensionContext,
): Promise<ToolCallEventResult | undefined> => {
  const input = commonInput("PreToolUse", context);
  if (state.promptId !== undefined) {
    input["prompt_id"] = state.promptId;
  }
  input["tool_input"] = event.input;
  input["tool_name"] = event.toolName;
  input["tool_use_id"] = event.toolCallId;
  const results = await runHooks(
    pi,
    "PreToolUse",
    event.toolName,
    input,
    context,
  );
  const stopRequested = shouldStop(results);
  const updatedInputValues = results
    .map((result) => getSpecific(result.output)?.["updatedInput"])
    .filter((value) => value !== undefined);
  if (updatedInputValues.some((value) => !isRecord(value))) {
    const reason = "PreToolUse updatedInput must be an object.";
    reportError(context, reason);
    return {
      block: true,
      reason,
      ...(stopRequested ? { terminate: true } : {}),
    };
  }
  if (updatedInputValues.length > 1) {
    const reason = "Multiple PreToolUse hooks returned updatedInput.";
    reportError(context, reason);
    return {
      block: true,
      reason,
      ...(stopRequested ? { terminate: true } : {}),
    };
  }
  const updatedInput = updatedInputValues.find(isRecord);
  if (updatedInput !== undefined) {
    for (const key of Object.keys(event.input)) {
      Reflect.deleteProperty(event.input, key);
    }
    Object.assign(event.input, updatedInput);
  }

  let decision: string | undefined;
  let reason: string | undefined;
  let priority = 0;
  for (const result of results) {
    if (result.blockReason !== undefined) {
      if (priority < (permissionPriority["deny"] ?? 4)) {
        reason = result.blockReason;
      }
      decision = "deny";
      priority = permissionPriority["deny"] ?? 4;
      continue;
    }
    const specific = getSpecific(result.output);
    const candidate = getString(specific, "permissionDecision");
    const candidatePriority =
      candidate === undefined ? 0 : (permissionPriority[candidate] ?? 0);
    if (candidate !== undefined && candidatePriority === 0) {
      decision = "deny";
      reason = `Unsupported PreToolUse permissionDecision: ${candidate}`;
      priority = 5;
      reportError(context, reason);
      continue;
    }
    if (candidatePriority > priority) {
      decision = candidate;
      reason = getString(specific, "permissionDecisionReason");
      priority = candidatePriority;
    }
  }

  if (stopRequested) {
    decision = "deny";
    reason = getStopReason(results) ?? "PreToolUse hook stopped the agent.";
  }

  if (decision !== "defer") {
    const additionalContext = collectContext(results);
    if (additionalContext !== undefined) {
      pi.sendMessage(hiddenMessage(additionalContext), {
        deliverAs: "steer",
      });
    }
  }
  if (decision === "deny") {
    return {
      block: true,
      reason: reason ?? "Tool use denied by hook.",
      ...(stopRequested ? { terminate: true } : {}),
    };
  }
  if (decision === "defer") {
    const message = "Pi cannot defer tool calls from an extension hook.";
    reportError(context, message);
    return { block: true, reason: message };
  }
  if (decision === "ask") {
    if (!context.hasUI) {
      return {
        block: true,
        reason:
          reason ?? "Tool confirmation requires an interactive Pi session.",
      };
    }
    const confirmed = await context.ui.confirm(
      "Pi hook approval",
      reason ?? `Allow ${event.toolName}?`,
    );
    if (!confirmed) {
      return {
        block: true,
        reason: reason ?? "Tool use rejected.",
      };
    }
  }
  return undefined;
};
