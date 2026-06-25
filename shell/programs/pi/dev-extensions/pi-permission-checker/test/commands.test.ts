import assert from "node:assert/strict";
import { test } from "node:test";
import { analyzeOne } from "../src/commands/index.ts";

function reads(argv: string[]): string[] {
  return analyzeOne(argv, "/repo")
    .pathAccesses.filter((a) => a.kind === "read")
    .map((a) => a.path);
}
function writes(argv: string[]): string[] {
  return analyzeOne(argv, "/repo")
    .pathAccesses.filter((a) => a.kind === "write")
    .map((a) => a.path);
}

test("awk: program is not a path, files are reads", () => {
  assert.deepEqual(reads(["awk", "-F,", "{print $1}", "a.csv", "b.csv"]), [
    "a.csv",
    "b.csv",
  ]);
});

test("awk -f: program file is read, no inline program dropped", () => {
  assert.deepEqual(reads(["awk", "-f", "prog.awk", "data.txt"]), [
    "prog.awk",
    "data.txt",
  ]);
});

test("jq: filter not a path; --arg skips two tokens; --slurpfile reads", () => {
  assert.deepEqual(
    reads(["jq", "--arg", "x", "1", "-f", "filter.jq", "data.json"]),
    ["filter.jq", "data.json"],
  );
  assert.deepEqual(
    reads(["jq", "--slurpfile", "d", "extra.json", ".", "in.json"]),
    ["extra.json", "in.json"],
  );
});

test("cut: delimiter/field values are not paths", () => {
  assert.deepEqual(reads(["cut", "-d", ":", "-f", "1", "/etc/passwd"]), [
    "/etc/passwd",
  ]);
});

test("diff -r marks a recursive search", () => {
  const r = analyzeOne(["diff", "-r", "a", "b"], "/repo");
  assert.deepEqual(r.search, { recursive: true });
  assert.deepEqual(r.pathAccesses, [
    { kind: "read", path: "a" },
    { kind: "read", path: "b" },
  ]);
});

test("sort -o is a write, operands are reads", () => {
  assert.deepEqual(reads(["sort", "-o", "out.txt", "in.txt"]), ["in.txt"]);
  assert.deepEqual(writes(["sort", "-o", "out.txt", "in.txt"]), ["out.txt"]);
});

test("dd if=/of= split reads and writes", () => {
  assert.deepEqual(reads(["dd", "if=/dev/sda", "of=disk.img", "bs=1M"]), [
    "/dev/sda",
  ]);
  assert.deepEqual(writes(["dd", "if=/dev/sda", "of=disk.img", "bs=1M"]), [
    "disk.img",
  ]);
});

test("chmod -R: operands are writes, mode is not a path", () => {
  assert.deepEqual(writes(["chmod", "-R", "755", "dir"]), ["dir"]);
});

test("install -t DEST: operands read, DEST write", () => {
  assert.deepEqual(
    reads(["install", "-m", "755", "-t", "/usr/bin", "a", "b"]),
    ["a", "b"],
  );
  assert.deepEqual(
    writes(["install", "-m", "755", "-t", "/usr/bin", "a", "b"]),
    ["/usr/bin"],
  );
});

test("rsync -a: sources read, dest write, recursive", () => {
  const r = analyzeOne(["rsync", "-a", "src/", "dst/"], "/repo");
  assert.deepEqual(r.pathAccesses, [
    { kind: "read", path: "src/" },
    { kind: "write", path: "dst/" },
  ]);
  assert.deepEqual(r.search, { recursive: true });
});

test("tar create: files read, archive write", () => {
  assert.deepEqual(writes(["tar", "-cf", "a.tar", "x", "y"]), ["a.tar"]);
  assert.deepEqual(reads(["tar", "-cf", "a.tar", "x", "y"]), ["x", "y"]);
});

test("tar extract (bundled xzf): archive read, extraction write to cwd", () => {
  assert.deepEqual(reads(["tar", "xzf", "a.tgz"]), ["a.tgz"]);
  assert.deepEqual(writes(["tar", "xzf", "a.tgz"]), ["."]);
});

test("tar extract -C dir writes into dir", () => {
  assert.deepEqual(writes(["tar", "-xzf", "a.tgz", "-C", "out"]), ["out"]);
});

test("unzip: archive read, default extract to cwd", () => {
  assert.deepEqual(reads(["unzip", "a.zip"]), ["a.zip"]);
  assert.deepEqual(writes(["unzip", "a.zip"]), ["."]);
  assert.deepEqual(writes(["unzip", "a.zip", "-d", "out"]), ["out"]);
});

test("gzip operands are writes (in-place)", () => {
  assert.deepEqual(writes(["gzip", "big.log"]), ["big.log"]);
});

test("curl -o / -O / -d @file", () => {
  assert.deepEqual(writes(["curl", "-o", "out.html", "https://x"]), [
    "out.html",
  ]);
  assert.deepEqual(writes(["curl", "-O", "https://x/f"]), ["."]);
  assert.deepEqual(reads(["curl", "-d", "@payload.json", "https://x"]), [
    "payload.json",
  ]);
});

