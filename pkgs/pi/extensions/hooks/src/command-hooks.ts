import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import {
  getString,
  isRecord,
  reportError,
  type HookEventName,
  type HookResult,
} from "./hook-contract.ts";
import { appendHookCall, type HookCallEntry } from "./hook-ui.ts";

type CommandHook = {
  readonly command: string;
  readonly timeout?: number;
  readonly type: "command";
};

type HookBlock = {
  readonly hooks: ReadonlyArray<CommandHook>;
  readonly matcher: string;
};

type HookConfig = ReadonlyMap<HookEventName, ReadonlyArray<HookBlock>>;

type CommandResult = {
  readonly aborted: boolean;
  readonly code: number | null;
  readonly error?: string;
  readonly oversized: boolean;
  readonly stderr: string;
  readonly stdout: string;
  readonly timedOut: boolean;
};

const hookEventNames: ReadonlySet<string> = new Set([
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "PostToolUseFailure",
  "PostToolBatch",
  "Stop",
  "StopFailure",
  "PreCompact",
  "PostCompact",
  "SessionEnd",
  "Notification",
]);

const eventsWithoutMatchers: ReadonlySet<HookEventName> = new Set([
  "UserPromptSubmit",
  "PostToolBatch",
  "Stop",
]);

const contextualEvents: ReadonlySet<HookEventName> = new Set([
  "SessionStart",
  "UserPromptSubmit",
]);

const defaultTimeouts: Readonly<Record<HookEventName, number>> = {
  Notification: 600,
  PostCompact: 600,
  PostToolBatch: 600,
  PostToolUse: 600,
  PostToolUseFailure: 600,
  PreCompact: 600,
  PreToolUse: 600,
  SessionEnd: 1.5,
  SessionStart: 600,
  Stop: 600,
  StopFailure: 600,
  UserPromptSubmit: 30,
};

const outputLimit = 10_000;

const isHookEventName = (value: string): value is HookEventName =>
  hookEventNames.has(value);

const validateMatcher = (matcher: string): void => {
  if (
    matcher === "" ||
    matcher === "*" ||
    /^[A-Za-z0-9_\- ,|]+$/.test(matcher)
  ) {
    return;
  }
  new RegExp(matcher);
};

const parseConfig = (value: unknown): HookConfig => {
  if (!isRecord(value)) {
    throw new Error("Pi hook config must be an object.");
  }

  const config = new Map<HookEventName, ReadonlyArray<HookBlock>>();
  for (const [eventName, blocksValue] of Object.entries(value)) {
    if (!isHookEventName(eventName)) {
      throw new Error(`Unsupported Pi hook event: ${eventName}`);
    }
    if (!Array.isArray(blocksValue) || blocksValue.length === 0) {
      throw new Error(`${eventName} must contain at least one matcher block.`);
    }

    const blocks: HookBlock[] = [];
    for (const blockValue of blocksValue) {
      if (!isRecord(blockValue)) {
        throw new Error(`${eventName} matcher block must be an object.`);
      }
      const matcherValue = blockValue["matcher"];
      const matcher = matcherValue === undefined ? "" : matcherValue;
      if (typeof matcher !== "string") {
        throw new Error(`${eventName} matcher must be a string.`);
      }
      validateMatcher(matcher);
      const hooksValue = blockValue["hooks"];
      if (!Array.isArray(hooksValue) || hooksValue.length === 0) {
        throw new Error(
          `${eventName} matcher block must contain command hooks.`,
        );
      }

      const hooks: CommandHook[] = [];
      for (const hookValue of hooksValue) {
        if (!isRecord(hookValue) || hookValue["type"] !== "command") {
          throw new Error(`${eventName} only supports command hooks.`);
        }
        if (
          typeof hookValue["command"] !== "string" ||
          hookValue["command"].length === 0
        ) {
          throw new Error(`${eventName} command must be a non-empty string.`);
        }
        if (
          hookValue["timeout"] !== undefined &&
          hookValue["timeout"] !== null &&
          (typeof hookValue["timeout"] !== "number" ||
            hookValue["timeout"] <= 0)
        ) {
          throw new Error(`${eventName} timeout must be positive.`);
        }
        hooks.push(
          hookValue["timeout"] === undefined || hookValue["timeout"] === null
            ? { command: hookValue["command"], type: "command" }
            : {
                command: hookValue["command"],
                timeout: hookValue["timeout"],
                type: "command",
              },
        );
      }
      blocks.push({ hooks, matcher });
    }
    config.set(eventName, blocks);
  }
  return config;
};

const configValue: unknown = JSON.parse(
  readFileSync(new URL("./hooks.json", import.meta.url), "utf8"),
);
const config = parseConfig(configValue);

const matcherMatches = (
  eventName: HookEventName,
  matcher: string,
  value: string,
): boolean => {
  if (
    eventsWithoutMatchers.has(eventName) ||
    matcher === "" ||
    matcher === "*"
  ) {
    return true;
  }
  if (/^[A-Za-z0-9_\- ,|]+$/.test(matcher)) {
    return matcher
      .split(/[|,]/)
      .some((candidate) => candidate.trim() === value);
  }
  return new RegExp(matcher).test(value);
};

