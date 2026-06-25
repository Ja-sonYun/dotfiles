import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// `-o FILE`/`-O` write the response; `-T FILE` uploads (read); `-d @FILE`/`-K FILE` read.
export default defineCommand(["curl"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  const dataFlags = new Set([
    "-d",
    "--data",
    "--data-binary",
    "--data-raw",
    "--data-ascii",
    "--data-urlencode",
  ]);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === "-o" || a === "--output") && i + 1 < args.length)
      acc.push({ kind: "write", path: args[++i] });
    else if (a === "-O" || a === "--remote-name")
      acc.push({ kind: "write", path: "." });
    else if ((a === "-T" || a === "--upload-file") && i + 1 < args.length) {
      const f = args[++i];
      if (f !== "-") acc.push({ kind: "read", path: f });
    } else if ((a === "-K" || a === "--config") && i + 1 < args.length) {
      acc.push({ kind: "read", path: args[++i] });
    } else if (dataFlags.has(a) && i + 1 < args.length) {
      const v = args[++i];
      if (v.startsWith("@")) acc.push({ kind: "read", path: v.slice(1) });
    }
  }
  return { pathAccesses: acc, nested: [] };
});
