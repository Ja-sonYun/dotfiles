import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// dd if=SRC of=DEST — if= is a read, of= is a write.
export default defineCommand(["dd"], (argv) => {
  const acc: PathAccess[] = [];
  for (const a of argv.slice(1)) {
    if (a.startsWith("if=")) {
      const p = a.slice(3);
      if (p && p !== "/dev/stdin" && p !== "-")
        acc.push({ kind: "read", path: p });
    } else if (a.startsWith("of=")) {
      const p = a.slice(3);
      if (p && p !== "/dev/stdout" && p !== "-")
        acc.push({ kind: "write", path: p });
    }
  }
  return { pathAccesses: acc, nested: [] };
});
