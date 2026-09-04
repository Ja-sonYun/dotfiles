import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type HookMessage = {
  readonly content: string;
  readonly customType: string;
  readonly display: boolean;
};

export type HookEventName =
  | "SessionStart"
  | "UserPromptSubmit"
  | "PreToolUse"
  | "PostToolUse"
  | "PostToolUseFailure"
  | "PostToolBatch"
  | "Stop"
  | "StopFailure"
  | "PreCompact"
  | "PostCompact"
  | "SessionEnd"
  | "Notification";

export type HookResult = {
  readonly blockReason?: string;
  readonly output?: Readonly<Record<string, unknown>>;
  readonly plain?: string;
};

export type AssistantResult = {
  readonly errorMessage?: string;
  readonly stopReason: string;
  readonly text: string;
};

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const reportError = (
  context: ExtensionContext,
  message: string,
): void => {
  if (context.hasUI) {
    context.ui.notify(message, "error");
    return;
  }
  console.error(message);
};

export const reportWarning = (
  context: ExtensionContext,
  message: string,
): void => {
  if (context.hasUI) {
    context.ui.notify(message, "warning");
    return;
  }
  console.error(message);
};

export const getString = (
  value: Readonly<Record<string, unknown>> | undefined,
  key: string,
): string | undefined => {
  const field = value?.[key];
  return typeof field === "string" ? field : undefined;
};

export const getBoolean = (
  value: Readonly<Record<string, unknown>> | undefined,
  key: string,
): boolean | undefined => {
  const field = value?.[key];
  return typeof field === "boolean" ? field : undefined;
};

export const getSpecific = (
  output: Readonly<Record<string, unknown>> | undefined,
): Readonly<Record<string, unknown>> | undefined => {
  const specific = output?.["hookSpecificOutput"];
  return isRecord(specific) ? specific : undefined;
};

export const collectContext = (
  results: ReadonlyArray<HookResult>,
): string | undefined => {
  const values: string[] = [];
  for (const result of results) {
    if (result.plain !== undefined) {
      values.push(result.plain);
    }
    const topLevel = getString(result.output, "additionalContext");
    if (topLevel !== undefined) {
      values.push(topLevel);
    }
    const specific = getString(getSpecific(result.output), "additionalContext");
    if (specific !== undefined) {
      values.push(specific);
    }
  }
  return values.length === 0 ? undefined : values.join("\n");
};

export const firstBlockReason = (
  results: ReadonlyArray<HookResult>,
): string | undefined => {
  for (const result of results) {
    if (result.blockReason !== undefined) {
      return result.blockReason;
    }
    if (getString(result.output, "decision") === "block") {
      return getString(result.output, "reason") ?? "Hook blocked the action.";
    }
  }
  return undefined;
};

export const firstSessionTitle = (
  results: ReadonlyArray<HookResult>,
): string | undefined => {
  for (const result of results) {
    const title =
      getString(getSpecific(result.output), "sessionTitle") ??
      getString(result.output, "sessionTitle");
    if (title !== undefined) {
      return title;
    }
  }
  return undefined;
};

export const shouldStop = (results: ReadonlyArray<HookResult>): boolean =>
  results.some((result) => getBoolean(result.output, "continue") === false);

export const getStopReason = (
  results: ReadonlyArray<HookResult>,
): string | undefined => {
  for (const result of results) {
    const reason = getString(result.output, "stopReason");
    if (reason !== undefined) {
      return reason;
    }
  }
  return undefined;
};

export const contentText = (content: unknown): string => {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return "";
  }
  const text: string[] = [];
  for (const block of content) {
    if (
      isRecord(block) &&
      block["type"] === "text" &&
      typeof block["text"] === "string"
    ) {
      text.push(block["text"]);
    }
  }
  return text.join("\n");
};

export const lastAssistantResult = (
  context: ExtensionContext,
): AssistantResult | undefined => {
  const entries = context.sessionManager.getBranch();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (
      !isRecord(entry) ||
      entry["type"] !== "message" ||
      !isRecord(entry["message"])
    ) {
      continue;
    }
    const message = entry["message"];
    if (
      message["role"] !== "assistant" ||
      typeof message["stopReason"] !== "string"
    ) {
      continue;
    }
    const errorMessage = message["errorMessage"];
    return typeof errorMessage === "string"
      ? {
          errorMessage,
          stopReason: message["stopReason"],
          text: contentText(message["content"]),
        }
      : {
          stopReason: message["stopReason"],
          text: contentText(message["content"]),
        };
  }
  return undefined;
};

export const commonInput = (
  eventName: HookEventName,
  context: ExtensionContext,
): Record<string, unknown> => {
  const input: Record<string, unknown> = {
    cwd: context.cwd,
    hook_event_name: eventName,
    session_id: context.sessionManager.getSessionId(),
  };
  const transcriptPath = context.sessionManager.getSessionFile();
  if (transcriptPath !== undefined) {
    input["transcript_path"] = transcriptPath;
  }
  return input;
};

export const hiddenMessage = (content: string): HookMessage => ({
  content,
  customType: "pi-hooks",
  display: false,
});
