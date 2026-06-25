import assert from "node:assert/strict";
import { mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  matchPathGlob,
  pathGlobToRegExp,
  simpleGlobToRegExp,
  tokenGlobMatch,
} from "../src/paths.ts";

test("pathGlobToRegExp: **/ matches zero or more leading directories", () => {
  const re = pathGlobToRegExp("**/.env*");
  assert.ok(re.test(".env"));
  assert.ok(re.test(".env.local"));
  assert.ok(re.test("dir/.env"));
  assert.ok(re.test("a/b/c/.env.production"));
  assert.ok(!re.test("env"));
});

test("pathGlobToRegExp: * stays within a path segment", () => {
  const re = pathGlobToRegExp("src/*.ts");
  assert.ok(re.test("src/main.ts"));
  assert.ok(!re.test("src/nested/main.ts"));
});

test("simpleGlobToRegExp: * spans anything", () => {
  assert.ok(simpleGlobToRegExp("git status *").test("git status -s"));
  assert.ok(simpleGlobToRegExp("-i*").test("-i.bak"));
});

test("tokenGlobMatch: ** is zero+ tokens, * is exactly one", () => {
  assert.ok(tokenGlobMatch(["rm", "**"], ["rm"]));
  assert.ok(tokenGlobMatch(["rm", "**"], ["rm", "-rf", "/tmp/x"]));
  assert.ok(
    tokenGlobMatch(["sed", "**", "-i*", "**"], ["sed", "-n", "-i.bak", "f"]),
  );
  assert.ok(tokenGlobMatch(["echo", "*"], ["echo", "hi"]));
  assert.ok(!tokenGlobMatch(["echo", "*"], ["echo", "hi", "bye"]));
});

test("matchPathGlob resolves symlinks (realpath)", () => {
  const dir = mkdtempSync(join(tmpdir(), "perm-"));
  const real = join(dir, "secret.env");
  writeFileSync(real, "x");
  const link = join(dir, "link.txt");
  symlinkSync(real, link);
  // The literal link path doesn't look denied, but it resolves to *.env.
  assert.ok(matchPathGlob("**/*.env", link, dir));
});
