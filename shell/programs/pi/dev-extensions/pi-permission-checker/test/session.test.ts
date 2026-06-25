import assert from "node:assert/strict";
import { test } from "node:test";
import { buildConfig } from "../src/config.ts";
import { evaluate } from "../src/evaluator.ts";
import * as session from "../src/session.ts";
import type { Request } from "../src/types.ts";

function req(partial: Partial<Request>): Request {
  return {
    tool: "bash",
    units: [],
    accesses: [],
    cwd: "/repo",
    isSearch: false,
    searchRecursive: false,
    opaque: false,
    ...partial,
  };
}

const askAll = buildConfig({ defaultMode: "ask", permissions: {} });

test("session file-scope allow covers only that file", () => {
  session.clear();
  session.add({
    decision: "allow",
    scope: "path",
    pathKind: "file",
    base: session.pathBase("/repo/a.txt", "/repo", "file"),
    access: "read",
  });
  assert.equal(
    evaluate(
      req({ tool: "read", accesses: [{ kind: "read", path: "/repo/a.txt" }] }),
      askAll,
    ).decision,
    "allow",
  );
  assert.equal(
    evaluate(
      req({ tool: "read", accesses: [{ kind: "read", path: "/repo/b.txt" }] }),
      askAll,
    ).decision,
    "ask",
  );
});

test("session dir-scope allow covers files under the directory", () => {
  session.clear();
  session.add({
    decision: "allow",
    scope: "path",
    pathKind: "dir",
    base: session.pathBase("/repo/sub/a.txt", "/repo", "dir"),
    access: "edit",
  });
  assert.equal(
    evaluate(
      req({
        tool: "edit",
        accesses: [{ kind: "edit", path: "/repo/sub/b.txt" }],
      }),
      askAll,
    ).decision,
    "allow",
  );
  assert.equal(
    evaluate(
      req({
        tool: "edit",
        accesses: [{ kind: "edit", path: "/repo/other/c.txt" }],
      }),
      askAll,
    ).decision,
    "ask",
  );
});

test("read-scoped session allow does NOT cover a later write to the same path", () => {
  session.clear();
  session.add({
    decision: "allow",
    scope: "path",
    pathKind: "file",
    base: session.pathBase("/repo/a.txt", "/repo", "file"),
    access: "read",
  });
  assert.equal(
    evaluate(
      req({ tool: "read", accesses: [{ kind: "read", path: "/repo/a.txt" }] }),
      askAll,
    ).decision,
    "allow",
  );
  assert.equal(
    evaluate(
      req({
        tool: "write",
        accesses: [{ kind: "write", path: "/repo/a.txt" }],
      }),
      askAll,
    ).decision,
    "ask",
  );
});

test("path-scoped session allow does NOT authorize an unrelated bash command unit", () => {
  session.clear();
  // User approved reading allowed.txt for the session...
  session.add({
    decision: "allow",
    scope: "path",
    pathKind: "file",
    base: session.pathBase("/repo/allowed.txt", "/repo", "file"),
    access: "read",
  });
  // ...but `cat allowed.txt && curl evil` carries an uncovered `curl` unit, so it must still ask.
  const r = evaluate(
    req({
      commandText: "cat allowed.txt && curl evil",
      units: [{ argv: ["cat", "allowed.txt"] }, { argv: ["curl", "evil"] }],
      accesses: [{ kind: "read", path: "/repo/allowed.txt" }],
    }),
    askAll,
  );
  assert.equal(r.decision, "ask");
});

test("session deny is remembered and beats config allow", () => {
  session.clear();
  const config = buildConfig({ permissions: { allow: ["bash(*)"] } });
  session.add({ decision: "deny", scope: "command", command: "rm -rf build" });
  assert.equal(
    evaluate(
      req({
        commandText: "rm -rf build",
        units: [{ argv: ["rm", "-rf", "build"] }],
      }),
      config,
    ).decision,
    "deny",
  );
});

test("wildcard allow covers matching units only", () => {
  session.clear();
  session.add({ decision: "allow", scope: "wildcard", tokens: ["echo", "**"] });
  assert.equal(
    evaluate(
      req({ commandText: "echo bye", units: [{ argv: ["echo", "bye"] }] }),
      askAll,
    ).decision,
    "allow",
  );
  // a compound command with an uncovered unit still asks
  assert.equal(
    evaluate(
      req({
        commandText: "echo a; rm b",
        units: [{ argv: ["echo", "a"] }, { argv: ["rm", "b"] }],
      }),
      askAll,
    ).decision,
    "ask",
  );
});

test("clear() resets session decisions", () => {
  session.clear();
  session.add({ decision: "allow", scope: "tool", tool: "bash" });
  assert.equal(
    evaluate(req({ commandText: "anything" }), askAll).decision,
    "allow",
  );
  session.clear();
  assert.equal(
    evaluate(req({ commandText: "anything" }), askAll).decision,
    "ask",
  );
});
