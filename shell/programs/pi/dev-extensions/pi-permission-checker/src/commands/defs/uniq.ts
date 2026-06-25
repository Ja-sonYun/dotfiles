import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

// uniq [opts] [INPUT [OUTPUT]] — first operand read, optional second operand write.
export default defineCommand(["uniq"], (argv) => {
  const { operands } = splitArgs(
    argv.slice(1),
    new Set([
      "-f",
      "-s",
      "-w",
      "--skip-fields",
      "--skip-chars",
      "--check-chars",
    ]),
  );
  const acc: PathAccess[] = [];
  if (operands[0] && operands[0] !== "-")
    acc.push({ kind: "read", path: operands[0] });
  if (operands[1] && operands[1] !== "-")
    acc.push({ kind: "write", path: operands[1] });
  return { pathAccesses: acc, nested: [] };
});