test("wget -O writes the named file; default writes cwd", () => {
  assert.deepEqual(writes(["wget", "-O", "out", "https://x"]), ["out"]);
  assert.deepEqual(writes(["wget", "https://x/f"]), ["."]);
});

test("python script.py is a read", () => {
  assert.deepEqual(reads(["python", "script.py"]), ["script.py"]);
  assert.equal(
    analyzeOne(["python", "script.py"], "/repo").opaque ?? false,
    false,
  );
});

test("python -c is opaque (always-ask)", () => {
  const r = analyzeOne(["python3", "-c", "import os; os.system('x')"], "/repo");
  assert.equal(r.opaque, true);
  assert.deepEqual(r.pathAccesses, []);
});

test("eval and make are opaque", () => {
  assert.equal(analyzeOne(["eval", "rm -rf /"], "/repo").opaque, true);
  assert.equal(analyzeOne(["make", "install"], "/repo").opaque, true);
});

test("source reads the file and is opaque", () => {
  const r = analyzeOne(["source", "env.sh"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "read", path: "env.sh" }]);
  assert.equal(r.opaque, true);
});

test("base64/cmp/rev are reads", () => {
  assert.deepEqual(reads(["base64", "secret.bin"]), ["secret.bin"]);
  assert.deepEqual(reads(["cmp", "a", "b"]), ["a", "b"]);
  assert.deepEqual(reads(["rev", "f.txt"]), ["f.txt"]);
});

test("flock: lockfile write + nested command", () => {
  const r = analyzeOne(["flock", "/tmp/lock", "rm", "-rf", "x"], "/repo");
  assert.deepEqual(r.pathAccesses, [{ kind: "write", path: "/tmp/lock" }]);
  assert.deepEqual(r.nested, [{ argv: ["rm", "-rf", "x"] }]);
});

test("perl -e'code' (attached inline) is opaque", () => {
  assert.equal(analyzeOne(["perl", "-e'print 1'", "f"], "/repo").opaque, true);
});

test("versioned interpreter python3.11 -c is opaque", () => {
  assert.equal(analyzeOne(["python3.11", "-c", "x"], "/repo").opaque, true);
  assert.deepEqual(reads(["python3.12", "app.py"]), ["app.py"]);
});

test("eval re-parses its argument as a nested script and stays opaque", () => {
  const r = analyzeOne(["eval", "rm -rf build"], "/repo");
  assert.equal(r.opaque, true);
  assert.deepEqual(r.nested, [{ script: "rm -rf build" }]);
});

test("env -S surfaces the command line as a nested script", () => {
  assert.deepEqual(
    analyzeOne(["env", "-S", "cat secret.txt"], "/repo").nested,
    [{ script: "cat secret.txt" }],
  );
});

test("sudo skips env assignments before the command", () => {
  assert.deepEqual(analyzeOne(["sudo", "FOO=bar", "rm", "x"], "/repo").nested, [
    { argv: ["rm", "x"] },
  ]);
});

test("sudo -s (interactive shell) is opaque", () => {
  assert.equal(analyzeOne(["sudo", "-s"], "/repo").opaque, true);
});

test("tee -p does not swallow the file operand", () => {
  assert.deepEqual(writes(["tee", "-p", "log.txt"]), ["log.txt"]);
});

test("mv marks sources as writes (they are removed)", () => {
  assert.deepEqual(writes(["mv", "a", "b", "dest/"]), ["a", "b", "dest/"]);
});

test("install -d creates directories (all writes)", () => {
  assert.deepEqual(writes(["install", "-d", "/opt/a", "/opt/b"]), [
    "/opt/a",
    "/opt/b",
  ]);
});

test("xargs does not treat the embedded command's -a as arg-file", () => {
  const r = analyzeOne(["xargs", "cp", "-a", "src", "dst"], "/repo");
  assert.deepEqual(r.pathAccesses, []);
  assert.deepEqual(r.nested, [{ argv: ["cp", "-a", "src", "dst"] }]);
});

test("find -- terminates options before path operands", () => {
  assert.deepEqual(reads(["find", "--", "/srv/data", "-name", "x"]), [
    "/srv/data",
  ]);
});

test("awk -fprog (attached) reads the program file", () => {
  assert.deepEqual(reads(["awk", "-fprog.awk", "data.txt"]), [
    "prog.awk",
    "data.txt",
  ]);
});

test("rg --pre surfaces a nested preprocessor command; --ignore-file is a read", () => {
  const r = analyzeOne(
    ["rg", "--pre", "pdftotext", "--ignore-file", ".ignore", "term", "docs"],
    "/repo",
  );
  assert.ok(r.nested.some((n) => n.argv && n.argv[0] === "pdftotext"));
  assert.ok(
    r.pathAccesses.some((a) => a.kind === "read" && a.path === ".ignore"),
  );
  assert.ok(r.pathAccesses.some((a) => a.kind === "read" && a.path === "docs"));
});
