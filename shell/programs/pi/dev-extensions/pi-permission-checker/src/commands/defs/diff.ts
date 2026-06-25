import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

const DIFF_VALUE = new Set([
  "-S",
  "--starting-file",
  "-X",
  "--exclude-from",
  "-D",
  "--ifdef",
  "--from-file",
  "--to-file",
  "-W",
  "--width",
  "--label",
]);

// Operand files are reads; `-r`/`--recursive` makes it a recursive search.
export default defineCommand(["diff", "colordiff"], (argv) => {
  const args = argv.slice(1);
  const recursive = args.some(
    (a) =>
      a === "--recursive" ||
      (a.startsWith("-") && !a.startsWith("--") && a.includes("r")),
  );
  const acc: PathAccess[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--exclude-from" && i + 1 < args.length)
      acc.push({ kind: "read", path: args[i + 1] });
  }
  const { operands } = splitArgs(args, DIFF_VALUE);
  for (const f of operands) if (f !== "-") acc.push({ kind: "read", path: f });
  return { pathAccesses: acc, nested: [], search: { recursive } };
});
