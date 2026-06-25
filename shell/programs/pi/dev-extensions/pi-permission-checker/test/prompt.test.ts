import assert from "node:assert/strict";
import { test } from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { buildConfig } from "../src/config.ts";
import { askUser, type PromptUi } from "../src/prompt.ts";
import * as session from "../src/session.ts";
import type { CommandUnit, Request } from "../src/types.ts";

const config = buildConfig({ defaultMode: "ask", permissions: {} });

/** A scripted UI: returns the queued answer for each select() call and records titles. */
function fakeUi(answers: string[]): PromptUi & { titles: string[] } {
  const titles: string[] = [];
  let i = 0;
  return {
    titles,
    async select(title: string) {
      titles.push(title);
      return answers[i++];
    },
    async input() {
      return "nope";
    },
  };
}

function pipelineReq(): Request {
  const command = "git ls-files | rg x | head -200";
  const units: CommandUnit[] = [
    { argv: ["git", "ls-files"], range: [0, 12] },
    { argv: ["rg", "x"], range: [15, 19] },
    { argv: ["head", "-200"], range: [22, 31] },
  ];
  return {
    tool: "bash",
    commandText: command,
    units,
    accesses: [],
    cwd: "/repo",
    isSearch: false,
    searchRecursive: false,
    opaque: false,
  };
}

function findSortReq(): Request {
  const command = "find /repo/sub/a /repo/sub/b -type f | sort";
  return {
    tool: "bash",
    commandText: command,
    units: [
      {
        argv: ["find", "/repo/sub/a", "/repo/sub/b", "-type", "f"],
        range: [0, 38],
      },
      { argv: ["sort"], range: [41, 45] },
    ],
    accesses: [
      { kind: "read", path: "/repo/sub/a" },
      { kind: "read", path: "/repo/sub/b" },
    ],
    cwd: "/repo",
    isSearch: true,
    searchRecursive: true,
    opaque: false,
  };
}

test("review asks each accessed path first, then each command", async () => {
  session.clear();
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes (allow once)",
    "Yes (allow once)",
    "Yes (allow once)",
    "Yes (allow once)",
  ]);
  const res = await askUser(ui, findSortReq(), config);
  assert.deepEqual(res, {});
  assert.equal(ui.titles.length, 5); // overview + 2 paths + 2 commands
  assert.match(ui.titles[1], /path 1\/2/);
  assert.match(ui.titles[1], /\/repo\/sub\/a/);
  assert.match(ui.titles[2], /path 2\/2/);
  assert.match(ui.titles[2], /\/repo\/sub\/b/);
  assert.match(ui.titles[3], /command 1\/2/);
  assert.match(ui.titles[4], /command 2\/2/);
});

test("approving a directory for the session skips sibling paths under it", async () => {
  session.clear();
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes, allow this directory for the session",
    "Yes (allow once)",
    "Yes (allow once)",
  ]);
  const res = await askUser(ui, findSortReq(), config);
  assert.deepEqual(res, {});
  // overview + path a (approve dir) + [path b skipped — covered] + 2 commands = 4
  assert.equal(ui.titles.length, 4);
  assert.match(ui.titles[1], /path 1\/2/);
  assert.match(ui.titles[2], /command 1\/2/); // straight to commands; path b was skipped
  assert.ok(
    session.all().some((e) => e.scope === "path" && e.pathKind === "dir"),
  );
});

test("a deny on a path short-circuits before any command is shown", async () => {
  session.clear();
  const ui = fakeUi(["Review & decide one by one", "No (deny once)"]);
  const res = await askUser(ui, findSortReq(), config);
  assert.equal(res.block, true);
  assert.equal(ui.titles.length, 2); // overview + first path only
});

test("multi-command bash shows an overview first listing every command", async () => {
  session.clear();
  const ui = fakeUi(["Allow all (once)"]);
  const res = await askUser(ui, pipelineReq(), config);
  assert.deepEqual(res, {});
  assert.equal(ui.titles.length, 1); // only the overview, no per-command prompts
  assert.match(ui.titles[0], /3 commands in this bash line/);
  assert.match(ui.titles[0], /git ls-files/);
  assert.match(ui.titles[0], /rg x/);
  assert.match(ui.titles[0], /head -200/);
});

test("overview 'Allow all for the session' records a wildcard per command and allows", async () => {
  session.clear();
  const ui = fakeUi(["Allow all for the session"]);
  const res = await askUser(ui, pipelineReq(), config);
  assert.deepEqual(res, {});
  assert.equal(ui.titles.length, 1); // overview only
  const wc = session.all().filter((e) => e.scope === "wildcard");
  assert.deepEqual(
    wc.map((e) => (e as { tokens: string[] }).tokens),
    [
      ["git", "ls-files"],
      ["rg", "x"],
      ["head", "-200"],
    ],
  );
});

test("overview 'Deny all' blocks with a single prompt", async () => {
  session.clear();
  const ui = fakeUi(["Deny all"]);
  const res = await askUser(ui, pipelineReq(), config);
  assert.equal(res.block, true);
  assert.equal(ui.titles.length, 1);
});

