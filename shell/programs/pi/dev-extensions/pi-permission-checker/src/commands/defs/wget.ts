import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// `-O FILE` writes the download; otherwise it writes into `-P PREFIX` (or the cwd).
// `-i FILE`/`--input-file` reads a list of URLs.
export default defineCommand(["wget"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  let explicitOut = false;
  let prefix: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === "-O" || a === "--output-document") && i + 1 < args.length) {
      acc.push({ kind: "write", path: args[++i] });
      explicitOut = true;
    } else if (a.startsWith("--output-document=")) {
      acc.push({ kind: "write", path: a.slice("--output-document=".length) });
      explicitOut = true;
    } else if ((a === "-i" || a === "--input-file") && i + 1 < args.length) {
      acc.push({ kind: "read", path: args[++i] });
    } else if (
      (a === "-P" || a === "--directory-prefix") &&
      i + 1 < args.length
    ) {
      prefix = args[++i];
    }
  }
  if (!explicitOut) acc.push({ kind: "write", path: prefix ?? "." });
  return { pathAccesses: acc, nested: [] };
});
