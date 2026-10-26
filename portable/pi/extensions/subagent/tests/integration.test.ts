import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createAssistantMessageEventStream,
  type Model,
} from "@earendil-works/pi-ai";
import type { ExtensionToolContext } from "@earendil-works/pi-coding-agent";

test("a spawned plan agent uses its parent's permission channel", async (t) => {
  assert.match(
    process.env.TMPDIR ?? "",
    /^\/tmp\/codex\/dotfiles\/\d{8}-\d{6}-[a-z-]+\/?$/,
  );
  assert.ok(process.env.TMPDIR);
  const cwd = mkdtempSync(join(process.env.TMPDIR, "subagent-ipc-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const sdk = process.env.PI_TEST_SDK;
  assert.ok(sdk, "PI_TEST_SDK must point to the installed Pi SDK");
  const {
    discoverAndLoadExtensions,
    SessionManager,
    ModelRuntime,
    ModelRegistry,
  }: typeof import("@earendil-works/pi-coding-agent") = await import(sdk);
  const previous = {
    PATH: process.env.PATH,
    PI_PERMISSION_CHILD: process.env.PI_PERMISSION_CHILD,
    PI_PERMISSION_MODE: process.env.PI_PERMISSION_MODE,
    PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
    PI_PERMISSIONS_CONFIG: process.env.PI_PERMISSIONS_CONFIG,
  };
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  delete process.env.PI_PERMISSION_CHILD;
  delete process.env.PI_PERMISSION_MODE;
  process.env.PI_CODING_AGENT_DIR = cwd;
  process.env.PI_PERMISSIONS_CONFIG = join(cwd, "permissions.toml");
  process.env.PATH = `${cwd}:${process.env.PATH}`;
  mkdirSync(join(cwd, "agents"));
  mkdirSync(join(cwd, "child"));
  writeFileSync(
    join(cwd, "agents", "reader.md"),
    "---\nname: reader\ndescription: Inspect files\npermissionMode: plan\n---\nRead files only.\n",
  );
  writeFileSync(
    process.env.PI_PERMISSIONS_CONFIG,
    `
[summaries]
provider = "fixture"
model = "summary"
[policy.presets]
defaults = true
`,
  );
  const evaluator = process.env.PI_TEST_EVALUATOR;
  assert.ok(
    evaluator,
    "PI_TEST_EVALUATOR must point to the installed evaluator",
  );
  writeFileSync(
    join(cwd, "pi-permissions-evaluator"),
    `#!${process.execPath}
const { execFileSync } = require("node:child_process");
const lines = require("node:readline").createInterface({ input: process.stdin });
lines.once("line", input => {
lines.close();
const command = process.argv[2];
const output = execFileSync(${JSON.stringify(evaluator)}, [command === "check" ? "state" : command], { input, encoding: "utf8" });
if (command !== "check") process.stdout.write(output);
else {
  const request = JSON.parse(input);
  const frame = JSON.parse(output);
  frame.value.results = Object.keys(request.additionalRules ?? {}).map(id => ({ id, verdict: "compliant" }));
  frame.value.needs_summary = false;
  process.stdout.write(JSON.stringify(frame) + "\\n");
}
});
`,
    { mode: 0o700 },
  );
  const childSource = `#!${process.execPath}
import assert from 'node:assert/strict';
import { discoverAndLoadExtensions } from ${JSON.stringify(sdk)};
const entry = process.argv[process.argv.indexOf('--extension') + 1];
assert.equal(process.env.PI_PERMISSION_CHILD, '1');
assert.equal(process.env.PI_PERMISSION_MODE, 'plan');
const loaded = await discoverAndLoadExtensions([entry], process.cwd(), process.env.PI_CODING_AGENT_DIR);
assert.deepEqual(loaded.errors, []);
loaded.runtime.getActiveTools = () => ['read', 'write', 'rules_check', 'rules_request_approval'];
loaded.runtime.setActiveTools = () => {};
const extension = loaded.extensions[0];
for (const start of extension.handlers.get('session_start') ?? []) await start({}, { cwd: process.cwd() });
const handler = extension.handlers.get('tool_call')[0];
const denied = await handler({toolName:'write', input:{path:'file.txt',content:'bad'}, parentToolCallId:'codemode-child'}, {cwd:process.cwd()});
assert.equal(denied.block, true);
process.stdout.write(JSON.stringify({type:'message_end',message:{role:'assistant',content:[{type:'text',text:'Write blocked by parent in ' + process.cwd()}],stopReason:'stop'}}) + '\\n');
process.disconnect();
`;
  writeFileSync(join(cwd, "pi"), childSource, { mode: 0o700 });
  const emitter = new EventEmitter();
  const bus = {
    emit: (name: string, data: unknown) => emitter.emit(name, data),
    on: (name: string, fn: (data: unknown) => void) => {
      emitter.on(name, fn);
      return () => emitter.off(name, fn);
    },
  };
  const permissions = fileURLToPath(
    new URL("../../permissions/index.ts", import.meta.url),
  );
  const subagent = fileURLToPath(new URL("../index.ts", import.meta.url));
  const loaded = await discoverAndLoadExtensions(
    [permissions, subagent],
    cwd,
    cwd,
    bus,
  );
  assert.deepEqual(loaded.errors, []);
  t.mock.method(loaded.runtime, "appendEntry", (name: string) =>
    assert.equal(name, "tool-summaries"),
  );
  const modelRegistry = new ModelRegistry(
    await ModelRuntime.create({
      authPath: join(cwd, "auth.json"),
      modelsPath: null,
      modelsStorePath: join(cwd, "models-store.json"),
      allowModelNetwork: false,
      refreshOnCreate: false,
    }),
  );
  const model: Model<"openai-completions"> = {
    id: "summary",
    name: "Fixture summary",
    provider: "fixture",
    api: "openai-completions",
    baseUrl: "https://fixture.invalid",
    input: ["text"],
    reasoning: false,
    contextWindow: 4096,
    maxTokens: 256,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };
  t.mock.method(modelRegistry, "find", (provider: string, id: string) => {
    assert.equal(provider, "fixture");
    assert.equal(id, "summary");
    return model;
  });
  t.mock.method(modelRegistry, "streamSimple", () => {
    const stream = createAssistantMessageEventStream();
    stream.end({
      role: "assistant",
      content: [{ type: "text", text: "Inspect tool" }],
      api: model.api,
      provider: model.provider,
      model: model.id,
      stopReason: "stop",
      timestamp: Date.now(),
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
    });
    return stream;
  });
  const unexpected = (): never => assert.fail("Unexpected SDK operation");
  const ctx: ExtensionToolContext = {
    cwd,
    sessionManager: SessionManager.inMemory(cwd),
    mode: "json",
    hasUI: true,
    model: undefined,
    scopedModels: [],
    signal: undefined,
    modelRegistry,
    ui: {
      select: unexpected,
      confirm: unexpected,
      input: unexpected,
      notify: (message) => assert.fail(message),
      onTerminalInput: unexpected,
      setStatus: unexpected,
      setWorkingMessage: unexpected,
      setWorkingVisible: unexpected,
      setWorkingIndicator: unexpected,
      setHiddenThinkingLabel: unexpected,
      setWidget: unexpected,
      setFooter: unexpected,
      setHeader: unexpected,
      setTitle: unexpected,
      custom: unexpected,
      pasteToEditor: unexpected,
      setEditorText: unexpected,
      getEditorText: unexpected,
      editor: unexpected,
      addAutocompleteProvider: unexpected,
      setEditorComponent: unexpected,
      getEditorComponent: unexpected,
      get theme(): never {
        return unexpected();
      },
      getAllThemes: unexpected,
      getTheme: unexpected,
      setTheme: unexpected,
      getToolsExpanded: unexpected,
      setToolsExpanded: unexpected,
    },
    isIdle: () => true,
    isProjectTrusted: () => true,
    abort: () => assert.fail("Unexpected abort"),
    hasPendingMessages: () => false,
    shutdown: () => assert.fail("Unexpected shutdown"),
    getContextUsage: () => undefined,
    compact: () => assert.fail("Unexpected compaction"),
    getSystemPrompt: () => "",
    tools: [],
    executeTool: async () => assert.fail("Unexpected nested tool execution"),
  };
  t.mock.method(ctx.ui, "custom", async () => "Allow once");
  const permissionExtension = loaded.extensions.find(
    (extension) => extension.resolvedPath === permissions,
  );
  assert.ok(permissionExtension);
  const startHandlers = permissionExtension.handlers.get("session_start");
  assert.ok(startHandlers);
  for (const handler of startHandlers)
    await handler({ reason: "startup" }, ctx);
  for (const [name, event] of [
    ["input", { source: "interactive", text: "Inspect files" }],
    ["before_agent_start", { prompt: "Inspect files" }],
    [
      "message_start",
      {
        message: {
          role: "user",
          content: [{ type: "text", text: "Inspect files" }],
        },
      },
    ],
  ] satisfies [string, Record<string, unknown>][]) {
    for (const handler of permissionExtension.handlers.get(name) ?? [])
      await handler(event, ctx);
  }
  const params = {
    agent: "reader",
    task: "Inspect files",
    cwd: "child",
    background: false,
  };
  const callHandlers = permissionExtension.handlers.get("tool_call");
  assert.ok(callHandlers);
  for (const handler of callHandlers) {
    const result = await handler(
      { toolName: "subagent", input: params, toolCallId: "dispatch" },
      ctx,
    );
    assert.equal(result, undefined);
  }
  const tool = loaded.extensions
    .find((extension) => extension.resolvedPath === subagent)
    ?.tools.get("subagent")?.definition;
  assert.ok(tool);
  const result = await tool.execute(
    "dispatch",
    params,
    new AbortController().signal,
    undefined,
    ctx,
  );
  assert.equal(result.isError, undefined, JSON.stringify(result));
  const content = result.content[0];
  assert.ok(content?.type === "text");
  assert.match(content.text, /Write blocked by parent/);
  assert.ok(content.text.includes(join(cwd, "child")));
});
