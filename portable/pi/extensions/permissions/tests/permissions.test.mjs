import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { analyzeBash } from "../bash.ts";
import {
  assess,
  assessSearch,
  fileDecision,
  mcpName,
  normalizeFileCall,
} from "../policy.ts";
import { PermissionSession } from "../session.ts";

const policy = {
  commands: {
    rules: [
      { prefix: ["printf"], decision: "allow" },
      { prefix: ["rm"], decision: "deny" },
      { prefix: ["cat"], decision: "allow" },
      { prefix: ["tee"], decision: "allow" },
      { prefix: ["bash"], decision: "allow" },
    ],
  },
  files: { rules: [{ path: "**/protected", read: "deny", write: "deny" }] },
  mcp: { docs: { default: "allow", tools: { delete: "deny", query: "ask" } } },
  mcp_readonly_tools: { docs: ["query"] },
  defaultRead: true,
};
const actor = { cwd: "/workspace", name: "main", mode: "default", task: "" };

for (const command of [
  "printf ok && rm file",
  "printf ok | rm file",
  "printf $(rm file)",
  "(printf ok; rm file)",
  "env rm file",
  "/bin/rm file",
]) {
  test(`checks every executable in ${command}`, async () => {
    const shell = await analyzeBash(
      command,
      process.env.PI_TEST_SHFMT || "shfmt",
    );
    assert.equal(
      assess(policy, { toolName: "bash", input: { command } }, actor, shell)
        .decision,
      "deny",
    );
  });
}

for (const command of [
  "printf ok > protected",
  "printf ok | tee protected",
  "cat < protected",
]) {
  test(`checks file effects in ${command}`, async () => {
    const shell = await analyzeBash(
      command,
      process.env.PI_TEST_SHFMT || "shfmt",
    );
    assert.equal(
      assess(policy, { toolName: "bash", input: { command } }, actor, shell)
        .decision,
      "deny",
    );
  });
}

for (const command of [
  "bash -c 'some_program'",
  "printf $COMMAND",
  "printf *.txt",
  "printf '",
]) {
  test(`asks for opaque or invalid shell: ${command}`, async () => {
    const shell = await analyzeBash(
      command,
      process.env.PI_TEST_SHFMT || "shfmt",
    );
    assert.equal(
      assess(policy, { toolName: "bash", input: { command } }, actor, shell)
        .decision,
      "ask",
    );
  });
}

test("literal quoted words remain intact and separators inside quotes do not execute", async () => {
  const shell = await analyzeBash(
    "printf '%s' 'rm protected; echo x'",
    process.env.PI_TEST_SHFMT || "shfmt",
  );
  assert.deepEqual(shell.commands, [["printf", "%s", "rm protected; echo x"]]);
  assert.equal(
    assess(policy, { toolName: "bash", input: {} }, actor, shell).decision,
    "allow",
  );
});

