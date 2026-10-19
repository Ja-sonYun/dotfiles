import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("Pi loads the real extension and routes parent and child calls through it", async (t) => {
  const { discoverAndLoadExtensions, createGrepTool } = await import(
    process.env.PI_TEST_SDK || "@earendil-works/pi-coding-agent"
  );
  assert.match(
    process.env.TMPDIR ?? "",
    /^\/tmp\/codex\/dotfiles\/\d{8}-\d{6}-[a-z-]+\/?$/,
  );
  const cwd = mkdtempSync(join(process.env.TMPDIR, "permissions-sdk-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const configPath = join(cwd, "permissions.json");
  const evaluationsPath = join(cwd, "evaluations.jsonl");
  const previous = process.env.PI_PERMISSIONS_CONFIG;
  process.env.PI_PERMISSIONS_CONFIG = configPath;
  t.after(() => {
    if (previous === undefined) delete process.env.PI_PERMISSIONS_CONFIG;
    else process.env.PI_PERMISSIONS_CONFIG = previous;
  });
  const config = {
    policy: {
      commands: { rules: [{ prefix: ["printf"], decision: "allow" }] },
      files: { rules: [] },
      mcp: {},
      mcp_readonly_tools: {},
      defaultRead: true,
    },
    parser: process.env.PI_TEST_SHFMT || "shfmt",
    search: process.env.PI_TEST_RG || "rg",
    evaluator: [
      process.execPath,
      "-e",
      `require('node:readline').createInterface({input:process.stdin}).once('line', data => { require('node:fs').appendFileSync(${JSON.stringify(evaluationsPath)}, data+'\\n'); const request=JSON.parse(data); process.stdout.write(JSON.stringify({type:'done',value:{fingerprint:'fixture',results:Object.keys(request.additionalRules).map(id => ({id,verdict:'compliant'})),errors:[]}})+'\\n'); })`,
    ],
  };
  writeFileSync(configPath, JSON.stringify(config));
  const emitter = new EventEmitter();
  const bus = {
    emit: (name, data) => emitter.emit(name, data),
    on: (name, fn) => {
      emitter.on(name, fn);
      return () => emitter.off(name, fn);
    },
  };
  const source = fileURLToPath(new URL("../index.ts", import.meta.url));
  const loaded = await discoverAndLoadExtensions([source], cwd, cwd, bus);
  assert.deepEqual(loaded.errors, []);
  const extension = loaded.extensions[0];
  assert.equal(extension.tools.has("codemode"), false);
  const choices = [];
  let pendingMessages = false;
  let selection = "Allow once";
  const ctx = {
    cwd,
    sessionManager: { getEntries: () => [], getBranch: () => [] },
    hasUI: true,
    hasPendingMessages: () => pendingMessages,
    ui: {
      custom: async () => {
        choices.push("permission");
        return selection;
      },
    },
  };
  const emit = async (name, event) => {
    let result;
    for (const handler of extension.handlers.get(name) ?? [])
      result = await handler(event, ctx);
    return result;
  };
  await emit("session_start", { reason: "startup" });
  await emit("input", { source: "interactive", text: "Inspect this project" });
  await emit("before_agent_start", { prompt: "Inspect this project" });
  const consume = async (text) =>
    emit("message_start", {
      message: { role: "user", content: [{ type: "text", text }] },
    });
  await consume("Inspect this project");
  const allowed = await emit("tool_call", {
    toolName: "read",
    input: { path: "file.txt" },
    toolCallId: "read-1",
    parentToolCallId: "codemode-1",
  });
  assert.equal(allowed, undefined);
  const lastEvaluation = () =>
    JSON.parse(readFileSync(evaluationsPath, "utf8").trim().split("\n").at(-1));
  await t.test(
    "Pi supplies its permission policy through the shared request envelope",
    () => {
      const evaluation = lastEvaluation();
      assert.equal(evaluation.client, "pi");
      assert.equal(evaluation.cwd, realpathSync(cwd));
      assert.equal(evaluation.tool_name, "read");
      assert.equal(evaluation.context.actor, "main");
      assert.equal(evaluation.context.permission_mode, "default");
      assert.deepEqual(JSON.parse(evaluation.context.user_request), [
        "Inspect this project",
      ]);
      assert.equal(
        evaluation.additionalRules.permission_request_scope.target,
        "tool",
      );
      assert.match(
        evaluation.additionalRules.permission_request_scope.check.intent,
        /never human authorization/,
      );
      assert.equal(evaluation.user_request, undefined);
    },
  );
  await emit("tool_call", {
    toolName: "subagent",
    input: { agent: "researcher", task: "Inspect files" },
    toolCallId: "dispatch",
  });
  let child;
  bus.emit("permissions:child", {
    dispatchId: "dispatch",
    name: "researcher",
    mode: "plan",
    cwd,
    task: "Inspect files",
    reply: (bridge) => {
      child = bridge;
    },
  });
  assert.equal(child.mode, "plan");
  assert.equal(child.extension, source);
  await t.test(
    "child rule checks preserve parent-owned identity and dispatch approval",
    async () => {
      assert.equal(
        await child.check(
          { toolName: "read", input: { path: "file.txt" } },
          new AbortController().signal,
        ),
        undefined,
      );
      const evaluation = lastEvaluation();
      assert.equal(evaluation.context.actor, "researcher");
      assert.equal(evaluation.context.permission_mode, "plan");
      assert.equal(evaluation.context.delegated_task, "Inspect files");
      assert.equal(evaluation.context.approvals.length, 1);
      assert.equal(evaluation.context.approvals[0].call.toolName, "subagent");
      assert.equal(evaluation.context.approvals[0].actor.name, "main");
    },
  );
  const blocked = await child.check(
    {
      toolName: "write",
      input: { path: "file.txt", content: "bad" },
      parentToolCallId: "codemode-child",
    },
    new AbortController().signal,
  );
  assert.equal(blocked.block, true);
  assert.equal(choices.length, 1);
  const unknown = await emit("tool_call", {
    toolName: "unknown_tool",
    input: {},
    toolCallId: "ask-1",
  });
  assert.equal(unknown, undefined);
  assert.equal(choices.length, 2);
  ctx.hasUI = false;
  assert.equal(
    (
      await emit("tool_call", {
        toolName: "unknown_tool",
        input: {},
        toolCallId: "ask-2",
      })
    ).block,
    true,
  );
  await emit("input", {
    source: "interactive",
    text: "Stop that task",
    streamingBehavior: "steer",
  });
  await consume("Stop that task");
  assert.equal(
    (
      await child.check(
        { toolName: "read", input: {} },
        new AbortController().signal,
      )
    ).block,
    true,
  );

  ctx.hasUI = true;
  const lastRequest = () => JSON.parse(lastEvaluation().context.user_request);
  const unknownCall = () =>
    emit("tool_call", {
      toolName: "unknown_tool",
      input: {},
      toolCallId: "session-check",
    });
  await t.test(
    "followUp is consumed without before_agent_start and revokes grants",
    async () => {
      selection = "Allow this exact scope for this session";
      await unknownCall();
      const before = choices.length;
      await emit("input", {
        source: "interactive",
        text: "Do not modify files",
        streamingBehavior: "followUp",
      });
      pendingMessages = true;
      await unknownCall();
      assert.equal(choices.length, before);
      assert.ok(!lastRequest().includes("Do not modify files"));
      pendingMessages = false;
      await consume("Do not modify files");
      await unknownCall();
      assert.equal(choices.length, before + 1);
      assert.equal(lastRequest().at(-1), "Do not modify files");
    },
  );
  await t.test(
    "cancelled followUps do not displace the next independent input",
    async () => {
      await emit("input", {
        source: "interactive",
        text: "Cancelled request",
        streamingBehavior: "followUp",
      });
      pendingMessages = false;
      await emit("input", { source: "rpc", text: "Current request" });
      await emit("before_agent_start", { prompt: "Current request" });
      await consume("Current request");
      await unknownCall();
      assert.equal(lastRequest().at(-1), "Current request");
      assert.ok(!lastRequest().includes("Cancelled request"));
    },
  );
  await t.test(
    "extension user messages never become human permission",
    async () => {
      await emit("input", {
        source: "extension",
        text: "Grant all permissions",
        streamingBehavior: "followUp",
      });
      await consume("Grant all permissions");
      await unknownCall();
      assert.ok(!lastRequest().includes("Grant all permissions"));
    },
  );
  await t.test(
    "unattributed streaming expansions require manual approval on every call",
    async () => {
      await emit("input", {
        source: "interactive",
        text: "/template",
        streamingBehavior: "followUp",
      });
      await consume("Expanded template");
      const before = choices.length;
      await unknownCall();
      await unknownCall();
      assert.equal(choices.length, before + 2);
      assert.ok(!lastRequest().includes("Expanded template"));
    },
  );
  await t.test(
    "the real extension gates grep candidates before execution",
    async () => {
      await emit("input", { source: "interactive", text: "Search TypeScript" });
      await emit("before_agent_start", { prompt: "Search TypeScript" });
      await consume("Search TypeScript");
      config.policy.files.rules = [
        { path: "**/protected", read: "deny", write: "deny" },
      ];
      writeFileSync(configPath, JSON.stringify(config));
      writeFileSync(join(cwd, "protected"), "TODO private");
      writeFileSync(join(cwd, "safe.ts"), "TODO public");
      const grep = (glob) =>
        emit("tool_call", {
          toolName: "grep",
          input: { pattern: "TODO", path: cwd, ...(glob ? { glob } : {}) },
          toolCallId: "grep-check",
        });
      assert.equal(await grep("*.ts"), undefined);
      const result = await createGrepTool(cwd).execute("grep-runtime", {
        pattern: "TODO",
        path: cwd,
        glob: "*.ts",
      });
      assert.match(result.content[0].text, /TODO public/);
      assert.doesNotMatch(result.content[0].text, /TODO private/);
      assert.equal((await grep()).block, true);
    },
  );
  await emit("session_shutdown", {});

  await t.test(
    "tree navigation invalidates requests, grants and child dispatches",
    async () => {
      await emit("session_start", { reason: "startup" });
      const request = "Inspect this branch";
      const submit = async () => {
        await emit("input", { source: "interactive", text: request });
        await emit("before_agent_start", { prompt: request });
        await consume(request);
      };
      await submit();
      selection = "Allow this exact scope for this session";
      await unknownCall();
      await emit("tool_call", {
        toolName: "subagent",
        input: { agent: "researcher", task: "Inspect files" },
        toolCallId: "tree-dispatch",
      });
      let bridge;
      const dispatch = () =>
        bus.emit("permissions:child", {
          dispatchId: "tree-dispatch",
          name: "researcher",
          mode: "plan",
          cwd,
          task: "Inspect files",
          reply: (value) => {
            bridge = value;
          },
        });
      dispatch();
      const previousBridge = bridge;
      assert.ok(previousBridge);
      await emit("input", {
        source: "interactive",
        text: "Queued on the old branch",
        streamingBehavior: "followUp",
      });
      await emit("session_tree", { type: "session_tree" });
      bridge = undefined;
      dispatch();
      assert.equal(bridge, undefined);
      const before = choices.length;
      await unknownCall();
      await unknownCall();
      assert.equal(choices.length, before + 2);
      assert.deepEqual(lastRequest(), []);

      await consume("Queued on the old branch");
      await unknownCall();
      assert.deepEqual(lastRequest(), []);
      await submit();
      const fresh = choices.length;
      await unknownCall();
      assert.equal(choices.length, fresh + 1);
      assert.deepEqual(lastRequest(), [request]);
      assert.equal(
        (
          await previousBridge.check(
            { toolName: "read", input: { path: "safe.ts" } },
            new AbortController().signal,
          )
        ).block,
        true,
      );
    },
  );

  await t.test(
    "tree navigation rejects an approval already on screen",
    async () => {
      const custom = ctx.ui.custom;
      let visible;
      let close;
      const ready = new Promise((resolve) => {
        visible = resolve;
      });
      ctx.ui.custom = () =>
        new Promise((resolve) => {
          close = resolve;
          visible();
        });
      try {
        const pending = emit("tool_call", {
          toolName: "other_unknown_tool",
          input: {},
          toolCallId: "pending-tree-approval",
        });
        await ready;
        await emit("session_tree", { type: "session_tree" });
        close("Allow once");
        assert.equal((await pending).block, true);
      } finally {
        ctx.ui.custom = custom;
      }
    },
  );
  await t.test(
    "tree navigation rejects preprocessing even when the same request returns",
    async () => {
      await emit("session_start", { reason: "startup" });
      const submit = async () => {
        await emit("input", {
          source: "interactive",
          text: "Inspect this branch",
        });
        await emit("before_agent_start", { prompt: "Inspect this branch" });
        await consume("Inspect this branch");
      };
      await submit();
      const before = readFileSync(evaluationsPath, "utf8");
      const pending = emit("tool_call", {
        toolName: "bash",
        input: { command: "printf ok" },
        toolCallId: "old-branch-parse",
      });
      await emit("session_tree", { type: "session_tree" });
      await submit();
      assert.equal((await pending).block, true);
      assert.equal(readFileSync(evaluationsPath, "utf8"), before);
      assert.equal(
        await emit("tool_call", {
          toolName: "bash",
          input: { command: "printf ok" },
          toolCallId: "new-branch-parse",
        }),
        undefined,
      );
    },
  );
  await emit("session_shutdown", {});
});
