import assert from "node:assert/strict";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { pathToFileURL } from "node:url";

type HookConfig = Readonly<
  Record<
    string,
    ReadonlyArray<{
      readonly matcher?: string;
      readonly hooks: ReadonlyArray<{
        readonly type: "command";
        readonly command: string;
        readonly timeout?: number;
      }>;
    }>
  >
>;

type Message = {
  readonly content: string;
  readonly customType: string;
  readonly display: boolean;
};

type SentMessage = {
  readonly message: Message;
  readonly options?: {
    readonly deliverAs?: "steer" | "followUp" | "nextTurn";
    readonly triggerTurn?: boolean;
  };
};

type HookEntry = {
  readonly customType: string;
  readonly data?: unknown;
};

type EntryRenderer = (
  entry: HookEntry,
  options: { readonly expanded: boolean },
  theme: { readonly fg: (color: string, text: string) => string },
) => unknown;

const isStringArray = (value: unknown): value is string[] =>
  Array.isArray(value) &&
  value.every((entry: unknown) => typeof entry === "string");

const extensionSource = new URL("./", import.meta.url);
const runtimeSources = [
  "command-hooks.ts",
  "events",
  "hook-contract.ts",
  "hook-ui.ts",
  "index.ts",
  "state.ts",
] as const;
const testCwd = process.cwd();
const temporaryDirectories: string[] = [];

