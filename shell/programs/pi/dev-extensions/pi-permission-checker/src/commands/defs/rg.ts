import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

const RG_VALUE = new Set([
  "-e",
  "-f",
  "-g",
  "--glob",
  "--iglob",
  "-m",
  "--max-count",
  "-A",
  "-B",
  "-C",
  "-t",
  "--type",
  "-T",
  "--type-not",
  "-M",
  "--max-columns",
  "-d",
  "--max-depth",
  "--color",
  "--colors",
  "--sort",
  "--sortr",
  "-r",
  "--replace",
  "-j",
  "--threads",
  "-E",
  "--encoding",
  "--context-separator",
  "--pre",
  "--ignore-file",
  "--type-add",
  "--type-clear",
]);

// ripgrep recurses the cwd by default. `-f`/`--file`/`--ignore-file` read files;
// `--pre CMD` runs a preprocessor command per file.
export default defineCommand(["rg"], (argv) => {
  const args = argv.slice(1);
  const usedPatternFlag = args.some((a) => /^(-e|--regexp|-f|--file)/.test(a));
  const filesOnly = args.some((a) => a === "--files");
  const acc: PathAccess[] = [];
  const nested: { argv: string[] }[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (
      (a === "-f" || a === "--file" || a === "--ignore-file") &&
      i + 1 < args.length
    ) {
      acc.push({ kind: "read", path: args[i + 1] });
    } else if (a === "--pre" && i + 1 < args.length) {
      nested.push({ argv: [args[i + 1]] });
    }
  }
  const { operands } = splitArgs(args, RG_VALUE);
  let files = operands;
  if (!filesOnly && !usedPatternFlag && files.length > 0)
    files = files.slice(1); // drop pattern
  for (const f of files) if (f !== "-") acc.push({ kind: "read", path: f });
  if (files.length === 0) acc.push({ kind: "read", path: "." });
  return { pathAccesses: acc, nested, search: { recursive: true } };
});
