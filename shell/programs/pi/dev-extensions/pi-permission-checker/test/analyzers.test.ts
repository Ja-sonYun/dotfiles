import assert from "node:assert/strict";
import { test } from "node:test";
import { analyzeOne } from "../src/commands/index.ts";

test("cat marks operands as read", () => {
  const r = analyzeOne(["cat", "a.txt", "b.txt"], "/repo");
  assert.deepEqual(r.pathAccesses, [
    { kind: "read", path: "a.txt" },
    { kind: "read", path: "b.txt" },
  ]);
});

test("cp: sources read, last operand write", () => {
  const r = analyzeOne(["cp", "src.txt", "dst.txt"], "/repo");
  assert.deepEqual(r.pathAccesses, [
    { kind: "read", path: "src.txt" },
    { kind: "write", path: "dst.txt" },
  ]);
});

test("sed -i marks target as edit; first operand (script) is not a path", () => {
  const r = analyzeOne(["sed", "-i", "s/a/b/", "file.txt"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "edit", path: "file.txt" }]);
});

test("sed without -i marks files as read", () => {
  const r = analyzeOne(["sed", "s/a/b/", "file.txt"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "file.txt" }]);
});

test("sed -i.bak (suffix) still detected as in-place", () => {
  const r = analyzeOne(["sed", "-i.bak", "s/a/b/", "f"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "edit", path: "f" }]);
});

test("find: roots are read, -exec yields nested command", () => {
  const r = analyzeOne(
    ["find", "src", "-name", "*.ts", "-exec", "rm", "{}", ";"],
    "/repo",
  );
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "src" }]);
  assert.deepEqual(r.nested, [{ argv: ["rm"] }]);
  assert.deepEqual(r.search, { recursive: true });
});

test("find -delete marks roots as write", () => {
  const r = analyzeOne(["find", ".", "-name", "*.tmp", "-delete"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "write", path: "." }]);
});

test("xargs surfaces the embedded command", () => {
  const r = analyzeOne(["xargs", "-I", "{}", "rm", "{}"], "/repo");
  assert.deepEqual(r.nested, [{ argv: ["rm"] }]);
});

test("sh -c surfaces the script for re-parsing", () => {
  const r = analyzeOne(["sh", "-c", "rm bar"], "/repo");
  assert.deepEqual(r.nested, [{ script: "rm bar" }]);
});

test("sudo wrapper surfaces the wrapped command", () => {
  const r = analyzeOne(["sudo", "-u", "root", "rm", "-rf", "/x"], "/repo");
  assert.deepEqual(r.nested, [{ argv: ["rm", "-rf", "/x"] }]);
});

test("grep -r is recursive and treats files as read", () => {
  const r = analyzeOne(["grep", "-r", "pat", "src"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "src" }]);
  assert.deepEqual(r.search, { recursive: true });
});

test("find global options before paths are skipped", () => {
  const r = analyzeOne(["find", "-L", "/tmp", "-name", "x"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "/tmp" }]);
});

test("BSD sed -i with separate '' suffix does not treat the script as a path", () => {
  const r = analyzeOne(["sed", "-i", "", "s/a/b/", "file.txt"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "edit", path: "file.txt" }]);
});

test("grep -f reads the pattern file from disk", () => {
  const r = analyzeOne(["grep", "-f", "secrets/patterns.txt", "src"], "/repo");
  assert.ok(
    r.pathAccesses.some(
      (a) => a.kind === "read" && a.path === "secrets/patterns.txt",
    ),
  );
});

test("cp -t DEST treats DEST as write and operands as reads", () => {
  const r = analyzeOne(["cp", "-t", "dest", "a", "b"], "/repo");
  assert.deepEqual(r.pathAccesses, [
    { kind: "read", path: "a" },
    { kind: "read", path: "b" },
    { kind: "write", path: "dest" },
  ]);
});

test("bash -lc combined cluster surfaces the script", () => {
  const r = analyzeOne(["bash", "-lc", "rm secret"], "/repo");
  assert.deepEqual(r.nested, [{ script: "rm secret" }]);
});

test("bare shell (stdin/interactive) is opaque", () => {
  assert.equal(analyzeOne(["bash"], "/repo").opaque, true);
  assert.equal(analyzeOne(["sh"], "/repo").opaque, true);
  // a script-file invocation is not opaque (the file is a read)
  const r = analyzeOne(["bash", "script.sh"], "/repo");
  assert.equal(r.opaque ?? false, false);
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "script.sh" }]);
});

test("env -i with options before assignments still finds the command", () => {
  const r = analyzeOne(["env", "-i", "FOO=bar", "rm", "x"], "/repo");
  assert.deepEqual(r.nested, [{ argv: ["rm", "x"] }]);
});

test("unknown command yields no path guesses", () => {
  const r = analyzeOne(["frobnicate", "whatever"], "/repo");
  assert.deepEqual(r.pathAccesses, []);
  assert.deepEqual(r.nested, []);
});
