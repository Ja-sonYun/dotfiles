import type { PathAccess } from "../../types.ts";
import { defineCommand, skipLeadingOptions } from "../helpers.ts";

const XARGS_VALUE = new Set([
  "-I",
  "-i",
  "-n",
  "-L",
  "-l",
  "-P",
  "-d",
  "-E",
  "-s",
  "-a",
  "--max-args",
  "--max-lines",
  "--max-procs",
  "--delimiter",
  "--replace",
  "--arg-file",
]);

// `-a FILE`/`--arg-file` reads input from a file. Everything from the first non-option
// token on is the embedded command, verbatim (incl. its own flags, e.g. `xargs rm -rf`).
export default defineCommand(["xargs"], (argv) => {
  const args = argv.slice(1);
  const start = skipLeadingOptions(args, XARGS_VALUE);
  // Only scan xargs's own options (before the embedded command) for -a/--arg-file.
  const acc: PathAccess[] = [];
  for (let i = 0; i < start; i++) {
    if ((args[i] === "-a" || args[i] === "--arg-file") && i + 1 < start) {
      acc.push({ kind: "read", path: args[i + 1] });
    } else if (args[i].startsWith("--arg-file=")) {
      acc.push({ kind: "read", path: args[i].slice("--arg-file=".length) });
    }
  }
  const cmd = args.slice(start).filter((t) => t !== "{}");
  return { pathAccesses: acc, nested: cmd.length ? [{ argv: cmd }] : [] };
});
