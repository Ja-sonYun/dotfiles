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
import { runSessionEnd, sessionEndInput } from "./events/session-end.ts";
import { runSessionStart, sessionStartInput } from "./events/session-start.ts";
import { runStop } from "./events/stop.ts";
import { runStopFailure } from "./events/stop-failure.ts";
import {
  runUserPromptSubmit,
  takePromptContext,
} from "./events/user-prompt-submit.ts";
import { runHooks } from "./command-hooks.ts";
import {
  commonInput,
  contentText,
  isRecord,
  reportError,
  type AssistantResult,
} from "./hook-contract.ts";
import { registerHookUI } from "./hook-ui.ts";
import { clearNotificationTimer, createHookState } from "./state.ts";

export default function registerHooks(pi: ExtensionAPI): void {
  const state = createHookState();
  let assistant: AssistantResult | undefined;
  let runSignal: AbortSignal | undefined;
  let pendingLifecycle = Promise.resolve();
  let promptResumeState: "running" | "idle" = "idle";
  registerHookUI(pi);

  const enqueueLifecycle = (
    action: () => Promise<unknown>,
    context: ExtensionContext,
  ): Promise<void> => {
    pendingLifecycle = pendingLifecycle.then(action).then(
      () => undefined,
      (error: unknown) => {
        reportError(
          context,
          error instanceof Error ? error.message : String(error),
        );
      },
    );
    return pendingLifecycle;
  };

  pi.on("ui_prompt_start", (event, context) => {
    const input = commonInput("Notification", context);
    promptResumeState = context.isIdle() ? "idle" : "running";
    const resumeState = promptResumeState;
    return enqueueLifecycle(
      () =>
        runNotification(
          pi,
          event.kind === "confirm" ? "permission_prompt" : "elicitation_dialog",
          context,
          "start",
          resumeState,
          input,
        ),
      context,
    );
  });

  pi.on("ui_prompt_end", (event, context) => {
    const input = commonInput("Notification", context);
    const resumeState = promptResumeState;
    return enqueueLifecycle(
      () =>
        runNotification(
          pi,
          event.kind === "confirm" ? "permission_prompt" : "elicitation_dialog",
          context,
          "end",
          resumeState,
          input,
        ),
      context,
    );
  });

  pi.on("session_info_changed", (event, context) => {
    const input = commonInput("SessionInfoChanged", context);
    input["session_title"] = event.name ?? "";
    return enqueueLifecycle(
      () => runHooks(pi, "SessionInfoChanged", "", input, context),
      context,
    );
  });

  pi.on("session_start", async (event, context) => {
    const input = sessionStartInput(pi, context);
    clearNotificationTimer(state);
    assistant = undefined;
    state.toolRecords.clear();
    await enqueueLifecycle(
      () => runSessionStart(pi, state, event.reason, context, input),
      context,
    );
  });

  pi.on("input", async (event, context) => {
    await pendingLifecycle;
    return runUserPromptSubmit(pi, state, event, context);
  });

  pi.on("before_agent_start", () => takePromptContext(state));

  pi.on("tool_call", async (event, context) => {
    await pendingLifecycle;
    state.toolRecords.set(event.toolCallId, {
      input: event.input,
      postHandled: false,
    });
    return runPreToolUse(pi, state, event, context);
  });

  pi.on("tool_result", async (event, context) => {
    await pendingLifecycle;
    const signal = context.signal;
    const record = {
      input: event.input,
      postHandled: false,
    };
    state.toolRecords.set(event.toolCallId, record);
    const result = event.isError
      ? await runPostToolUseFailure(pi, event, context)
      : await runPostToolUse(pi, event, context);
    record.postHandled = event.isError || !signal?.aborted;
    return result;
  });

  pi.on("tool_execution_end", async (event, context) => {
    await pendingLifecycle;
    const record = state.toolRecords.get(event.toolCallId);
    if (record === undefined || record.postHandled) {
      return;
    }
    record.postHandled = true;
    const result = isRecord(event.result) ? event.result : undefined;
    await runPostToolUseFailure(
      pi,
      {
        type: "tool_result",
        toolName: event.toolName,
        toolCallId: event.toolCallId,
        input: record.input,
        content: [
          {
            type: "text",
            text:
              contentText(result?.["content"]) ||
              "Tool call was blocked or cancelled.",
          },
        ],
        details: result?.["details"],
        isError: true,
      },
      context,
    );
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") {
      return;
    }
    assistant = {
      stopReason: event.message.stopReason,
      text: contentText(event.message.content),
      ...(event.message.errorMessage === undefined
        ? {}
        : { errorMessage: event.message.errorMessage }),
    };
  });

  pi.on("turn_end", async (event, context) =>
    runPostToolBatch(pi, state, event, context),
  );

  pi.on("session_before_compact", async (event, context) =>
    runPreCompact(pi, event, context),
  );

  pi.on("session_compact", async (event, context) => {
    const input = sessionStartInput(pi, context);
    await runPostCompact(pi, event, context);
    await enqueueLifecycle(
      () => runSessionStart(pi, state, "compact", context, input),
      context,
    );
  });

  pi.on("agent_start", (_event, context) => {
    assistant = undefined;
    runSignal = context.signal;
    clearNotificationTimer(state);
  });

  pi.on("agent_settled", async (_event, context) => {
    const result = runSignal?.aborted
      ? {
          stopReason: "aborted",
          text: assistant?.text ?? "",
          errorMessage: "Agent run was cancelled.",
        }
      : (assistant ?? {
          stopReason: "aborted",
          text: "",
          errorMessage: "Agent run was cancelled before receiving a response.",
        });
    const failed =
      result.stopReason === "error" ||
      result.stopReason === "aborted" ||
      result.stopReason === "length";
    const input = commonInput(failed ? "StopFailure" : "Stop", context);
    input["stop_hook_active"] = state.stopContinuations > 0;
    const notificationInput = commonInput("Notification", context);
    await enqueueLifecycle(async () => {
      if (failed) {
        await runStopFailure(pi, result, context, input);
        return;
      }
      if (await runStop(pi, state, result, context, input)) {
        scheduleNotification(pi, state, context, () =>
          enqueueLifecycle(
            () =>
              runNotification(
                pi,
                "idle_prompt",
                context,
                "start",
                "idle",
                notificationInput,
              ),
            context,
          ),
        );
      }
    }, context);
  });

  pi.on("session_shutdown", async (event, context) => {
    const input = sessionEndInput(event, context);
    clearNotificationTimer(state);
    await enqueueLifecycle(
      () => runSessionEnd(pi, state, event, context, input),
      context,
    );
    state.toolRecords.clear();
  });
}
