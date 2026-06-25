import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// zip [opts] ARCHIVE files... — the archive (first operand) is written, the rest are read.
export default defineCommand(["zip"], (argv) => {
  const operands = argv.slice(1).filter((a) => !a.startsWith("-"));
  const acc: PathAccess[] = [];
  if (operands.length > 0) {
    acc.push({ kind: "write", path: operands[0] });
    for (const o of operands.slice(1)) acc.push({ kind: "read", path: o });
  }
  return { pathAccesses: acc, nested: [] };
});
