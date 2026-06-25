import type { PathAccess } from "../../types.ts";
import { basename, defineCommand, splitArgs } from "../helpers.ts";

const GREP_VALUE = new Set([
  "-e",
  "-f",
  "-m",
  "-A",
  "-B",
  "-C",
  "-d",
  "--regexp",
  "--file",
  "--max-count",
  "--include",
  "--exclude",
  "--exclude-dir",
  "--include-from",
  "--exclude-from",
  "--color",
  "--colour",
]);

// `-f`/`--file`/`--include-from`/`--exclude-from` read a file from disk.
function fileFlagReads(args: string[]): PathAccess[] {
  const acc: PathAccess[] = [];
  const named = new Set(["-f", "--file", "--include-from", "--exclude-from"]);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (named.has(a) && i + 1 < args.length)
      acc.push({ kind: "read", path: args[i + 1] });
    else if (a.startsWith("--file="))
      acc.push({ kind: "read", path: a.slice("--file=".length) });
    else if (a.startsWith("-f") && a.length > 2)
      acc.push({ kind: "read", path: a.slice(2) });
  }
  return acc;
}

export default defineCommand(["grep", "egrep", "fgrep", "rgrep"], (argv) => {
  const name = basename(argv[0] ?? "");
  const args = argv.slice(1);
  const recursive =
    name === "rgrep" ||
    args.some((a) => a === "--recursive" || /^-[A-Za-z]*[rR]/.test(a));
  const usedPatternFlag = args.some((a) => /^(-e|--regexp|-f|--file)/.test(a));
  const { operands } = splitArgs(args, GREP_VALUE);
  let files = operands;
  if (!usedPatternFlag && files.length > 0) files = files.slice(1); // drop pattern
  const acc = [
    ...files
      .filter((f) => f !== "-")
      .map((f) => ({ kind: "read" as const, path: f })),
    ...fileFlagReads(args),
  ];
  if (recursive && files.length === 0) acc.push({ kind: "read", path: "." });
  return { pathAccesses: acc, nested: [], search: { recursive } };
});
