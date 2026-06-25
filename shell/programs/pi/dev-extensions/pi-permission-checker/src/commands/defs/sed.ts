import type { PathAccess } from "../../types.ts";
import { defineCommand, splitArgs } from "../helpers.ts";

// In-place (-i / --in-place) targets are edits; otherwise file operands are reads.
// The sed program (first operand unless given via -e/-f) is not a path. BSD `sed -i ''`
// passes the backup suffix as a separate empty operand.
export default defineCommand(["sed", "gsed"], (argv) => {
  const args = argv.slice(1);
  let inPlace = false;
  for (const a of args) {
    if (a === "--") break;
    if (/^--in-place/.test(a)) inPlace = true;
    else if (/^-[A-Za-z]*i/.test(a)) inPlace = true;
  }
  const valueFlags = new Set([
    "-e",
    "-f",
    "--expression",
    "--file",
    "-l",
    "--line-length",
  ]);
  const usedScriptFlag = args.some((a) =>
    /^(-e|--expression|-f|--file)/.test(a),
  );
  const { operands, flags } = splitArgs(args, valueFlags);
  const acc: PathAccess[] = [];
  for (let i = 0; i < flags.length; i++) {
    if ((flags[i] === "-f" || flags[i] === "--file") && i + 1 < flags.length)
      acc.push({ kind: "read", path: flags[i + 1] });
    else if (flags[i].startsWith("--file="))
      acc.push({ kind: "read", path: flags[i].slice("--file=".length) });
    else if (
      flags[i].startsWith("-f") &&
      flags[i].length > 2 &&
      !flags[i].startsWith("--")
    )
      acc.push({ kind: "read", path: flags[i].slice(2) }); // -fscript.sed
  }
  let files = operands.filter((o) => o !== "");
  if (!usedScriptFlag && files.length > 0) files = files.slice(1);
  for (const f of files)
    if (f !== "-") acc.push({ kind: inPlace ? "edit" : "read", path: f });
  return { pathAccesses: acc, nested: [] };
});
