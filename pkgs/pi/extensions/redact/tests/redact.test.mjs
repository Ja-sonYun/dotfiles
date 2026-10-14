import assert from "node:assert/strict";
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
import { createRedactedOperations } from "../execution.ts";

test("redact intercepts Pi shell output before publication", async (t) => {
  assert.match(
    process.env.TMPDIR ?? "",
    /^\/tmp\/codex\/dotfiles\/\d{8}-\d{6}-[a-z-]+\/?$/,
  );
  assert.ok(process.env.PI_TEST_SDK);
  assert.ok(process.env.PI_TEST_REDACT);
  const cwd = mkdtempSync(join(process.env.TMPDIR, "redact-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const previous = { ...process.env };
  t.after(() => {
    for (const name of [
      "HOME",
      "PATH",
      "PI_REDACT_EXECUTABLE",
      "PI_CODING_AGENT_DIR",
      "PI_REDACT_FIXTURE",
    ]) {
      if (previous[name] === undefined) delete process.env[name];
      else process.env[name] = previous[name];
    }
  });
  process.env.HOME = cwd;
  process.env.PI_REDACT_EXECUTABLE = process.env.PI_TEST_REDACT;
  process.env.PI_CODING_AGENT_DIR = join(cwd, "agent");
  process.env.PI_REDACT_FIXTURE = "fixture-secret-value";
  mkdirSync(join(cwd, ".config", "redact"), { recursive: true });
  writeFileSync(
    join(cwd, ".config", "redact", "rules.txt"),
    "fixture-secret-value\n",
  );
  const sdk = await import(process.env.PI_TEST_SDK);
  const source = fileURLToPath(new URL("../index.ts", import.meta.url));
  const loaded = await sdk.discoverAndLoadExtensions([source], cwd, cwd);
  assert.deepEqual(loaded.errors, []);
  const extension = loaded.extensions[0];
  const bash = extension.tools.get("bash").definition;
  const signal = new AbortController().signal;
  const ctx = {
    cwd,
    sessionManager: {
      getSessionId: () => "redact-test",
      getSessionFile: () => undefined,
    },
  };
  const command =
    "printf '%s' fixture-secret-value; printf '\n%s\n' fixture-secret-value >&2; exit 7";
  const masked = (value) => {
    assert.doesNotMatch(value, /fixture-secret-value/);
    assert.match(value, /\[REDACTED:/);
  };

  await t.test(
    "stdout, stderr, updates, structured results and exit codes",
    async () => {
      const updates = [];
      const result = await bash.execute(
        "bash-1",
        { command },
        signal,
        (value) => updates.push(value),
        ctx,
      );
      masked(JSON.stringify(result));
      masked(JSON.stringify(updates));
      assert.equal(result.isError, true);
      assert.equal(result.structuredContent.exit_code, 7);
      assert.equal(
        result.structuredContent.output.match(/\[REDACTED:/g).length,
        2,
      );
    },
  );

  await t.test(
    "command and environment stay intact; split secrets wait for EOF",
    async () => {
      let output = "";
      const operations = createRedactedOperations(
        {
          async exec(actualCommand, actualCwd, options) {
            assert.equal(actualCommand, command);
            assert.equal(actualCwd, cwd);
            assert.equal(options.env.CHECK, "fixture-secret-value");
            assert.equal(options.timeout, 42);
            options.onData(Buffer.from("fixture-sec"));
            assert.equal(output, "");
            options.onData(Buffer.from("ret-value"));
            return { exitCode: 9 };
          },
        },
        process.env.PI_TEST_REDACT,
      );
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
      assert.ok(result.details.fullOutputPath);
      const path = result.details.fullOutputPath;
      t.after(() => rmSync(path, { force: true }));
      masked(readFileSync(path, "utf8"));
      masked(JSON.stringify(result));
    },
  );

  await t.test(
    "user_bash operations also sanitize interactive and RPC output",
    async () => {
      const { operations } = await extension.handlers.get("user_bash")[0](
        { command },
        ctx,
      );
      const { executeBashWithOperations } = await import(
        new URL(
          "./core/bash-executor.js",
          pathToFileURL(process.env.PI_TEST_SDK),
        )
      );
      const updates = [];
      const result = await executeBashWithOperations(command, cwd, operations, {
        onChunk: (chunk) => updates.push(chunk),
      });
      masked(result.output);
      masked(updates.join(""));
      assert.equal(result.exitCode, 7);
    },
  );

  await t.test(
    "codemode receives sanitized structured Bash output",
    async () => {
      let codemode;
      sdk.createCodemodeExtension({ models: false })({
        registerTool: (tool) => {
          codemode = tool;
        },
        getAllTools: () => [bash],
        getSettings: () => ({}),
      });
      const result = await codemode.execute(
        "code",
        {
          code: `text(await tools.bash({command: 'printf "%s" "$PI_REDACT_FIXTURE"'}));`,
        },
        signal,
        undefined,
        {
          tools: [bash],
          sessionManager: { getBranch: () => [] },
          executeTool: async (name, args, options) => {
            assert.equal(name, "bash");
            const result = await bash.execute(
              "nested",
              args,
              options.signal,
              undefined,
              ctx,
            );
            return {
              toolCall: { id: "nested" },
              result,
              isError: result.isError ?? false,
            };
          },
        },
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
        process.env.PI_TEST_REDACT,
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
      const fail = join(cwd, "filter-failure");
      writeFileSync(
        fail,
        `#!${process.execPath}\nprocess.stdin.resume(); process.stdin.on('end', () => { process.stdout.write('fixture-secret-value'); process.stderr.write('fixture-secret-value'); process.exitCode = 1; });\n`,
        { mode: 0o700 },
      );
      for (const executable of [undefined, join(cwd, "missing"), fail]) {
        const operations = createRedactedOperations(
          sdk.createLocalBashOperations(),
          executable,
        );
        await assert.rejects(
          operations.exec("printf fixture-secret-value", cwd, {
            onData: () => assert.fail("raw output published"),
          }),
          /^(Error: Redact failed; output withheld|Error: Redact executable is not configured)$/,
        );
      }
      const operations = createRedactedOperations(
        {
          async exec() {
            throw new Error("fixture-secret-value");
          },
        },
        process.env.PI_TEST_REDACT,
      );
      await assert.rejects(
        operations.exec("command", cwd, { onData: () => assert.fail() }),
        /^Error: Command execution failed; output withheld$/,
      );
    },
  );

  await t.test(
    "filter cancellation and its separate deadline withhold partial output",
    async () => {
      const hanging = join(cwd, "filter-hanging");
      const ready = join(cwd, "filter-ready");
      writeFileSync(
        hanging,
        `#!${process.execPath}\nprocess.stdin.resume(); process.stdin.on('end', () => { require('node:fs').writeFileSync(${JSON.stringify(ready)}, 'ready'); process.stdout.write('fixture-secret-value'); setInterval(() => {}, 1000); });\n`,
        { mode: 0o700 },
      );
      const operations = createRedactedOperations(
        sdk.createLocalBashOperations(),
        hanging,
      );
      const controller = new AbortController();
      const pending = operations.exec("printf fixture-secret-value", cwd, {
        signal: controller.signal,
        onData: () => assert.fail("partial output published"),
      });
      const timer = setInterval(() => {
        try {
          readFileSync(ready);
          controller.abort();
        } catch {}
      }, 20);
      try {
        await assert.rejects(pending, /^Error: aborted$/);
      } finally {
        clearInterval(timer);
      }
      await assert.rejects(
        operations.exec("printf fixture-secret-value", cwd, {
          onData: () => assert.fail("partial output published"),
        }),
        /^Error: Redact failed; output withheld$/,
      );
    },
  );

  await t.test(
    "spawned subagents inherit the extension profile and redact executable",
    async () => {
      const agentDir = process.env.PI_CODING_AGENT_DIR;
      mkdirSync(join(agentDir, "agents"), { recursive: true });
      writeFileSync(
        join(agentDir, "agents", "worker.md"),
        "---\nname: worker\ndescription: Run a command\n---\nRun the task.\n",
      );
      writeFileSync(
        join(agentDir, "settings.json"),
        JSON.stringify({ extensions: [source] }),
      );
      const child = `#!${process.execPath}
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {discoverAndLoadExtensions} from ${JSON.stringify(process.env.PI_TEST_SDK)};
assert.equal(process.env.PI_PERMISSION_CHILD, '1');
assert.equal(process.env.PI_REDACT_EXECUTABLE, ${JSON.stringify(process.env.PI_TEST_REDACT)});
assert.equal(process.argv.includes('-ne'), false);
const settings = JSON.parse(readFileSync(join(process.env.PI_CODING_AGENT_DIR, 'settings.json'), 'utf8'));
const loaded = await discoverAndLoadExtensions(settings.extensions, process.cwd(), process.env.PI_CODING_AGENT_DIR);
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
        emit: (name, data) => emitter.emit(name, data),
        on: (name, fn) => {
          emitter.on(name, fn);
          return () => emitter.off(name, fn);
        },
      };
      bus.on("permissions:child", (message) =>
        message.reply({
          extension: source,
          mode: "default",
          check: async () => undefined,
        }),
      );
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
      const tool = subagents.extensions[0].tools.get("subagent").definition;
      const result = await tool.execute(
        "dispatch",
        { agent: "worker", task: "Run a command" },
        signal,
        undefined,
        { cwd, hasUI: false },
      );
      assert.notEqual(result.isError, true, JSON.stringify(result));
      masked(JSON.stringify(result));
    },
  );
});
