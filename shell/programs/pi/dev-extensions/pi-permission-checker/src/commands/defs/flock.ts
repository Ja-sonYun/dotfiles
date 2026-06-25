import type { PathAccess } from "../../types.ts";
import { defineCommand, skipLeadingOptions } from "../helpers.ts";

// flock [opts] LOCKFILE -c <script> | flock [opts] LOCKFILE command [args...]
export default defineCommand(["flock"], (argv) => {
  const args = argv.slice(1);
  const start = skipLeadingOptions(
    args,
    new Set(["-w", "--timeout", "-E", "--conflict-exit-code"]),
  );
  const rest = args.slice(start);
  if (rest.length === 0) return { pathAccesses: [], nested: [] };
  const acc: PathAccess[] = [];
  const lockfile = rest[0];
  if (lockfile && lockfile !== "-") acc.push({ kind: "write", path: lockfile });
  const cmd = rest.slice(1);
  if (cmd[0] === "-c" && cmd[1] !== undefined)
    return { pathAccesses: acc, nested: [{ script: cmd[1] }] };
  return { pathAccesses: acc, nested: cmd.length ? [{ argv: cmd }] : [] };
});