const shellQuote = (value: string): string =>
  `'${value.replaceAll("'", `'\\''`)}'`;

const outputCommand = (value: unknown): string =>
  `cat >/dev/null; printf %s ${shellQuote(JSON.stringify(value))}`;

const plainCommand = (value: string): string =>
  `cat >/dev/null; printf %s ${shellQuote(value)}`;

const exitTwoCommand = (message: string): string =>
  `cat >/dev/null; printf %s ${shellQuote(message)} >&2; exit 2`;

const captureCommand = (path: string, output?: unknown): string => {
  const writeInput = `cat >${shellQuote(path)}`;
  return output === undefined
    ? writeInput
    : `${writeInput}; printf %s ${shellQuote(JSON.stringify(output))}`;
};

class FakeContext {
  readonly cwd = testCwd;
  hasUI = true;
  readonly mode = "tui";
  readonly model = { id: "model-id", provider: "provider-id" };
  readonly notifications: Array<{
    readonly message: string;
    readonly type?: "info" | "warning" | "error";
  }> = [];
  readonly sessionManager = {
    getBranch: () => this.branch,
    getSessionFile: () => "/sessions/session.jsonl",
    getSessionId: () => "session-id",
    getSessionName: () => this.sessionName,
  };
  readonly ui = {
    confirm: async (): Promise<boolean> => {
      this.confirmCount += 1;
      return this.confirmResult;
    },
    notify: (message: string, type?: "info" | "warning" | "error"): void => {
      this.notifications.push(
        type === undefined ? { message } : { message, type },
      );
    },
  };
  abortCount = 0;
  branch: ReadonlyArray<unknown> = [];
  confirmCount = 0;
  confirmResult = true;
  idle = true;
  signal: AbortSignal | undefined;
  sessionName: string | undefined;
  shutdownCount = 0;

  abort(): void {
    this.abortCount += 1;
  }

  isIdle(): boolean {
    return this.idle;
  }

  shutdown(): void {
    this.shutdownCount += 1;
  }
}

class FakePi {
  readonly entries: HookEntry[] = [];
  readonly entryRenderers = new Map<string, EntryRenderer>();
  readonly eventHandlers = new Map<string, Set<(data: unknown) => void>>();
  readonly events = {
    emit: (channel: string, data: unknown): void => {
      for (const handler of this.eventHandlers.get(channel) ?? []) {
        handler(data);
      }
    },
    on: (channel: string, handler: (data: unknown) => void): (() => void) => {
      const handlers = this.eventHandlers.get(channel) ?? new Set();
      handlers.add(handler);
      this.eventHandlers.set(channel, handlers);
      return () => handlers.delete(handler);
    },
  };
  readonly handlers = new Map<string, unknown>();
  readonly sentMessages: SentMessage[] = [];
  sessionName: string | undefined;

  appendEntry(customType: string, data?: unknown): void {
    this.entries.push(
      data === undefined ? { customType } : { customType, data },
    );
  }

  on(event: string, handler: unknown): void {
    this.handlers.set(event, handler);
  }

  sendMessage(message: Message, options?: SentMessage["options"]): void {
    this.sentMessages.push(
      options === undefined ? { message } : { message, options },
    );
  }

  setSessionName(name: string): void {
    this.sessionName = name;
  }

  getSessionName(): string | undefined {
    return this.sessionName;
  }

  registerEntryRenderer(customType: string, renderer: unknown): void {
    if (typeof renderer !== "function") {
      assert.fail(`${customType} renderer is not a function`);
    }
    this.entryRenderers.set(customType, (entry, options, theme) =>
      Reflect.apply(renderer, undefined, [entry, options, theme]),
    );
  }

  renderEntry(index: number): string[] {
    const entry = this.entries[index];
    if (entry === undefined) {
      assert.fail(`missing entry ${index}`);
    }
    const renderer = this.entryRenderers.get(entry.customType);
    if (renderer === undefined) {
      assert.fail(`missing ${entry.customType} renderer`);
    }
    const component = renderer(
      entry,
      { expanded: false },
      { fg: (_color, text) => text },
    );
    if (
      typeof component !== "object" ||
      component === null ||
      !("render" in component) ||
      typeof component.render !== "function"
    ) {
      assert.fail(`${entry.customType} renderer returned no component`);
    }
    const lines: unknown = Reflect.apply(component.render, component, [80]);
    if (!isStringArray(lines)) {
      assert.fail(`${entry.customType} renderer returned invalid lines`);
    }
    return lines;
  }

  async emit(
    event: string,
    payload: unknown,
    context: FakeContext,
  ): Promise<unknown> {
    const handler = this.handlers.get(event);
    if (typeof handler !== "function") {
      assert.fail(`missing ${event} handler`);
    }
    const result: unknown = Reflect.apply(handler, undefined, [
      payload,
      context,
    ]);
    return result;
  }
}

type LoadedExtension = {
  readonly api: FakePi;
  readonly context: FakeContext;
  readonly directory: string;
};

const loadExtension = async (config: HookConfig): Promise<LoadedExtension> => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-test-"));
  temporaryDirectories.push(directory);
  const indexPath = join(directory, "index.ts");
  for (const source of runtimeSources) {
    cpSync(new URL(source, extensionSource), join(directory, source), {
      recursive: true,
    });
  }
  writeFileSync(join(directory, "hooks.json"), JSON.stringify(config));
  const moduleUrl = `${pathToFileURL(indexPath).href}?case=${crypto.randomUUID()}`;
  const extensionModule: unknown = await import(moduleUrl);
  if (
    typeof extensionModule !== "object" ||
    extensionModule === null ||
    !("default" in extensionModule)
  ) {
    assert.fail("extension has no default export");
  }
  const register = extensionModule["default"];
  if (typeof register !== "function") {
    assert.fail("extension default export is not a function");
  }
  const api = new FakePi();
  Reflect.apply(register, undefined, [api]);
  return { api, context: new FakeContext(), directory };
};

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("displays completed hooks without sending them to the model", async () => {
  const { api, context } = await loadExtension({
    UserPromptSubmit: [
      {
        hooks: [{ type: "command", command: plainCommand("") }],
      },
    ],
  });

  await api.emit(
    "input",
    { source: "interactive", text: "hello", type: "input" },
    context,
  );

  assert.deepEqual(api.entries, [
    {
      customType: "pi-hook-call",
      data: { eventName: "UserPromptSubmit", status: "succeeded" },
    },
  ]);
  assert.deepEqual(api.renderEntry(0), ["⎿ UserPromptSubmit hook succeeded"]);
  assert.deepEqual(api.sentMessages, []);
});

test("displays blocked and failed hook commands", async () => {
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          { type: "command", command: exitTwoCommand("blocked") },
          { type: "command", command: "cat >/dev/null; exit 1" },
        ],
      },
    ],
  });

  await api.emit(
    "tool_call",
    {
      input: { command: "true" },
      toolCallId: "tool-1",
      toolName: "bash",
      type: "tool_call",
    },
    context,
  );

  assert.deepEqual(api.entries, [
    {
      customType: "pi-hook-call",
      data: { eventName: "PreToolUse", status: "blocked" },
    },
    {
      customType: "pi-hook-call",
      data: {
        detail: "exit 1",
        eventName: "PreToolUse",
        status: "failed",
      },
    },
  ]);
});

test("does not display unmatched hooks", async () => {
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "edit",
        hooks: [{ type: "command", command: plainCommand("") }],
      },
    ],
  });

  await api.emit(
    "tool_call",
    {
      input: { command: "true" },
      toolCallId: "tool-1",
      toolName: "bash",
      type: "tool_call",
    },
    context,
  );

  assert.deepEqual(api.entries, []);
});

test("loads adjacent config and passes truthful SessionStart input", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-capture-"));
  temporaryDirectories.push(directory);
  const capturePath = join(directory, "input.json");
  const output = {
    hookSpecificOutput: {
      additionalContext: "session context",
      hookEventName: "SessionStart",
      sessionTitle: "resumed session",
    },
  };
  const command = `cat >${shellQuote(capturePath)}; printf %s ${shellQuote(JSON.stringify(output))}`;
  const { api, context } = await loadExtension({
    SessionStart: [
      {
        matcher: "startup",
        hooks: [{ type: "command", command: outputCommand({}) }],
      },
      { matcher: "resume", hooks: [{ type: "command", command }] },
    ],
  });

  await api.emit(
    "session_start",
    { type: "session_start", reason: "resume" },
    context,
  );

  assert.deepEqual(JSON.parse(readFileSync(capturePath, "utf8")), {
    cwd: testCwd,
    hook_event_name: "SessionStart",
    model: "provider-id/model-id",
    session_id: "session-id",
    source: "resume",
    transcript_path: "/sessions/session.jsonl",
  });
  assert.equal(api.sessionName, "resumed session");
  assert.deepEqual(api.sentMessages, [
    {
      message: {
        content: "session context",
        customType: "pi-hooks",
        display: false,
      },
      options: { deliverAs: "nextTurn" },
    },
  ]);
});

test("blocks a submitted prompt and does not expose its text in the notification", async () => {
  const { api, context } = await loadExtension({
    UserPromptSubmit: [
      {
        hooks: [
          {
            type: "command",
            command: outputCommand({
              decision: "block",
              reason: "prompt rejected",
              suppressOriginalPrompt: true,
            }),
          },
        ],
      },
    ],
  });

  const result = await api.emit(
    "input",
    { source: "interactive", text: "secret prompt", type: "input" },
    context,
  );

  assert.deepEqual(result, { action: "handled" });
  assert.deepEqual(context.notifications, [
    { message: "prompt rejected", type: "warning" },
  ]);
  assert.doesNotMatch(context.notifications[0]?.message ?? "", /secret prompt/);
});

test("injects prompt context before the agent starts", async () => {
  const { api, context } = await loadExtension({
    UserPromptSubmit: [
      {
        hooks: [
          { type: "command", command: plainCommand("plain context") },
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                additionalContext: "structured context",
                hookEventName: "UserPromptSubmit",
                sessionTitle: "prompt title",
              },
            }),
          },
        ],
      },
    ],
  });

  const inputResult = await api.emit(
    "input",
    { source: "interactive", text: "hello", type: "input" },
    context,
  );
  const startResult = await api.emit(
    "before_agent_start",
    { prompt: "hello", type: "before_agent_start" },
    context,
  );

  assert.deepEqual(inputResult, { action: "continue" });
  assert.equal(api.sessionName, "prompt title");
  assert.deepEqual(startResult, {
    message: {
      content: "plain context\nstructured context",
      customType: "pi-hooks",
      display: false,
    },
  });
});

test("delivers prompt context with streaming prompts instead of the next idle prompt", async () => {
  const { api, context } = await loadExtension({
    UserPromptSubmit: [
      {
        hooks: [{ type: "command", command: plainCommand("stream context") }],
      },
    ],
  });
  context.idle = false;

  assert.deepEqual(
    await api.emit(
      "input",
      {
        source: "interactive",
        streamingBehavior: "steer",
        text: "interrupt",
        type: "input",
      },
      context,
    ),
    { action: "continue" },
  );
  assert.equal(
    await api.emit(
      "before_agent_start",
      { prompt: "later", type: "before_agent_start" },
      context,
    ),
    undefined,
  );

  await api.emit(
    "input",
    {
      source: "interactive",
      streamingBehavior: "followUp",
      text: "queue",
      type: "input",
    },
    context,
  );
  await api.emit(
    "input",
    {
      source: "interactive",
      text: "queue without an explicit mode",
      type: "input",
    },
    context,
  );

  assert.deepEqual(
    api.sentMessages.map(({ message, options }) => ({
      content: message.content,
      deliverAs: options?.deliverAs,
    })),
    [
      { content: "stream context", deliverAs: "steer" },
      { content: "stream context", deliverAs: "followUp" },
      { content: "stream context", deliverAs: "followUp" },
    ],
  );
});

test("applies PreToolUse precedence, input replacement, and confirmation", async () => {
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash|read",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                additionalContext: "tool context",
                hookEventName: "PreToolUse",
                permissionDecision: "allow",
                updatedInput: { command: "printf safe" },
              },
            }),
          },
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "ask",
                permissionDecisionReason: "confirm changed command",
              },
            }),
          },
        ],
      },
    ],
  });
  const event = {
    input: { command: "printf unsafe", timeout: 30 },
    toolCallId: "tool-1",
    toolName: "bash",
    type: "tool_call",
  };

  const result = await api.emit("tool_call", event, context);

  assert.equal(result, undefined);
  assert.deepEqual(event.input, { command: "printf safe" });
  assert.equal(context.confirmCount, 1);
  assert.deepEqual(api.sentMessages, [
    {
      message: {
        content: "tool context",
        customType: "pi-hooks",
        display: false,
      },
      options: { deliverAs: "steer" },
    },
  ]);
});

test("blocks rejected or unavailable PreToolUse approval without terminating", async () => {
  const loaded = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "ask",
                permissionDecisionReason: "confirm this command",
              },
            }),
          },
        ],
      },
    ],
  });
  const event = {
    input: { command: "true" },
    toolCallId: "tool-1",
    toolName: "bash",
    type: "tool_call",
  };
  loaded.context.confirmResult = false;

  assert.deepEqual(await loaded.api.emit("tool_call", event, loaded.context), {
    block: true,
    reason: "confirm this command",
  });
  assert.equal(loaded.context.confirmCount, 1);

  loaded.context.hasUI = false;
  assert.deepEqual(await loaded.api.emit("tool_call", event, loaded.context), {
    block: true,
    reason: "confirm this command",
  });
  assert.equal(loaded.context.confirmCount, 1);
});

test("blocks ordinary PreToolUse denials and terminates only explicit stops", async () => {
  const deferred = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "defer",
              },
            }),
          },
        ],
      },
    ],
  });
  const exited = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          { type: "command", command: exitTwoCommand("blocked by command") },
        ],
      },
    ],
  });
  const stopped = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              continue: false,
              stopReason: "stop the agent",
            }),
          },
        ],
      },
    ],
  });
  const event = {
    input: { command: "true" },
    toolCallId: "tool-1",
    toolName: "bash",
    type: "tool_call",
  };

  assert.deepEqual(
    await deferred.api.emit("tool_call", event, deferred.context),
    {
      block: true,
      reason: "Pi cannot defer tool calls from an extension hook.",
    },
  );
  assert.deepEqual(await exited.api.emit("tool_call", event, exited.context), {
    block: true,
    reason: "blocked by command",
  });
  assert.deepEqual(
    await stopped.api.emit("tool_call", event, stopped.context),
    {
      block: true,
      reason: "stop the agent",
      terminate: true,
    },
  );
});

test("blocks invalid PreToolUse input updates without terminating", async () => {
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                updatedInput: "invalid",
              },
            }),
          },
        ],
      },
    ],
  });

  assert.deepEqual(
    await api.emit(
      "tool_call",
      {
        input: { command: "true" },
        toolCallId: "tool-1",
        toolName: "bash",
        type: "tool_call",
      },
      context,
    ),
    {
      block: true,
      reason: "PreToolUse updatedInput must be an object.",
    },
  );
  assert.deepEqual(context.notifications, [
    {
      message: "PreToolUse updatedInput must be an object.",
      type: "error",
    },
  ]);
});

test("patches successful tool output and gives failed tools corrective context", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-tools-"));
  temporaryDirectories.push(directory);
  const successInput = join(directory, "success.json");
  const failureInput = join(directory, "failure.json");
  const { api, context } = await loadExtension({
    PostToolUse: [
      {
        matcher: "^bash$",
        hooks: [
          {
            type: "command",
            command: captureCommand(successInput, {
              decision: "block",
              reason: "review the redaction",
              hookSpecificOutput: {
                additionalContext: "successful tool context",
                hookEventName: "PostToolUse",
                updatedToolOutput: {
                  content: [{ text: "redacted", type: "text" }],
                  details: { redacted: true },
                  isError: false,
                },
              },
            }),
          },
        ],
      },
    ],
    PostToolUseFailure: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: captureCommand(failureInput, {
              hookSpecificOutput: {
                additionalContext: "retry with a smaller command",
                hookEventName: "PostToolUseFailure",
              },
            }),
          },
        ],
      },
    ],
  });

  const successful = await api.emit(
    "tool_result",
    {
      content: [{ text: "original", type: "text" }],
      details: { exitCode: 0 },
      input: { command: "printf original" },
      isError: false,
      toolCallId: "tool-success",
      toolName: "bash",
      type: "tool_result",
    },
    context,
  );
  const failed = await api.emit(
    "tool_result",
    {
      content: [{ text: "Exit code 1", type: "text" }],
      details: { exitCode: 1 },
      input: { command: "false" },
      isError: true,
      toolCallId: "tool-failure",
      toolName: "bash",
      type: "tool_result",
    },
    context,
  );

  assert.deepEqual(successful, {
    content: [{ text: "redacted", type: "text" }],
    details: { redacted: true },
    isError: false,
  });
  assert.equal(failed, undefined);
  assert.deepEqual(JSON.parse(readFileSync(successInput, "utf8")), {
    cwd: testCwd,
    hook_event_name: "PostToolUse",
    session_id: "session-id",
    tool_input: { command: "printf original" },
    tool_name: "bash",
    tool_response: {
      content: [{ text: "original", type: "text" }],
      details: { exitCode: 0 },
      isError: false,
    },
    tool_use_id: "tool-success",
    transcript_path: "/sessions/session.jsonl",
  });
  assert.match(readFileSync(failureInput, "utf8"), /"error":"Exit code 1"/);
  assert.deepEqual(
    api.sentMessages.map(({ message }) => message.content),
    [
      "successful tool context",
      "review the redaction",
      "retry with a smaller command",
    ],
  );
});

test("sends PostToolUseFailure exit-code-2 feedback to the model", async () => {
  const { api, context } = await loadExtension({
    PostToolUseFailure: [
      {
        matcher: "bash",
        hooks: [{ type: "command", command: exitTwoCommand("retry safely") }],
      },
    ],
  });

  await api.emit(
    "tool_result",
    {
      content: [{ text: "Exit code 1", type: "text" }],
      details: { exitCode: 1 },
      input: { command: "false" },
      isError: true,
      toolCallId: "tool-failure",
      toolName: "bash",
      type: "tool_result",
    },
    context,
  );

  assert.deepEqual(api.sentMessages, [
    {
      message: {
        content: "retry safely",
        customType: "pi-hooks",
        display: false,
      },
      options: { deliverAs: "steer" },
    },
  ]);
});

test("fails closed on multiple tool input updates and preserves output on patch conflicts", async () => {
  const { api, context } = await loadExtension({
    PostToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PostToolUse",
                updatedToolOutput: { content: [{ text: "one", type: "text" }] },
              },
            }),
          },
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PostToolUse",
                updatedToolOutput: { content: [{ text: "two", type: "text" }] },
              },
            }),
          },
        ],
      },
    ],
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                updatedInput: { command: "one" },
              },
            }),
          },
          {
            type: "command",
            command: outputCommand({
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                updatedInput: { command: "two" },
              },
            }),
          },
        ],
      },
    ],
  });
  const input = { command: "original" };

  assert.deepEqual(
    await api.emit(
      "tool_call",
      { input, toolCallId: "tool-1", toolName: "bash", type: "tool_call" },
      context,
    ),
    {
      block: true,
      reason: "Multiple PreToolUse hooks returned updatedInput.",
    },
  );
  assert.deepEqual(input, { command: "original" });
  assert.equal(
    await api.emit(
      "tool_result",
      {
        content: [{ text: "original", type: "text" }],
        details: undefined,
        input,
        isError: false,
        toolCallId: "tool-1",
        toolName: "bash",
        type: "tool_result",
      },
      context,
    ),
    undefined,
  );
  assert.deepEqual(
    context.notifications.map(({ message }) => message),
    [
      "Multiple PreToolUse hooks returned updatedInput.",
      "Multiple PostToolUse hooks returned updatedToolOutput.",
    ],
  );
});

test("emits one ordered PostToolBatch and aborts before the next model call", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-batch-"));
  temporaryDirectories.push(directory);
  const capturePath = join(directory, "batch.json");
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [{ type: "command", command: exitTwoCommand("blocked") }],
      },
    ],
    PostToolBatch: [
      {
        matcher: "ignored",
        hooks: [
          {
            type: "command",
            command: captureCommand(capturePath, {
              decision: "block",
              reason: "stop after batch",
            }),
          },
        ],
      },
    ],
  });
  await api.emit(
    "tool_call",
    {
      input: { command: "false" },
      toolCallId: "blocked-tool",
      toolName: "bash",
      type: "tool_call",
    },
    context,
  );
  await api.emit(
    "tool_result",
    {
      content: [{ text: "first result", type: "text" }],
      details: undefined,
      input: { path: "first" },
      isError: false,
      toolCallId: "tool-1",
      toolName: "read",
      type: "tool_result",
    },
    context,
  );
  await api.emit(
    "tool_result",
    {
      content: [{ text: "second result", type: "text" }],
      details: undefined,
      input: { path: "second" },
      isError: false,
      toolCallId: "tool-2",
      toolName: "read",
      type: "tool_result",
    },
    context,
  );

  await api.emit(
    "turn_end",
    {
      message: { role: "assistant" },
      toolResults: [
        {
          content: [{ text: "first result", type: "text" }],
          isError: false,
          toolCallId: "tool-1",
          toolName: "read",
        },
        {
          content: [{ text: "second result", type: "text" }],
          isError: false,
          toolCallId: "tool-2",
          toolName: "read",
        },
      ],
      turnIndex: 1,
      type: "turn_end",
    },
    context,
  );

  const input = JSON.parse(readFileSync(capturePath, "utf8"));
  assert.deepEqual(
    input.tool_calls.map(
      (call: Record<string, unknown>) => call["tool_use_id"],
    ),
    ["tool-1", "tool-2"],
  );
  assert.equal(context.abortCount, 1);
  assert.equal(api.sentMessages.at(-1)?.message.content, "stop after batch");
});

test("maps compaction events and emits compact SessionStart after PostCompact", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-compact-"));
  temporaryDirectories.push(directory);
  const postPath = join(directory, "post.json");
  const startPath = join(directory, "start.json");
  const blocking = await loadExtension({
    PreCompact: [
      {
        matcher: "auto",
        hooks: [
          {
            type: "command",
            command: outputCommand({
              decision: "block",
              reason: "keep context",
            }),
          },
        ],
      },
    ],
  });
  const lifecycle = await loadExtension({
    PostCompact: [
      {
        matcher: "manual",
        hooks: [{ type: "command", command: captureCommand(postPath) }],
      },
    ],
    SessionStart: [
      {
        matcher: "compact",
        hooks: [{ type: "command", command: captureCommand(startPath) }],
      },
    ],
  });

  assert.deepEqual(
    await blocking.api.emit(
      "session_before_compact",
      {
        customInstructions: "focus on tests",
        reason: "overflow",
        type: "session_before_compact",
        willRetry: true,
      },
      blocking.context,
    ),
    { cancel: true },
  );
  await lifecycle.api.emit(
    "session_compact",
    {
      compactionEntry: { summary: "compact summary" },
      reason: "manual",
      type: "session_compact",
      willRetry: false,
    },
    lifecycle.context,
  );

  assert.match(
    readFileSync(postPath, "utf8"),
    /"compact_summary":"compact summary"/,
  );
  assert.match(readFileSync(startPath, "utf8"), /"source":"compact"/);
});

test("shows lifecycle exit-code-2 messages to the user", async () => {
  const { api, context } = await loadExtension({
    PostCompact: [
      {
        matcher: "manual",
        hooks: [
          { type: "command", command: exitTwoCommand("compact warning") },
        ],
      },
    ],
    SessionEnd: [
      {
        matcher: "prompt_input_exit",
        hooks: [{ type: "command", command: exitTwoCommand("end warning") }],
      },
    ],
    SessionStart: [
      {
        matcher: "startup",
        hooks: [{ type: "command", command: exitTwoCommand("start warning") }],
      },
    ],
  });

  await api.emit(
    "session_start",
    { reason: "startup", type: "session_start" },
    context,
  );
  await api.emit(
    "session_compact",
    {
      compactionEntry: { summary: "summary" },
      reason: "manual",
      type: "session_compact",
      willRetry: false,
    },
    context,
  );
  await api.emit(
    "session_shutdown",
    { reason: "quit", type: "session_shutdown" },
    context,
  );

  assert.deepEqual(context.notifications, [
    { message: "start warning", type: "warning" },
    { message: "compact warning", type: "warning" },
    { message: "end warning", type: "warning" },
  ]);
});

test("separates Stop, StopFailure, and aborted runs with an eight-continuation cap", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-stop-"));
  temporaryDirectories.push(directory);
  const failurePath = join(directory, "failure.json");
  const { api, context } = await loadExtension({
    Stop: [
      {
        hooks: [
          {
            type: "command",
            command: outputCommand({
              decision: "block",
              reason: "continue work",
            }),
          },
        ],
      },
    ],
    StopFailure: [
      {
        matcher: "unknown",
        hooks: [{ type: "command", command: captureCommand(failurePath) }],
      },
    ],
  });
  context.branch = [
    {
      message: {
        content: [{ text: "done", type: "text" }],
        role: "assistant",
        stopReason: "stop",
      },
      type: "message",
    },
  ];

  for (let attempt = 0; attempt < 9; attempt += 1) {
    await api.emit("agent_settled", { type: "agent_settled" }, context);
  }
  assert.equal(api.sentMessages.length, 8);
  assert.deepEqual(api.sentMessages[0]?.options, {
    deliverAs: "followUp",
    triggerTurn: true,
  });

  context.branch = [
    {
      message: {
        content: [{ text: "partial", type: "text" }],
        errorMessage: "provider failed",
        role: "assistant",
        stopReason: "error",
      },
      type: "message",
    },
  ];
  await api.emit("agent_settled", { type: "agent_settled" }, context);
  assert.match(
    readFileSync(failurePath, "utf8"),
    /"error_details":"provider failed"/,
  );

  rmSync(failurePath);
  context.branch = [
    {
      message: {
        content: [],
        role: "assistant",
        stopReason: "aborted",
      },
      type: "message",
    },
  ];
  await api.emit("agent_settled", { type: "agent_settled" }, context);
  assert.equal(existsSync(failurePath), false);
});

test("classifies StopFailure errors and passes the rendered error message", async () => {
  const cases = [
    ["rate_limit", "Request failed with status 429: rate limit exceeded"],
    ["overloaded", "Provider overloaded (529)"],
    ["authentication_failed", "Unauthorized: invalid API key (401)"],
    ["oauth_org_not_allowed", "oauth_org_not_allowed"],
    ["billing_error", "Payment required: credit balance exhausted (402)"],
    ["invalid_request", "invalid_request"],
    ["model_not_found", "Model not found"],
    ["server_error", "server_error"],
    ["max_output_tokens", "Maximum output token limit reached"],
    ["unknown", "Provider failed unexpectedly"],
  ] as const;

  for (const [kind, message] of cases) {
    const directory = mkdtempSync(join(tmpdir(), "pi-hooks-failure-kind-"));
    temporaryDirectories.push(directory);
    const capturePath = join(directory, "failure.json");
    const { api, context } = await loadExtension({
      StopFailure: [
        {
          matcher: kind,
          hooks: [{ type: "command", command: captureCommand(capturePath) }],
        },
      ],
    });
    context.branch = [
      {
        message: {
          content: [{ text: "partial response", type: "text" }],
          errorMessage: message,
          role: "assistant",
          stopReason: "error",
        },
        type: "message",
      },
    ];

    await api.emit("agent_settled", { type: "agent_settled" }, context);

    const input = JSON.parse(readFileSync(capturePath, "utf8"));
    assert.equal(input.error, kind);
    assert.equal(input.error_details, message);
    assert.equal(input.last_assistant_message, message);
  }
});

test("maps SessionEnd reasons and skips extension reload", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-end-"));
  temporaryDirectories.push(directory);
  const capturePath = join(directory, "end.json");
  const { api, context } = await loadExtension({
    SessionEnd: [
      {
        matcher: "prompt_input_exit",
        hooks: [{ type: "command", command: captureCommand(capturePath) }],
      },
    ],
  });

  await api.emit(
    "session_shutdown",
    { reason: "reload", type: "session_shutdown" },
    context,
  );
  assert.equal(existsSync(capturePath), false);
  await api.emit(
    "session_shutdown",
    { reason: "quit", type: "session_shutdown" },
    context,
  );
  assert.match(
    readFileSync(capturePath, "utf8"),
    /"reason":"prompt_input_exit"/,
  );
});

test("fires idle_prompt after 60 seconds and cancels it on user input", async (testContext) => {
  testContext.mock.timers.enable({ apis: ["setTimeout"] });
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-idle-"));
  temporaryDirectories.push(directory);
  const capturePath = join(directory, "idle.json");
  const { api, context } = await loadExtension({
    Notification: [
      {
        matcher: "idle_prompt",
        hooks: [{ type: "command", command: captureCommand(capturePath) }],
      },
    ],
  });
  context.branch = [
    {
      message: {
        content: [{ text: "done", type: "text" }],
        role: "assistant",
        stopReason: "stop",
      },
      type: "message",
    },
  ];

  await api.emit("agent_settled", { type: "agent_settled" }, context);
  testContext.mock.timers.tick(60_000);
  await new Promise<void>((resolve, reject) => {
    let attempts = 0;
    const interval = setInterval(() => {
      attempts += 1;
      if (
        existsSync(capturePath) &&
        readFileSync(capturePath, "utf8").length > 0
      ) {
        clearInterval(interval);
        resolve();
      } else if (attempts === 1_000) {
        clearInterval(interval);
        reject(new Error("idle notification hook did not run"));
      }
    }, 1);
  });
  assert.match(
    readFileSync(capturePath, "utf8"),
    /"notification_type":"idle_prompt"/,
  );

  rmSync(capturePath);
  await api.emit("agent_settled", { type: "agent_settled" }, context);
  await api.emit(
    "input",
    { source: "interactive", text: "next prompt", type: "input" },
    context,
  );
  testContext.mock.timers.tick(60_000);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(existsSync(capturePath), false);
});

test("fires permission_prompt when the permission UI opens", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-permission-"));
  temporaryDirectories.push(directory);
  const capturePath = join(directory, "permission.json");
  const { api, context } = await loadExtension({
    Notification: [
      {
        matcher: "permission_prompt",
        hooks: [{ type: "command", command: captureCommand(capturePath) }],
      },
    ],
  });

  await api.emit(
    "session_start",
    { reason: "startup", type: "session_start" },
    context,
  );
  api.events.emit("permissions:ui_prompt", {
    message: "Allow docs:read?",
    surface: "mcp",
    value: "docs:read",
  });
  await new Promise<void>((resolve, reject) => {
    let attempts = 0;
    const interval = setInterval(() => {
      attempts += 1;
      if (
        existsSync(capturePath) &&
        readFileSync(capturePath, "utf8").length > 0
      ) {
        clearInterval(interval);
        resolve();
      } else if (attempts === 1_000) {
        clearInterval(interval);
        reject(new Error("permission notification hook did not run"));
      }
    }, 1);
  });

  assert.match(
    readFileSync(capturePath, "utf8"),
    /"notification_type":"permission_prompt"/,
  );
});

test("reports timeout, malformed JSON, and oversized output without blocking", async () => {
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: "cat >/dev/null; sleep 1",
            timeout: 0.01,
          },
          { type: "command", command: plainCommand("not json") },
          {
            type: "command",
            command:
              "cat >/dev/null; node -e \"process.stdout.write('x'.repeat(10001))\"",
          },
        ],
      },
    ],
  });

  assert.equal(
    await api.emit(
      "tool_call",
      {
        input: { command: "true" },
        toolCallId: "tool-1",
        toolName: "bash",
        type: "tool_call",
      },
      context,
    ),
    undefined,
  );
  assert.deepEqual(
    context.notifications.map(({ message }) => message),
    [
      "PreToolUse hook timed out.",
      "PreToolUse hook returned invalid JSON.",
      "PreToolUse hook output exceeded 10000 characters.",
    ],
  );
  assert.deepEqual(api.entries, [
    {
      customType: "pi-hook-call",
      data: {
        detail: "timed out",
        eventName: "PreToolUse",
        status: "failed",
      },
    },
    {
      customType: "pi-hook-call",
      data: {
        detail: "invalid output",
        eventName: "PreToolUse",
        status: "failed",
      },
    },
    {
      customType: "pi-hook-call",
      data: {
        detail: "output exceeded 10000 characters",
        eventName: "PreToolUse",
        status: "failed",
      },
    },
  ]);
  assert.deepEqual(api.renderEntry(0), ["⎿ PreToolUse hook failed: timed out"]);
});

test("does not treat malformed structured context as plain text", async () => {
  const { api, context } = await loadExtension({
    UserPromptSubmit: [
      {
        hooks: [{ type: "command", command: plainCommand("{invalid") }],
      },
    ],
  });

  await api.emit(
    "input",
    { source: "interactive", text: "hello", type: "input" },
    context,
  );

  assert.equal(
    await api.emit(
      "before_agent_start",
      { prompt: "hello", type: "before_agent_start" },
      context,
    ),
    undefined,
  );
  assert.deepEqual(context.notifications, [
    {
      message: "UserPromptSubmit hook returned invalid JSON.",
      type: "error",
    },
  ]);
});

test("returns promptly when a timed-out shell has a background descendant", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-descendant-"));
  temporaryDirectories.push(directory);
  const pidPath = join(directory, "pid");
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: `sleep 2 & printf %s "$!" >${shellQuote(pidPath)}; wait`,
            timeout: 0.01,
          },
        ],
      },
    ],
  });
  const startedAt = Date.now();

  await api.emit(
    "tool_call",
    {
      input: { command: "true" },
      toolCallId: "tool-1",
      toolName: "bash",
      type: "tool_call",
    },
    context,
  );

  assert.ok(Date.now() - startedAt < 500);
  const descendantPid = Number(readFileSync(pidPath, "utf8"));
  await new Promise<void>((resolve, reject) => {
    let attempts = 0;
    const interval = setInterval(() => {
      attempts += 1;
      try {
        process.kill(descendantPid, 0);
        if (attempts === 100) {
          clearInterval(interval);
          reject(new Error("timed-out hook descendant is still running"));
        }
      } catch {
        clearInterval(interval);
        resolve();
      }
    }, 1);
  });
  assert.deepEqual(context.notifications, [
    { message: "PreToolUse hook timed out.", type: "error" },
  ]);
});

test("aborts a hook process group and reports it as cancelled", async () => {
  const directory = mkdtempSync(join(tmpdir(), "pi-hooks-abort-"));
  temporaryDirectories.push(directory);
  const pidPath = join(directory, "pid");
  const controller = new AbortController();
  const { api, context } = await loadExtension({
    PreToolUse: [
      {
        matcher: "bash",
        hooks: [
          {
            type: "command",
            command: `sleep 2 & printf %s "$!" >${shellQuote(pidPath)}; wait`,
            timeout: 2,
          },
        ],
      },
    ],
  });
  context.signal = controller.signal;
  const result = api.emit(
    "tool_call",
    {
      input: { command: "true" },
      toolCallId: "tool-1",
      toolName: "bash",
      type: "tool_call",
    },
    context,
  );
  await new Promise<void>((resolve, reject) => {
    let attempts = 0;
    const interval = setInterval(() => {
      attempts += 1;
      if (existsSync(pidPath) && readFileSync(pidPath, "utf8").length > 0) {
        clearInterval(interval);
        resolve();
      } else if (attempts === 1_000) {
        clearInterval(interval);
        reject(new Error("hook descendant did not start"));
      }
    }, 1);
  });
  const abortedAt = Date.now();

  controller.abort();
  assert.equal(await result, undefined);
  assert.ok(Date.now() - abortedAt < 500);

  const descendantPid = Number(readFileSync(pidPath, "utf8"));
  await new Promise<void>((resolve, reject) => {
    let attempts = 0;
    const interval = setInterval(() => {
      attempts += 1;
      try {
        process.kill(descendantPid, 0);
        if (attempts === 100) {
          clearInterval(interval);
          reject(new Error("aborted hook descendant is still running"));
        }
      } catch {
        clearInterval(interval);
        resolve();
      }
    }, 1);
  });
  assert.deepEqual(context.notifications, []);
  assert.deepEqual(api.entries, [
    {
      customType: "pi-hook-call",
      data: {
        detail: "cancelled",
        eventName: "PreToolUse",
        status: "failed",
      },
    },
  ]);
  assert.deepEqual(api.renderEntry(0), ["⎿ PreToolUse hook failed: cancelled"]);
});
