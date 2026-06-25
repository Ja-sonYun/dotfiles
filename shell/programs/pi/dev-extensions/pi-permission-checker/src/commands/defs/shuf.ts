import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

// shuf [opts] [FILE] — operand files read; `-o FILE`/`--output` is a write.
export default defineCommand(["shuf"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  let output: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === "-o" || a === "--output") && i + 1 < args.length)
      output = args[i + 1];
    else if (a.startsWith("--output=")) output = a.slice("--output=".length);
  }
  const { operands } = splitArgs(
    args,
    new Set([
      "-o",
      "--output",
      "-n",
      "--head-count",
      "-i",
      "--input-range",
      "--random-source",
    ]),
  );
  for (const f of operands) if (f !== "-") acc.push({ kind: "read", path: f });
  if (output && output !== "-") acc.push({ kind: "write", path: output });
  return { pathAccesses: acc, nested: [] };
});
