import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

const EXEC_FLAGS = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

// Leading paths are search roots (read; write if -delete). -exec/-execdir/-ok/-okdir
// command groups are nested commands.
export default defineCommand(["find"], (argv) => {
  const args = argv.slice(1);
  const nested: { argv: string[] }[] = [];

  // Global options precede the path operands: -H/-L/-P (no arg), -D arg, -O<n>.
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === "-H" || a === "-L" || a === "-P") i += 1;
    else if (a === "-D") i += 2;
    else if (a.startsWith("-O")) i += 1;
    else break;
  }

  if (args[i] === "--") i++; // end-of-options marker before path operands
  const roots: string[] = [];
  while (i < args.length) {
    const a = args[i];
    if (a.startsWith("-") || a === "(" || a === ")" || a === "!" || a === ",")
      break;
    roots.push(a);
    i++;
  }
  if (roots.length === 0) roots.push(".");

  let deletes = false;
  for (; i < args.length; i++) {
    const a = args[i];
    if (a === "-delete") {
      deletes = true;
    } else if (EXEC_FLAGS.has(a)) {
      const cmd: string[] = [];
      i++;
      while (i < args.length && args[i] !== ";" && args[i] !== "+") {
        cmd.push(args[i]);
        i++;
      }
      const cleaned = cmd.filter((t) => t !== "{}");
      if (cleaned.length) nested.push({ argv: cleaned });
    }
  }

  const acc: PathAccess[] = roots.map((r) => ({
    kind: deletes ? "write" : "read",
    path: r,
  }));
  return { pathAccesses: acc, nested, search: { recursive: true } };
});
