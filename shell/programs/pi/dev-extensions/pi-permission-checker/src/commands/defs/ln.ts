import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

// ln [opts] TARGET... LINK_NAME — the link name (last operand) is the write.
export default defineCommand(["ln"], (argv) => {
  const { operands } = splitArgs(
    argv.slice(1),
    new Set(["-S", "--suffix", "-t", "--target-directory"]),
  );
  const acc: PathAccess[] = [];
  if (operands.length >= 2)
    acc.push({ kind: "write", path: operands[operands.length - 1] });
  else for (const o of operands) acc.push({ kind: "write", path: o });
  return { pathAccesses: acc, nested: [] };
});