test("'Review one by one' drops into per-command prompts, highlighting each", async () => {
  session.clear();
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes (allow once)",
    "Yes (allow once)",
    "Yes (allow once)",
  ]);
  const res = await askUser(ui, pipelineReq(), config);
  assert.deepEqual(res, {});
  assert.equal(ui.titles.length, 4); // overview + 3 commands
  assert.match(ui.titles[1], /command 1\/3/);
  // the highlighted unit is wrapped in ANSI color codes, not literal markers
  assert.ok(ui.titles[1].includes("\x1b[1;7mgit ls-files\x1b[0m"));
  assert.ok(ui.titles[2].includes("\x1b[1;7mrg x\x1b[0m"));
  assert.ok(ui.titles[3].includes("\x1b[1;7mhead -200\x1b[0m"));
  assert.doesNotMatch(ui.titles[1], /‹‹|››/);
  // the full command is shown in each per-command prompt, not just the highlighted unit
  assert.match(ui.titles[2], /git ls-files .* head -200/);
});

test("a deny during review short-circuits and blocks the whole line", async () => {
  session.clear();
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes (allow once)",
    "No (deny once)",
  ]);
  const res = await askUser(ui, pipelineReq(), config);
  assert.equal(res.block, true);
  assert.equal(ui.titles.length, 3); // overview + 2 commands; third never prompted
});

test("per-command 'allow for session' records a wildcard for that unit's argv", async () => {
  session.clear();
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes, allow this command for the session",
    "Yes, allow this command for the session",
    "Yes, allow this command for the session",
  ]);
  await askUser(ui, pipelineReq(), config);
  const wc = session.all().filter((e) => e.scope === "wildcard");
  assert.equal(wc.length, 3);
  assert.deepEqual(
    wc.map((e) => (e as { tokens: string[] }).tokens),
    [
      ["git", "ls-files"],
      ["rg", "x"],
      ["head", "-200"],
    ],
  );
});

test("an AI explanation is shown atop the prompt when provided", async () => {
  session.clear();
  const ui = fakeUi(["Allow all (once)"]);
  await askUser(ui, pipelineReq(), config, "• reads files\n• no network");
  assert.match(ui.titles[0], /What this script does \(AI\):/);
  assert.match(ui.titles[0], /reads files/);
  // the command overview still follows the explanation
  assert.match(ui.titles[0], /3 commands in this bash line/);
});

test("a single bash command lists the files/directories it accesses", async () => {
  session.clear();
  const ui = fakeUi(["Yes (allow once)"]);
  const req: Request = {
    tool: "bash",
    commandText: "rg pat llm_api_gateway terraform",
    units: [
      { argv: ["rg", "pat", "llm_api_gateway", "terraform"], range: [0, 32] },
    ],
    accesses: [
      { kind: "read", path: "llm_api_gateway" },
      { kind: "read", path: "terraform" },
    ],
    cwd: "/repo",
    isSearch: true,
    searchRecursive: true,
    opaque: false,
  };
  await askUser(ui, req, config);
  assert.match(ui.titles[0], /Accesses:/);
  assert.match(ui.titles[0], /read +llm_api_gateway/);
  assert.match(ui.titles[0], /read +terraform/);
});

test("highlighted command line stays within display-column budget for CJK/emoji", async () => {
  session.clear();
  const head = "cat 重要な日本語ファイル.txt";
  const tail =
    ' | grep -n "とても長い日本語の検索パターンをここに入れて幅を超えさせる日本語日本語日本語🚀🚀🚀"';
  const command = head + tail;
  const sep = command.indexOf(" | ");
  const req: Request = {
    tool: "bash",
    commandText: command,
    units: [
      { argv: ["cat", "重要な日本語ファイル.txt"], range: [0, head.length] },
      { argv: ["grep", "-n", "…"], range: [sep + 3, command.length] },
    ],
    accesses: [],
    cwd: "/repo",
    isSearch: false,
    searchRecursive: false,
    opaque: false,
  };
  const ui = fakeUi([
    "Review & decide one by one",
    "Yes (allow once)",
    "Yes (allow once)",
  ]);
  await askUser(ui, req, config);

  const cols = (process.stdout as { columns?: number }).columns;
  const budget = Math.max(
    20,
    (typeof cols === "number" && cols > 0 ? cols : 80) - 4,
  );
  const line = ui.titles[1].split("\n").pop() ?? "";
  assert.ok(
    visibleWidth(line) <= budget,
    `line width ${visibleWidth(line)} exceeds budget ${budget}`,
  );
  assert.ok(line.includes("\x1b[1;7mcat 重要な日本語ファイル.txt\x1b[0m"));
  assert.match(line, /…/);
});

test("single-command bash uses one combined dialog (no per-unit loop)", async () => {
  session.clear();
  const ui = fakeUi(["Yes (allow once)"]);
  const req: Request = {
    tool: "bash",
    commandText: "rm file",
    units: [{ argv: ["rm", "file"], range: [0, 7] }],
    accesses: [],
    cwd: "/repo",
    isSearch: false,
    searchRecursive: false,
    opaque: false,
  };
  const res = await askUser(ui, req, config);
  assert.deepEqual(res, {});
  assert.equal(ui.titles.length, 1);
  assert.doesNotMatch(ui.titles[0], /command 1\//);
});
