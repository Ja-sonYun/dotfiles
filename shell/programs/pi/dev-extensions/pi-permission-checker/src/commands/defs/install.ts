import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs, srcDestCmd } from "../helpers.ts";

const INSTALL_VALUE = [
  "-m",
  "--mode",
  "-o",
  "--owner",
  "-g",
  "--group",
  "-t",
  "--target-directory",
  "--strip-program",
  "-S",
  "--suffix",
];

// `install -d DIR...` creates directories (all operands are writes). Otherwise it copies
// sources to a destination (srcDest semantics, incl. `-t DEST`).
export default defineCommand(["install"], (argv, cwd) => {
  const args = argv.slice(1);
  if (args.some((a) => a === "-d" || a === "--directory")) {
    const { operands } = splitArgs(args, new Set(INSTALL_VALUE));
    const acc: PathAccess[] = operands.map((o) => ({ kind: "write", path: o }));
    return { pathAccesses: acc, nested: [] };
  }
  return srcDestCmd(INSTALL_VALUE, { targetDir: true })(argv, cwd);
});