test("file aliases and recursive searches cannot bypass a denied path", async (t) => {
  const cwd = mkdtempSync(join(tmpdir(), "permissions-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  writeFileSync(join(cwd, "protected"), "fixture");
  symlinkSync(join(cwd, "protected"), join(cwd, "alias"));
  mkdirSync(join(cwd, "allowed"));
  assert.equal(fileDecision(policy, "alias", cwd, "read"), "deny");
  const call = { toolName: "read", input: { path: "@protected" } };
  normalizeFileCall(call, cwd);
  assert.equal(assess(policy, call, { ...actor, cwd }).decision, "deny");
  assert.equal(
    (
      await assessSearch(
        policy,
        { toolName: "grep", input: { path: cwd } },
        { ...actor, cwd },
        process.env.PI_TEST_RG || "rg",
      )
    ).decision,
    "deny",
  );
  assert.equal(
    (
      await assessSearch(
        policy,
        { toolName: "grep", input: { path: join(cwd, "allowed") } },
        { ...actor, cwd },
        process.env.PI_TEST_RG || "rg",
      )
    ).decision,
    "allow",
  );
});

test("grep permissions use the builtin search's glob, ignore, and symlink selection", async (t) => {
  const cwd = mkdtempSync(join(tmpdir(), "permissions-search-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  mkdirSync(join(cwd, ".git"));
  mkdirSync(join(cwd, "ignored"));
  mkdirSync(join(cwd, "secret-dir"));
  writeFileSync(join(cwd, ".gitignore"), "ignored/\nsecret-dir/\n");
  writeFileSync(join(cwd, "safe.ts"), "TODO visible\n");
  writeFileSync(join(cwd, "protected"), "TODO private\n");
  writeFileSync(join(cwd, "ignored", "protected"), "TODO ignored\n");
  writeFileSync(join(cwd, "secret-dir", "protected"), "TODO hidden\n");
  symlinkSync(join(cwd, "secret-dir"), join(cwd, "linked-dir"));
  symlinkSync(join(cwd, "protected"), join(cwd, "alias.ts"));
  const check = (input) =>
    assessSearch(
      policy,
      { toolName: "grep", input: { path: cwd, pattern: "TODO", ...input } },
      { ...actor, cwd, mode: "plan" },
      process.env.PI_TEST_RG || "rg",
    );
  assert.equal((await check({ glob: "*.ts" })).decision, "allow");
  assert.equal((await check({ glob: "no-match-*" })).decision, "allow");
  assert.equal((await check({})).decision, "deny");
  assert.equal((await check({ path: join(cwd, "alias.ts") })).decision, "deny");
  rmSync(join(cwd, "protected"));
  rmSync(join(cwd, "alias.ts"));
  assert.equal((await check({})).decision, "allow");
  for (let i = 0; i < 10001; i++)
    writeFileSync(join(cwd, "ignored", `file-${i}`), "");
  assert.equal((await check({ glob: "*.ts" })).decision, "allow");
  await assert.rejects(check({ glob: "[" }));
});

test("read-only checks apply equally to nested calls and ignore server hints", () => {
  const readonly = { ...actor, name: "researcher", mode: "plan" };
  for (const toolName of [
    "bash",
    "write",
    "edit",
    "mcp__docs__delete",
    "unknown",
  ]) {
    assert.equal(
      assess(
        policy,
        { toolName, input: {}, parentToolCallId: "codemode/1" },
        readonly,
      ).decision,
      "deny",
    );
  }
  assert.equal(
    assess(policy, { toolName: "mcp__docs__query", input: {} }, readonly)
      .decision,
    "ask",
  );
  assert.equal(
    assess(policy, { toolName: "codemode", input: {} }, readonly).decision,
    "allow",
  );
});

test("MCP denies outrank allows and long original names remain selectable", () => {
  assert.equal(
    assess(policy, { toolName: "mcp__docs__delete", input: {} }, actor)
      .decision,
    "deny",
  );
  const tool = "long_tool_".repeat(10);
  const long = {
    ...policy,
    mcp: { docs: { default: null, tools: { [tool]: "allow" } } },
    mcp_readonly_tools: { docs: [tool] },
  };
  assert.equal(
    assess(
      long,
      { toolName: mcpName("docs", tool), input: {} },
      { ...actor, mode: "plan" },
    ).decision,
    "allow",
  );
});

const call = { toolName: "bash", input: { command: "git status" } };
const clean = () =>
  Promise.resolve({
    fingerprint: "rules-v1",
    results: [{ id: "permission_request_scope", verdict: "compliant" }],
    errors: [],
  });
const ask = { decision: "ask", reasons: ["command"] };

test("session approval is exact and still runs rules on every call", async () => {
  const session = new PermissionSession();
  let prompts = 0;
  let checks = 0;
  const evaluate = () => {
    checks++;
    return clean();
  };
  const approve = async () => {
    prompts++;
    return "session";
  };
  const run = (
    input = call,
    who = actor,
    version = "policy-v1",
    request = "inspect",
  ) => session.check(input, who, request, version, ask, evaluate, approve);
  assert.equal(await run(), undefined);
  assert.equal(await run(), undefined);
  assert.equal(prompts, 1);
  assert.equal(checks, 2);
  await run({ ...call, input: { command: "git diff" } });
  await run(call, { ...actor, name: "child" });
  await run(call, { ...actor, cwd: "/other" });
  await run(call, actor, "policy-v2");
  await run(call, actor, "policy-v1", "different request");
  assert.equal(prompts, 6);
  session.reset();
  await run();
  assert.equal(prompts, 7);
});

test("once approval and repeated denial never become session grants", async () => {
  const session = new PermissionSession();
  let prompts = 0;
  for (const choice of ["once", "once", "deny", "deny"]) {
    const result = await session.check(
      call,
      actor,
      "inspect",
      "v1",
      ask,
      clean,
      async () => {
        prompts++;
        return choice;
      },
    );
    assert.equal(result?.block, choice === "deny" ? true : undefined);
  }
  assert.equal(prompts, 4);
});

test("hard denial and rule violations cannot be approved", async () => {
  const session = new PermissionSession();
  const forbidden = async () => {
    assert.fail("must not ask");
  };
  assert.equal(
    (
      await session.check(
        call,
        actor,
        "inspect",
        "v1",
        { decision: "deny", reasons: ["readonly"] },
        forbidden,
        forbidden,
      )
    ).block,
    true,
  );
  assert.equal(
    (
      await session.check(
        call,
        actor,
        "inspect",
        "v1",
        ask,
        async () => ({
          fingerprint: "v1",
          errors: [],
          results: [{ id: "rule", verdict: "violation" }],
        }),
        forbidden,
      )
    ).block,
    true,
  );
});

test("Jev failure and uncertainty require approval every time", async () => {
  const session = new PermissionSession();
  let prompts = 0;
  const evaluate = async () => {
    throw new Error("timeout");
  };
  for (let i = 0; i < 2; i++) {
    await session.check(
      call,
      actor,
      "inspect",
      "v1",
      { decision: "allow", reasons: [] },
      evaluate,
      async () => {
        prompts++;
        return "session";
      },
    );
  }
  assert.equal(prompts, 2);
  const headless = await session.check(
    call,
    actor,
    "inspect",
    "v1",
    ask,
    evaluate,
    async () => "deny",
  );
  assert.equal(headless.block, true);
});

test("reset cancels queued and visible approvals", async () => {
  const session = new PermissionSession();
  let displayed;
  const ready = new Promise((resolve) => {
    displayed = resolve;
  });
  const approve = async (_approval, signal) => {
    displayed();
    await new Promise((resolve) =>
      signal.addEventListener("abort", resolve, { once: true }),
    );
    return "once";
  };
  const first = session.check(
    call,
    actor,
    "inspect",
    "v1",
    ask,
    clean,
    approve,
  );
  const second = session.check(
    call,
    actor,
    "inspect",
    "v1",
    ask,
    clean,
    approve,
  );
  await ready;
  session.reset();
  assert.equal((await first).block, true);
  assert.equal((await second).block, true);
});

test("changed rules revoke a grant even when the old rules are restored", async () => {
  const session = new PermissionSession();
  let prompts = 0;
  const run = (version, choice) =>
    session.check(
      call,
      actor,
      "inspect",
      "policy",
      ask,
      async () => ({ ...(await clean()), fingerprint: version }),
      async () => {
        prompts++;
        return choice;
      },
    );
  await run("old", "session");
  assert.equal((await run("new", "deny")).block, true);
  await run("old", "once");
  assert.equal(prompts, 3);
});

test("a command allow cannot bypass a write-protected operand", async () => {
  const protectedPolicy = {
    ...policy,
    commands: { rules: [{ prefix: ["touch"], decision: "allow" }] },
    files: { rules: [{ path: "**/readonly", read: "allow", write: "deny" }] },
  };
  const shell = await analyzeBash(
    "touch readonly",
    process.env.PI_TEST_SHFMT || "shfmt",
  );
  assert.equal(
    assess(protectedPolicy, { toolName: "bash", input: {} }, actor, shell)
      .decision,
    "deny",
  );
});

test("Bash search allows cannot bypass an unverified restricted file scope", async () => {
  const searchPolicy = {
    ...policy,
    commands: {
      rules: ["rg", "grep", "egrep", "fgrep", "rgrep", "printf"].map(
        (name) => ({
          prefix: [name],
          decision: "allow",
        }),
      ),
    },
    files: { rules: [{ path: "**/.env", read: "deny", write: "deny" }] },
  };
  const decide = async (command, current = searchPolicy) =>
    assess(
      current,
      { toolName: "bash", input: { command } },
      actor,
      await analyzeBash(command, process.env.PI_TEST_SHFMT || "shfmt"),
    );
  for (const command of [
    "rg --hidden --no-ignore SECRET .",
    "grep -R SECRET .",
    "grep --recursive SECRET .",
    "egrep -r SECRET .",
    "fgrep -r SECRET .",
    "rgrep SECRET .",
    "printf ok | rg --hidden SECRET .",
    "rg --file=.env .",
    "rg SECRET safe.txt",
  ]) {
    assert.equal((await decide(command)).decision, "ask", command);
  }
  assert.equal((await decide("rg SECRET .env")).decision, "deny");
  assert.equal((await decide("printf ok")).decision, "allow");
  assert.equal(
    (
      await decide("rg SECRET .", {
        ...searchPolicy,
        files: { rules: [] },
      })
    ).decision,
    "allow",
  );
  assert.equal(
    (
      await decide("rg SECRET .", {
        ...searchPolicy,
        files: { rules: [] },
        defaultRead: false,
      })
    ).decision,
    "ask",
  );
});
