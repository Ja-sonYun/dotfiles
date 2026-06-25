import assert from "node:assert/strict";
import { test } from "node:test";
import { buildConfig, parseRule } from "../src/config.ts";

test("ArgRegex is dropped from allow/ask but kept in deny", () => {
  const config = buildConfig({
    permissions: {
      allow: ["ArgRegex(.*)", "read"],
      ask: ["ArgRegex(.*)"],
      deny: ["ArgRegex(secret)"],
    },
  });
  assert.ok(!config.allow.some((r) => r.kind === "argRegex"));
  assert.ok(!config.ask.some((r) => r.kind === "argRegex"));
  assert.ok(config.deny.some((r) => r.kind === "argRegex"));
});

test("unknown / misspelled tool rules are rejected", () => {
  assert.equal(parseRule("bsh(argv:rm **)"), undefined);
  assert.equal(parseRule("notatool"), undefined);
  assert.deepEqual(parseRule("read"), { kind: "tool", tool: "read" });
});

test("argv: is only valid for bash", () => {
  assert.equal(parseRule("read(argv:cat **)"), undefined);
  assert.deepEqual(parseRule("bash(argv:rm -rf **)"), {
    kind: "bashArgv",
    tokens: ["rm", "-rf", "**"],
  });
});

test("invalid / misplaced rules are recorded in invalidRules", () => {
  const config = buildConfig({
    permissions: {
      allow: ["ArgRegex(.*)", "read"],
      deny: ["bsh(argv:rm **)", "Path(**/.env*)"],
    },
    wildcardable: ["read"],
  });
  assert.ok(config.invalidRules.some((r) => r.includes("ArgRegex")));
  assert.ok(config.invalidRules.some((r) => r.includes("bsh(argv:rm **)")));
  assert.ok(config.invalidRules.some((r) => r.includes("wildcardable")));
  // valid rules still parsed
  assert.ok(config.deny.some((r) => r.kind === "path"));
});

test("wildcardable parses bash argv patterns only", () => {
  const config = buildConfig({
    wildcardable: ["bash(argv:echo **)", "read", "Path(x)"],
  });
  assert.equal(config.wildcardable.length, 1);
  assert.deepEqual(config.wildcardable[0], ["echo", "**"]);
});
