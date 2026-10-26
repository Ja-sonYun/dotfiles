import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import type {
  ExtensionAPI,
  ExtensionToolContext,
  ToolDefinition,
  BashOperations,
} from "@earendil-works/pi-coding-agent";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { PermissionBridge } from "../../subagent/permissions.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function record(value: unknown): Record<string, unknown> {
  assert.ok(isRecord(value));
  return value;
}

import { createRedactedOperations } from "../execution.ts";
import { redact } from "../../../redaction/index.ts";

test("redact intercepts Pi shell output before publication", async (t) => {
  assert.match(
    process.env.TMPDIR ?? "",
    /^\/tmp\/codex\/dotfiles\/\d{8}-\d{6}-[a-z-]+\/?$/,
  );
  assert.ok(process.env.PI_TEST_SDK);
  assert.ok(process.env.TMPDIR);
  const cwd = mkdtempSync(join(process.env.TMPDIR, "redact-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const previous = { ...process.env };
  t.after(() => {
    for (const name of [
      "HOME",
      "PATH",
      "PI_RESOURCE_PACKAGE",
      "PI_CODING_AGENT_DIR",
      "PI_REDACT_FIXTURE",
      "PI_REDACTION_RULES_FILE",
    ]) {
      if (previous[name] === undefined) delete process.env[name];
      else process.env[name] = previous[name];
    }
  });
  process.env.HOME = cwd;
  process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
  process.env.PI_REDACT_FIXTURE = "fixture-secret-value";
  process.env.PI_REDACTION_RULES_FILE = join(
    cwd,
    ".config",
    "redact",
    "rules.txt",
  );
  mkdirSync(join(cwd, ".config", "redact"), { recursive: true });
  writeFileSync(
    join(cwd, ".config", "redact", "rules.txt"),
    "fixture-secret-value\n",
  );
  const sdk: typeof import("@earendil-works/pi-coding-agent") = await import(
    process.env.PI_TEST_SDK
  );
  const source = fileURLToPath(new URL("../index.ts", import.meta.url));
  const loaded = await sdk.discoverAndLoadExtensions([source], cwd, cwd);
  assert.deepEqual(loaded.errors, []);
  const extension = loaded.extensions[0];
  assert.ok(extension);
  const bash = extension.tools.get("bash")?.definition;
  assert.ok(bash);
  const signal = new AbortController().signal;
  const context = (
    overrides: Partial<ExtensionToolContext> = {},
  ): ExtensionToolContext => ({
    cwd,
    sessionManager: Object.assign(sdk.SessionManager.inMemory(cwd), {
      getSessionId: () => "redact-test",
      getSessionFile: () => undefined,
    }),
    mode: "json",
    hasUI: false,
    model: undefined,
    scopedModels: [],
    signal: undefined,
    get modelRegistry(): never {
      return assert.fail("Unexpected model registry access");
    },
    get ui(): never {
      return assert.fail("Unexpected UI access");
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
    ...overrides,
  });
  const ctx = context();
  const bashTool: AgentTool = {
    ...bash,
    execute: (id, params, signal, onUpdate) =>
      bash.execute(id, params, signal, onUpdate, ctx),
  };
  const command =
    "printf '%s' fixture-secret-value; printf '\n%s\n' fixture-secret-value >&2; exit 7";
  const masked = (value: string) => {
    assert.doesNotMatch(value, /fixture-secret-value/);
    assert.match(value, /\[REDACTED:/);
  };

  await t.test(
    "built-in rules preserve unrelated bytes and NUL separators",
    async () => {
      const token =
        "ghp_" +
        createHash("sha256")
          .update("synthetic fixture")
          .digest("hex")
          .slice(0, 36);
      const input = Buffer.concat([
        Buffer.from([255, 0]),
        Buffer.from(`token = ${token}\nBearer sample-token`),
      ]);
      assert.deepEqual(
        await redact(input),
        Buffer.concat([
          Buffer.from([255, 0]),
          Buffer.from("token = [REDACTED:github-pat]\nBearer [REDACTED:token]"),
        ]),
      );
    },
  );

  await t.test(
    "personal regex overlaps and environment references",
    async () => {
      const path = join(cwd, ".config", "redact", "rules.txt");
      writeFileSync(path, "abcdef\nregex:bcdefgh\n$(PI_REDACT_FIXTURE)\n");
      try {
        assert.equal(
          (
            await redact(Buffer.from("abcdefgh\0fixture-secret-value"))
          ).toString(),
          "[REDACTED:custom-regex]\0[REDACTED:env-pi-redact-fixture]",
        );
      } finally {
        writeFileSync(path, "fixture-secret-value\n");
      }
    },
  );

  await t.test("read text and structured content are both masked", async () => {
    const path = join(cwd, "read.txt");
    writeFileSync(path, "fixture-secret-value\n");
    const read = extension.tools.get("read")?.definition;
    assert.ok(read);
    const result = await read.execute("read", { path }, signal, undefined, ctx);
    masked(JSON.stringify(result.content));
    masked(JSON.stringify(result.structuredContent));
  });

  await t.test(
    "stdout, stderr, updates, structured results and exit codes",
    async () => {
      const updates: unknown[] = [];
      const result = await bash.execute(
        "bash-1",
        { command },
        signal,
        (value: unknown) => updates.push(value),
        ctx,
      );
      masked(JSON.stringify(result));
      masked(JSON.stringify(updates));
      assert.equal(result.isError, true);
      const structured = record(result.structuredContent);
      assert.ok(typeof structured.output === "string");
      assert.equal(structured.exit_code, 7);
      assert.equal(structured.output.match(/\[REDACTED:/g)?.length, 2);
    },
  );

  await t.test(
    "command and environment stay intact; split secrets wait for EOF",
    async () => {
      let output = "";
      const operations = createRedactedOperations({
        async exec(actualCommand, actualCwd, options) {
          assert.equal(actualCommand, command);
          assert.equal(actualCwd, cwd);
          assert.equal(options.env?.CHECK, "fixture-secret-value");
          assert.equal(options.timeout, 42);
          options.onData(Buffer.from("fixture-sec"));
          assert.equal(output, "");
          options.onData(Buffer.from("ret-value"));
          return { exitCode: 9 };
        },
      });
      const result = await operations.exec(command, cwd, {
        timeout: 42,
        env: { CHECK: "fixture-secret-value" },
        onData: (data) => {
          output += data;
        },
      });
      masked(output);
      assert.equal(result.exitCode, 9);
    },
  );

  await t.test(
    "large sanitized output is the only content persisted to Pi's log",
    async () => {
      const result = await bash.execute(
        "large",
        {
          command:
            "for ((i=0;i<6000;i++)); do printf '%s\n' fixture-secret-value; done",
        },
        signal,
        undefined,
        ctx,
      );
      const details = record(result.details);
      assert.ok(typeof details.fullOutputPath === "string");
      const path = details.fullOutputPath;
      t.after(() => rmSync(path, { force: true }));
      masked(readFileSync(path, "utf8"));
      masked(JSON.stringify(result));
    },
  );

  await t.test(
    "user_bash operations also sanitize interactive and RPC output",
    async () => {
      const handler = extension.handlers.get("user_bash")?.[0];
      assert.ok(handler);
      const handled = record(await handler({ command }, ctx));
      const rawOperations = record(handled.operations);
      const exec = rawOperations.exec;
      assert.ok(typeof exec === "function");
      const operations: BashOperations = {
        async exec(command, cwd, options) {
          const value = record(
            await Reflect.apply(exec, rawOperations, [command, cwd, options]),
          );
          assert.ok(
            value.exitCode === null || typeof value.exitCode === "number",
          );
          return { exitCode: value.exitCode };
        },
      };
      assert.ok(process.env.PI_TEST_SDK);
      const executor = record(
        await import(
          new URL(
            "./core/bash-executor.js",
            pathToFileURL(process.env.PI_TEST_SDK),
          ).href
        ),
      );
      assert.ok(typeof executor.executeBashWithOperations === "function");
      const updates: unknown[] = [];
      const result = record(
        await Reflect.apply(executor.executeBashWithOperations, executor, [
          command,
          cwd,
          operations,
          {
            onChunk: (chunk: unknown) => {
              assert.ok(typeof chunk === "string");
              updates.push(chunk);
            },
          },
        ]),
      );
      assert.ok(typeof result.output === "string");
      masked(result.output);
      masked(updates.join(""));
      assert.equal(result.exitCode, 7);
    },
  );

  await t.test(
    "codemode receives sanitized structured Bash output",
    async () => {
      let executeCodemode: ToolDefinition["execute"] | undefined;
      const api: Pick<
        ExtensionAPI,
        "registerTool" | "getAllTools" | "getSettings"
      > = {
        registerTool: (tool) => {
          executeCodemode = tool.execute;
        },
        getAllTools: () => [
          {
            ...bash,
            exposure: bash.exposure ?? "direct",
            sourceInfo: extension.sourceInfo,
          },
        ],
        getSettings: () => ({}),
      };
      Reflect.apply(sdk.createCodemodeExtension({ models: false }), undefined, [
        api,
      ]);
      assert.ok(executeCodemode);
      const result = await executeCodemode(
        "code",
        {
          code: `text(await tools.bash({command: 'printf "%s" "$PI_REDACT_FIXTURE"'}));`,
        },
        signal,
        undefined,
        context({
          tools: [bashTool],
          executeTool: async (name, args, options) => {
            assert.equal(name, "bash");
            const input = record(args);
            assert.ok(typeof input.command === "string");
            const command = input.command;
            const result = await bash.execute(
              "nested",
              { command },
              options?.signal,
              undefined,
              ctx,
            );
            return {
              toolCall: {
                type: "toolCall",
                id: "nested",
                name,
                arguments: { command },
              },
              result,
              isError: result.isError ?? false,
            };
          },
        }),
      );
      assert.notEqual(result.isError, true, JSON.stringify(result));
      masked(JSON.stringify(result));
    },
  );

  await t.test(
    "cancellation and timeout discard buffered raw output",
    async () => {
      const controller = new AbortController();
      const pending = bash.execute(
        "cancel",
        { command: "printf fixture-secret-value; sleep 30" },
        controller.signal,
        undefined,
        ctx,
      );
      const timer = setTimeout(() => controller.abort(), 150);
      try {
        await assert.rejects(pending, /^Error: Command aborted$/);
      } finally {
        clearTimeout(timer);
      }
      await assert.rejects(
        bash.execute(
          "timeout",
          {
            command: "printf fixture-secret-value; sleep 30",
            timeout: 0.1,
          },
          signal,
          undefined,
          ctx,
        ),
        /^Error: Command timed out after 0.1 seconds$/,
      );
      await assert.rejects(
        bash.execute(
          "already-cancelled",
          { command: "printf fixture-secret-value" },
          controller.signal,
          undefined,
          ctx,
        ),
        /^Error: Command aborted$/,
      );
    },
  );

  await t.test(
    "output overflow aborts execution without publishing any bytes",
    async () => {
      const operations = createRedactedOperations(
        sdk.createLocalBashOperations(),
      );
      await assert.rejects(
        operations.exec("head -c 17000000 /dev/zero; sleep 30", cwd, {
          onData: () => assert.fail("raw output published"),
        }),
        /Redact output limit exceeded/,
      );
    },
  );

  await t.test(
    "filter failures and native errors never publish raw diagnostics",
    async () => {
      const rules = join(cwd, ".config", "redact", "rules.txt");
      writeFileSync(rules, "regex:(\n");
      try {
        const operations = createRedactedOperations(
          sdk.createLocalBashOperations(),
        );
        await assert.rejects(
          operations.exec("printf fixture-secret-value", cwd, {
            onData: () => assert.fail("raw output published"),
          }),
          /^Error: Redact failed; output withheld$/,
        );
      } finally {
        writeFileSync(rules, "fixture-secret-value\n");
      }
      const operations = createRedactedOperations({
        async exec() {
          throw new Error("fixture-secret-value");
        },
      });
      await assert.rejects(
        operations.exec("command", cwd, { onData: () => assert.fail() }),
        /^Error: Command execution failed; output withheld$/,
      );
    },
  );

  await t.test("worker cancellation withholds output", async () => {
    const controller = new AbortController();
    const pending = redact(
      Buffer.from("fixture-secret-value"),
      controller.signal,
    );
    const timer = setTimeout(() => controller.abort(), 1);
    try {
      await assert.rejects(pending, /^Error: aborted$/);
    } finally {
      clearTimeout(timer);
    }
  });

  await t.test(
    "spawned subagents inherit the selected resource package",
    async () => {
      const agentDir = process.env.PI_CODING_AGENT_DIR;
      assert.ok(agentDir);
      mkdirSync(join(agentDir, "agents"), { recursive: true });
      writeFileSync(
        join(agentDir, "agents", "worker.md"),
        "---\nname: worker\ndescription: Run a command\n---\nRun the task.\n",
      );
      writeFileSync(
        join(cwd, "package.json"),
        JSON.stringify({ name: "redact-test", pi: { extensions: [source] } }),
      );
      process.env.PI_RESOURCE_PACKAGE = cwd;
      const child = `#!${process.execPath}
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {discoverAndLoadExtensions} from ${JSON.stringify(process.env.PI_TEST_SDK)};
assert.equal(process.env.PI_PERMISSION_CHILD, '1');
assert.equal(process.env.PI_RESOURCE_PACKAGE, ${JSON.stringify(cwd)});
assert.equal(process.argv.includes('-ne'), false);
const bundle = JSON.parse(readFileSync(join(process.env.PI_RESOURCE_PACKAGE, 'package.json'), 'utf8'));
const loaded = await discoverAndLoadExtensions(bundle.pi.extensions, process.cwd(), process.env.PI_CODING_AGENT_DIR);
assert.deepEqual(loaded.errors, []);
const bash = loaded.extensions[0].tools.get('bash').definition;
const ctx = {cwd:process.cwd(),sessionManager:{getSessionId:()=>'child',getSessionFile:()=>undefined}};
const result = await bash.execute('child-bash', {command:'printf fixture-secret-value'}, undefined, undefined, ctx);
process.stdout.write(JSON.stringify({type:'message_end',message:{role:'assistant',content:result.content,stopReason:'stop'}}) + '\\n');
process.disconnect();
`;
      writeFileSync(join(cwd, "pi"), child, { mode: 0o700 });
      process.env.PATH = `${cwd}:${previous.PATH}`;
      const emitter = new EventEmitter();
      const bus = {
        emit: (name: string, data: unknown) => emitter.emit(name, data),
        on: (name: string, fn: (data: unknown) => void) => {
          emitter.on(name, fn);
          return () => emitter.off(name, fn);
        },
      };
      bus.on("permissions:child", (message) => {
        const request = record(message);
        assert.ok(typeof request.reply === "function");
        const bridge: PermissionBridge = {
          extension: source,
          mode: "default",
          check: async () => undefined,
          rules: async () => ({}),
        };
        Reflect.apply(request.reply, request, [bridge]);
      });
      const subagentSource = fileURLToPath(
        new URL("../../subagent/index.ts", import.meta.url),
      );
      const subagents = await sdk.discoverAndLoadExtensions(
        [subagentSource],
        cwd,
        agentDir,
        bus,
      );
      assert.deepEqual(subagents.errors, []);
      const tool = subagents.extensions[0]?.tools.get("subagent")?.definition;
      assert.ok(tool);
      const result = await tool.execute(
        "dispatch",
        { agent: "worker", task: "Run a command", background: false },
        signal,
        undefined,
        context({ hasUI: false }),
      );
      assert.notEqual(result.isError, true, JSON.stringify(result));
      masked(JSON.stringify(result));
    },
  );
});
