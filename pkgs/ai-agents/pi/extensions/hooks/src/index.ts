import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import {
  runNotification,
  scheduleNotification,
} from "./events/notification.ts";
import { runPostCompact } from "./events/post-compact.ts";
import { runPostToolBatch } from "./events/post-tool-batch.ts";
import { runPostToolUse } from "./events/post-tool-use.ts";
import { runPostToolUseFailure } from "./events/post-tool-use-failure.ts";
import { runPreCompact } from "./events/pre-compact.ts";
import { runPreToolUse } from "./events/pre-tool-use.ts";
import { runSessionEnd } from "./events/session-end.ts";
import { runSessionStart } from "./events/session-start.ts";
import { runStop } from "./events/stop.ts";
import { runStopFailure } from "./events/stop-failure.ts";
import {
  runUserPromptSubmit,
  takePromptContext,
} from "./events/user-prompt-submit.ts";
import { lastAssistantResult } from "./hook-contract.ts";
import { registerHookUI } from "./hook-ui.ts";
import { clearNotificationTimer, createHookState } from "./state.ts";

export default function registerHooks(pi: ExtensionAPI): void {
  const state = createHookState();
  let currentContext: ExtensionContext | undefined;
  registerHookUI(pi);

  const disposePermissionPrompt = pi.events.on(
    "permissions:ui_prompt",
    async () => {
      if (currentContext !== undefined) {
        await runNotification(pi, "permission_prompt", currentContext);
      }
    },
  );

  pi.on("session_start", async (event, context) => {
    currentContext = context;
    await runSessionStart(pi, state, event.reason, context);
  });

  pi.on("input", async (event, context) =>
    runUserPromptSubmit(pi, state, event, context),
  );

  pi.on("before_agent_start", () => takePromptContext(state));

  pi.on("tool_call", async (event, context) =>
    runPreToolUse(pi, state, event, context),
  );

  pi.on("tool_result", async (event, context) => {
    state.toolRecords.set(event.toolCallId, { input: event.input });
    return event.isError
      ? runPostToolUseFailure(pi, event, context)
      : runPostToolUse(pi, event, context);
  });

  pi.on("turn_end", async (event, context) =>
    runPostToolBatch(pi, state, event, context),
  );

  pi.on("session_before_compact", async (event, context) =>
    runPreCompact(pi, event, context),
  );

  pi.on("session_compact", async (event, context) => {
    await runPostCompact(pi, event, context);
    await runSessionStart(pi, state, "compact", context);
  });

  pi.on("agent_start", () => {
    clearNotificationTimer(state);
  });

  pi.on("agent_settled", async (_event, context) => {
    const assistant = lastAssistantResult(context);
    if (assistant === undefined || assistant.stopReason === "aborted") {
      return;
    }
    if (assistant.stopReason === "error") {
      await runStopFailure(pi, assistant, context);
      return;
    }
    if (await runStop(pi, state, assistant, context)) {
      scheduleNotification(pi, state, context);
    }
  });

  pi.on("session_shutdown", async (event, context) => {
    currentContext = undefined;
    disposePermissionPrompt();
    await runSessionEnd(pi, state, event, context);
  });
}
