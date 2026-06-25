import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

const SORT_VALUE = new Set([
  "-o",
  "--output",
  "-k",
  "--key",
  "-t",
  "--field-separator",
  "-S",
  "--buffer-size",
  "-T",
  "--temporary-directory",
  "--files0-from",
]);

// Operand files are reads; `-o FILE`/`--output` is a write.
export default defineCommand(["sort"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  let output: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === "-o" || a === "--output") && i + 1 < args.length)
      output = args[i + 1];
    else if (a.startsWith("--output=")) output = a.slice("--output=".length);
    else if (a.startsWith("-o") && a.length > 2) output = a.slice(2);
  }
  const { operands } = splitArgs(args, SORT_VALUE);
  for (const f of operands) if (f !== "-") acc.push({ kind: "read", path: f });
  if (output && output !== "-") acc.push({ kind: "write", path: output });
  return { pathAccesses: acc, nested: [] };
});
