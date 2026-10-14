import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("a spawned plan agent uses its parent's permission channel", async (t) => {
  assert.match(
    process.env.TMPDIR ?? "",
    /^\/tmp\/codex\/dotfiles\/\d{8}-\d{6}-[a-z-]+\/?$/,
  );
  const cwd = mkdtempSync(join(process.env.TMPDIR, "subagent-ipc-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const sdk = process.env.PI_TEST_SDK;
  assert.ok(sdk, "PI_TEST_SDK must point to the installed Pi SDK");
  const { discoverAndLoadExtensions } = await import(sdk);
  const previous = {
    PATH: process.env.PATH,
    PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
    PI_PERMISSIONS_CONFIG: process.env.PI_PERMISSIONS_CONFIG,
  };
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  process.env.PI_CODING_AGENT_DIR = cwd;
  process.env.PI_PERMISSIONS_CONFIG = join(cwd, "permissions.json");
  process.env.PATH = `${cwd}:${process.env.PATH}`;
  mkdirSync(join(cwd, "agents"));
  mkdirSync(join(cwd, "child"));
  writeFileSync(
    join(cwd, "agents", "reader.md"),
    "---\nname: reader\ndescription: Inspect files\npermissionMode: plan\n---\nRead files only.\n",
  );
  writeFileSync(
    process.env.PI_PERMISSIONS_CONFIG,
    JSON.stringify({
      policy: {
        commands: { rules: [] },
        files: { rules: [] },
        mcp: {},
        mcp_readonly_tools: {},
        defaultRead: true,
      },
      parser: process.env.PI_TEST_SHFMT || "shfmt",
      evaluator: [],
    }),
  );
  const childSource = `#!${process.execPath}
import assert from 'node:assert/strict';
import { discoverAndLoadExtensions } from ${JSON.stringify(sdk)};
const entry = process.argv[process.argv.indexOf('--extension') + 1];
assert.equal(process.env.PI_PERMISSION_CHILD, '1');
assert.equal(process.env.PI_PERMISSION_MODE, 'plan');
const loaded = await discoverAndLoadExtensions([entry], process.cwd(), process.env.PI_CODING_AGENT_DIR);
assert.deepEqual(loaded.errors, []);
const handler = loaded.extensions[0].handlers.get('tool_call')[0];
const denied = await handler({toolName:'write', input:{path:'file.txt',content:'bad'}, parentToolCallId:'codemode-child'}, {cwd:process.cwd()});
assert.equal(denied.block, true);
process.stdout.write(JSON.stringify({type:'message_end',message:{role:'assistant',content:[{type:'text',text:'Write blocked by parent in ' + process.cwd()}],stopReason:'stop'}}) + '\\n');
process.disconnect();
`;
  writeFileSync(join(cwd, "pi"), childSource, { mode: 0o700 });
  const emitter = new EventEmitter();
  const bus = {
    emit: (name, data) => emitter.emit(name, data),
    on: (name, fn) => {
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
  const ctx = { cwd, hasUI: true, ui: { select: async () => "Allow once" } };
  const permissionExtension = loaded.extensions.find(
    (extension) => extension.resolvedPath === permissions,
  );
  for (const handler of permissionExtension.handlers.get("session_start"))
    await handler({ reason: "startup" }, ctx);
  const params = { agent: "reader", task: "Inspect files", cwd: "child" };
  for (const handler of permissionExtension.handlers.get("tool_call")) {
    const result = await handler(
      { toolName: "subagent", input: params, toolCallId: "dispatch" },
      ctx,
    );
    assert.equal(result, undefined);
  }
  const tool = loaded.extensions
    .find((extension) => extension.resolvedPath === subagent)
    .tools.get("subagent").definition;
  const result = await tool.execute(
    "dispatch",
    params,
    new AbortController().signal,
    undefined,
    ctx,
  );
  assert.equal(result.isError, undefined, JSON.stringify(result));
  assert.match(result.content[0].text, /Write blocked by parent/);
  assert.ok(result.content[0].text.includes(join(cwd, "child")));
});
