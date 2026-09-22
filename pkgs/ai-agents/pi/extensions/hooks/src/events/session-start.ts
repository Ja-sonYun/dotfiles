import type {
  ExtensionAPI,
  ExtensionContext,
  SessionStartEvent,
} from "@earendil-works/pi-coding-agent";

import { runHooks } from "../command-hooks.ts";
import {
  collectContext,
  commonInput,
  firstBlockReason,
  firstSessionTitle,
  getSpecific,
  hiddenMessage,
  reportError,
  reportWarning,
  shouldStop,
} from "../hook-contract.ts";
import { clearNotificationTimer, type HookState } from "../state.ts";

type SessionStartReason = SessionStartEvent["reason"] | "compact";

const sessionSource = (reason: SessionStartReason): string | undefined => {
  if (reason === "reload") {
    return undefined;
  }
  if (reason === "new") {
    return "clear";
  }
  return reason;
};

export const sessionStartInput = (
  pi: ExtensionAPI,
  context: ExtensionContext,
): Record<string, unknown> => {
  const input = commonInput("SessionStart", context);
  input["session_title"] =
    pi.getSessionName() ?? context.sessionManager.getSessionName() ?? "";
  if (context.model !== undefined) {
    input["model"] = `${context.model.provider}/${context.model.id}`;
  }
  return input;
};

export const runSessionStart = async (
  pi: ExtensionAPI,
  state: HookState,
  reason: SessionStartReason,
  context: ExtensionContext,
  input: Record<string, unknown> = sessionStartInput(pi, context),
): Promise<void> => {
  const source = sessionSource(reason);
  if (source === undefined) {
    return;
  }
  clearNotificationTimer(state);
  state.pendingPromptContext = undefined;
  input["source"] = source;
  const results = await runHooks(pi, "SessionStart", source, input, context);
  const blockReason = firstBlockReason(results);
  if (blockReason !== undefined) {
    reportWarning(context, blockReason);
  }
  for (const result of results) {
    const specific = getSpecific(result.output);
    for (const field of ["initialUserMessage", "watchPaths", "reloadSkills"]) {
      if (specific?.[field] !== undefined) {
        reportError(
          context,
          `SessionStart ${field} is not supported by Pi hooks.`,
        );
      }
    }
  }
  const title = firstSessionTitle(results);
  if (title !== undefined && ["startup", "resume", "fork"].includes(source)) {
    pi.setSessionName(title);
  }
  const additionalContext = collectContext(results);
  if (additionalContext !== undefined) {
    pi.sendMessage(hiddenMessage(additionalContext), {
      deliverAs: "nextTurn",
    });
  }
  if (shouldStop(results)) {
    context.shutdown();
  }
};
