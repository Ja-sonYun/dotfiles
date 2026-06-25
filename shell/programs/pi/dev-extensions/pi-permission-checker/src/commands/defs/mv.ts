import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs, targetDirectory } from "../helpers.ts";

// mv removes each source as well as creating the destination, so sources are writes too
// (a deny rule protecting a source path should still block moving/deleting it).
export default defineCommand(["mv"], (argv) => {
  const args = argv.slice(1);
  const { operands } = splitArgs(
    args,
    new Set(["-t", "--target-directory", "-S", "--suffix"]),
  );
  const dest = targetDirectory(args);
  const acc: PathAccess[] = [];
  if (dest !== undefined) {
    for (const o of operands) acc.push({ kind: "write", path: o });
    acc.push({ kind: "write", path: dest });
  } else if (operands.length >= 2) {
    for (const s of operands.slice(0, -1)) acc.push({ kind: "write", path: s });
    acc.push({ kind: "write", path: operands[operands.length - 1] });
  } else {
    for (const o of operands) acc.push({ kind: "write", path: o });
  }
  return { pathAccesses: acc, nested: [] };
});
