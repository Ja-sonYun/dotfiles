import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

const RSYNC_VALUE = new Set([
  "-e",
  "--rsh",
  "--exclude",
  "--include",
  "--exclude-from",
  "--include-from",
  "--files-from",
  "-T",
  "--temp-dir",
  "--compare-dest",
  "--copy-dest",
  "--link-dest",
  "--partial-dir",
  "--log-file",
  "--out-format",
  "--bwlimit",
  "--timeout",
  "--port",
  "--chmod",
]);

// rsync [opts] SRC... DEST — sources read, last operand (DEST) write. -r/-a → recursive.
export default defineCommand(["rsync"], (argv) => {
  const args = argv.slice(1);
  const recursive = args.some(
    (a) =>
      a === "--recursive" ||
      (a.startsWith("-") &&
        !a.startsWith("--") &&
        (a.includes("r") || a.includes("a"))),
  );
  const acc: PathAccess[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (
      (a === "--exclude-from" ||
        a === "--include-from" ||
        a === "--files-from") &&
      i + 1 < args.length
    ) {
      acc.push({ kind: "read", path: args[i + 1] });
    }
  }
  const { operands } = splitArgs(args, RSYNC_VALUE);
  if (operands.length >= 2) {
    for (const s of operands.slice(0, -1)) acc.push({ kind: "read", path: s });
    acc.push({ kind: "write", path: operands[operands.length - 1] });
  } else {
    for (const o of operands) acc.push({ kind: "read", path: o });
  }
  return { pathAccesses: acc, nested: [], search: { recursive } };
});
