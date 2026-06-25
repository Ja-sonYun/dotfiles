import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

// split/csplit [opts] [INPUT [PREFIX]] — input read, output prefix write.
export default defineCommand(["split", "csplit"], (argv) => {
  const { operands } = splitArgs(
    argv.slice(1),
    new Set([
      "-b",
      "-l",
      "-n",
      "-a",
      "--bytes",
      "--lines",
      "--number",
      "--suffix-length",
      "--additional-suffix",
      "-f",
      "-k",
      "-p",
    ]),
  );
  const acc: PathAccess[] = [];
  if (operands[0] && operands[0] !== "-")
    acc.push({ kind: "read", path: operands[0] });
  if (operands[1]) acc.push({ kind: "write", path: operands[1] });
  return { pathAccesses: acc, nested: [] };
});