const runCommand = (
  hook: CommandHook,
  eventName: HookEventName,
  input: Readonly<Record<string, unknown>>,
  cwd: string,
  signal: AbortSignal | undefined,
): Promise<CommandResult> =>
  new Promise((resolve) => {
    const child = spawn("sh", ["-c", hook.command], {
      cwd,
      detached: true,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let aborted = false;
    let abortListener: (() => void) | undefined;
    let completed = false;
    let oversized = false;
    let stderr = "";
    let stdout = "";
    let timedOut = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;

    const finish = (result: CommandResult): void => {
      if (completed) {
        return;
      }
      completed = true;
      if (timeout !== undefined) {
        clearTimeout(timeout);
      }
      if (abortListener !== undefined) {
        signal?.removeEventListener("abort", abortListener);
      }
      resolve(result);
    };

    const finishCurrent = (code: number | null, error?: string): void => {
      finish({
        aborted,
        code,
        ...(error === undefined ? {} : { error }),
        oversized,
        stderr,
        stdout,
        timedOut,
      });
    };

    const terminate = (): void => {
      if (child.pid !== undefined) {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {
          child.kill("SIGKILL");
        }
      } else {
        child.kill("SIGKILL");
      }
      child.stdin.destroy();
      child.stdout.destroy();
      child.stderr.destroy();
    };

    const append = (target: "stderr" | "stdout", chunk: string): void => {
      if (completed) {
        return;
      }
      const current = target === "stdout" ? stdout : stderr;
      const remaining = Math.max(0, outputLimit - current.length);
      const next = current + chunk.slice(0, remaining);
      if (target === "stdout") {
        stdout = next;
      } else {
        stderr = next;
      }
      if (chunk.length > remaining) {
        oversized = true;
        terminate();
        finishCurrent(null);
      }
    };

    timeout = setTimeout(
      () => {
        timedOut = true;
        terminate();
        finishCurrent(null);
      },
      (hook.timeout ?? defaultTimeouts[eventName]) * 1_000,
    );

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      append("stdout", chunk);
    });
    child.stderr.on("data", (chunk: string) => {
      append("stderr", chunk);
    });
    child.stdin.on("error", () => undefined);
    child.once("error", (error: Error) => {
      finishCurrent(null, error.message);
    });
    child.once("close", (code: number | null) => {
      finishCurrent(code);
    });
    abortListener = (): void => {
      if (completed) {
        return;
      }
      aborted = true;
      terminate();
      finishCurrent(null);
    };
    signal?.addEventListener("abort", abortListener, { once: true });
    if (signal?.aborted) {
      abortListener();
    }
    if (!completed) {
      child.stdin.end(JSON.stringify(input));
    }
  });

const parseCommandResult = (
  eventName: HookEventName,
  result: CommandResult,
  context: ExtensionContext,
): HookResult | undefined => {
  if (result.aborted) {
    return undefined;
  }
  if (result.timedOut) {
    reportError(context, `${eventName} hook timed out.`);
    return undefined;
  }
  if (result.oversized) {
    reportError(context, `${eventName} hook output exceeded 10000 characters.`);
    return undefined;
  }
  if (result.error !== undefined) {
    reportError(context, `${eventName} hook failed: ${result.error}`);
    return undefined;
  }
  if (result.code === 2) {
    return {
      blockReason:
        result.stderr.trim() || `${eventName} hook blocked the action.`,
    };
  }
  if (result.code !== 0) {
    reportError(
      context,
      `${eventName} hook exited with code ${result.code ?? "unknown"}: ${result.stderr.trim()}`,
    );
    return undefined;
  }

  const stdout = result.stdout.trim();
  if (stdout === "") {
    return {};
  }
  try {
    const outputValue: unknown = JSON.parse(stdout);
    if (!isRecord(outputValue)) {
      reportError(context, `${eventName} hook JSON output must be an object.`);
      return undefined;
    }
    return { output: outputValue };
  } catch {
    if (contextualEvents.has(eventName) && !stdout.startsWith("{")) {
      return { plain: stdout };
    }
    reportError(context, `${eventName} hook returned invalid JSON.`);
    return undefined;
  }
};

const hookCallEntry = (
  eventName: HookEventName,
  result: CommandResult,
  parsed: HookResult | undefined,
): HookCallEntry => {
  if (result.aborted) {
    return { detail: "cancelled", eventName, status: "failed" };
  }
  if (result.timedOut) {
    return { detail: "timed out", eventName, status: "failed" };
  }
  if (result.oversized) {
    return {
      detail: "output exceeded 10000 characters",
      eventName,
      status: "failed",
    };
  }
  if (result.error !== undefined) {
    return { detail: result.error, eventName, status: "failed" };
  }
  if (result.code === 2) {
    return { eventName, status: "blocked" };
  }
  if (result.code !== 0) {
    return {
      detail: `exit ${result.code ?? "unknown"}`,
      eventName,
      status: "failed",
    };
  }
  return parsed === undefined
    ? { detail: "invalid output", eventName, status: "failed" }
    : { eventName, status: "succeeded" };
};

export const runHooks = async (
  pi: ExtensionAPI,
  eventName: HookEventName,
  matcherValue: string,
  input: Readonly<Record<string, unknown>>,
  context: ExtensionContext,
): Promise<ReadonlyArray<HookResult>> => {
  const hooks = (config.get(eventName) ?? [])
    .filter((block) => matcherMatches(eventName, block.matcher, matcherValue))
    .flatMap((block) => block.hooks);
  const commandResults = await Promise.all(
    hooks.map((hook) =>
      runCommand(hook, eventName, input, context.cwd, context.signal),
    ),
  );
  const results: HookResult[] = [];
  for (const commandResult of commandResults) {
    const result = parseCommandResult(eventName, commandResult, context);
    appendHookCall(pi, hookCallEntry(eventName, commandResult, result));
    if (result === undefined) {
      continue;
    }
    const systemMessage = getString(result.output, "systemMessage");
    if (systemMessage !== undefined) {
      context.ui.notify(systemMessage, "info");
    }
    if (result.output?.["terminalSequence"] !== undefined) {
      reportError(
        context,
        `${eventName} terminalSequence is not supported by Pi hooks.`,
      );
    }
    results.push(result);
  }
  return results;
};
