import type { PathAccess } from "../../types.ts";
import { defineCommand } from "../helpers.ts";

// Supports GNU (`-xzf`), long (`--extract --file=`), and traditional bundled (`xzf`) forms.
// create (c): operand files read, archive write. extract/append (x/r/u): archive read,
// extraction writes to -C dir (or cwd). list (t): archive read.
export default defineCommand(["tar", "gtar", "bsdtar"], (argv) => {
  const args = argv.slice(1);
  const acc: PathAccess[] = [];
  let mode = "";
  let archive: string | undefined;
  let chdir: string | undefined;
  let wantsArchiveOperand = false;
  const operands: string[] = [];
  let endOpts = false;

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!endOpts && a === "--") {
      endOpts = true;
      continue;
    }
    if (!endOpts && a.startsWith("--")) {
      const eq = a.indexOf("=");
      const key = eq > 0 ? a.slice(0, eq) : a;
      const val = eq > 0 ? a.slice(eq + 1) : undefined;
      const take = () =>
        val !== undefined ? val : i + 1 < args.length ? args[++i] : undefined;
      if (key === "--create") mode ||= "c";
      else if (key === "--extract" || key === "--get") mode ||= "x";
      else if (key === "--list") mode ||= "t";
      else if (key === "--append" || key === "--update") mode ||= "r";
      else if (key === "--file") archive = take();
      else if (key === "--directory") chdir = take();
      else if (key === "--files-from" || key === "--exclude-from") {
        const f = take();
        if (f) acc.push({ kind: "read", path: f });
      }
      continue;
    }
    if (!endOpts && a.startsWith("-")) {
      const letters = a.slice(1);
      for (const ch of letters) if ("cxtru".includes(ch)) mode ||= ch;
      if (letters.includes("f") && i + 1 < args.length) archive = args[++i];
      if (letters.includes("C") && i + 1 < args.length) chdir = args[++i];
      continue;
    }
    // Traditional bundled options as the first bare token, e.g. `tar xzf a.tgz`.
    if (operands.length === 0 && !mode && /^[A-Za-z]+$/.test(a)) {
      for (const ch of a) if ("cxtru".includes(ch)) mode ||= ch;
      if (a.includes("f")) wantsArchiveOperand = true;
      continue;
    }
    operands.push(a);
  }

  let opnds = operands;
  if (wantsArchiveOperand && archive === undefined && opnds.length > 0) {
    archive = opnds[0];
    opnds = opnds.slice(1);
  }
  if (archive && archive !== "-")
    acc.push({ kind: mode === "c" ? "write" : "read", path: archive });
  if (mode === "c") {
    for (const o of opnds) acc.push({ kind: "read", path: o });
  } else if (mode === "x" || mode === "r" || mode === "u") {
    acc.push({ kind: "write", path: chdir ?? "." });
  }
  return { pathAccesses: acc, nested: [] };
});
