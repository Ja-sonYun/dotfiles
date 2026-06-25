import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// unzip [opts] ARCHIVE [members...] [-d EXDIR] — archive is read, extraction writes to -d (or cwd).
export default defineCommand(["unzip"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  let dir = ".";
  const operands: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-d" && i + 1 < args.length) {
      dir = args[++i];
      continue;
    }
    if (a.startsWith("-")) continue;
    operands.push(a);
  }
  if (operands.length > 0 && operands[0] !== "-")
    acc.push({ kind: "read", path: operands[0] });
  acc.push({ kind: "write", path: dir });
  return { pathAccesses: acc, nested: [] };
});
