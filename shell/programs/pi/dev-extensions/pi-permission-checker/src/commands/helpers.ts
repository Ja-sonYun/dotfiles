// Builders for per-command definitions. Each command file uses these to declare
// its path handling and any nested-command handling in one place. Idiosyncratic
// commands (sed, find, tar, ...) supply a bespoke analyze function instead.

import type { PathAccess } from "../types.ts";
import { basename, skipLeadingOptions, splitArgs } from "./common.ts";
import type { AnalyzeResult, CommandAnalyzer, Nested } from "./types.ts";

export { basename, skipLeadingOptions, splitArgs };

export type AnalyzeFn = (argv: string[], cwd: string) => AnalyzeResult;

/** Define a command analyzer for one or more (alias) command names. */
export function defineCommand(
  names: string[],
  analyze: AnalyzeFn,
): CommandAnalyzer {
  return { names, analyze };
}

function operandsOf(argv: string[], valueFlags: string[]): string[] {
  return splitArgs(argv.slice(1), new Set(valueFlags)).operands.filter(
    (o) => o !== "-",
  );
}

/** Extract a `-t`/`--target-directory` value (a write destination) if present. */
export function targetDirectory(args: string[]): string | undefined {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === "-t" || a === "--target-directory") && i + 1 < args.length)
      return args[i + 1];
    if (a.startsWith("--target-directory="))
      return a.slice("--target-directory=".length);
    if (a.startsWith("-t") && a.length > 2) return a.slice(2);
  }
  return undefined;
}

/** All operands are read paths. */
export function readCmd(valueFlags: string[] = []): AnalyzeFn {
  return (argv) => ({
    pathAccesses: operandsOf(argv, valueFlags).map((p) => ({
      kind: "read",
      path: p,
    })),
    nested: [],
  });
}

/** All operands are write paths (create/modify/delete). */
export function writeCmd(valueFlags: string[] = []): AnalyzeFn {
  return (argv) => ({
    pathAccesses: operandsOf(argv, valueFlags).map((p) => ({
      kind: "write",
      path: p,
    })),
    nested: [],
  });
}

/** cp/mv style: leading operands read, last operand write; `-t DEST` makes all operands reads. */
export function srcDestCmd(
  valueFlags: string[] = [],
  opts: { targetDir?: boolean } = {},
): AnalyzeFn {
  return (argv) => {
    const args = argv.slice(1);
    const operands = operandsOf(argv, valueFlags);
    const acc: PathAccess[] = [];
    if (opts.targetDir) {
      const dest = targetDirectory(args);
      if (dest !== undefined) {
        for (const o of operands) acc.push({ kind: "read", path: o });
        acc.push({ kind: "write", path: dest });
        return { pathAccesses: acc, nested: [] };
      }
    }
    if (operands.length >= 2) {
      for (const s of operands.slice(0, -1))
        acc.push({ kind: "read", path: s });
      acc.push({ kind: "write", path: operands[operands.length - 1] });
    } else {
      for (const o of operands) acc.push({ kind: "write", path: o });
    }
    return { pathAccesses: acc, nested: [] };
  };
}

/**
 * chmod/chown/chgrp style: the first operand is a mode/owner spec (not a path) and the rest
 * are writes. With a `--reference FILE` flag there is no spec operand and the file is a read.
 */
export function specThenWriteCmd(
  valueFlags: string[] = [],
  referenceFlags: string[] = ["--reference"],
): AnalyzeFn {
  const refs = referenceFlags;
  return (argv) => {
    const args = argv.slice(1);
    const acc: PathAccess[] = [];
    let usedRef = false;
    for (const a of args) {
      for (const rf of refs) {
        if (a.startsWith(rf + "=")) {
          usedRef = true;
          acc.push({ kind: "read", path: a.slice(rf.length + 1) });
        }
      }
    }
    // refs consume a value via splitArgs; also detect the separate-token form for the read.
    for (let i = 0; i < args.length; i++) {
      if (refs.includes(args[i]) && i + 1 < args.length) {
        usedRef = true;
        acc.push({ kind: "read", path: args[i + 1] });
      }
    }
    let operands = splitArgs(
      args,
      new Set([...valueFlags, ...refs]),
    ).operands.filter((o) => o !== "-");
    if (!usedRef && operands.length > 0) operands = operands.slice(1); // drop the mode/owner spec
    for (const o of operands) acc.push({ kind: "write", path: o });
    return { pathAccesses: acc, nested: [] };
  };
}

/** Command runner that wraps another command (sudo/env/timeout/...): skip own options, run the rest. */
export function wrapperCmd(valueFlags: string[] = []): AnalyzeFn {
  return (argv) => {
    const args = argv.slice(1);
    const i = skipLeadingOptions(args, new Set(valueFlags));
    const rest = args.slice(i);
    return { pathAccesses: [], nested: rest.length ? [{ argv: rest }] : [] };
  };
}

/** Shell exec: `-c <script>` (incl. combined clusters like -lc) -> nested script; else first operand is a script file read. */
export function shellExecCmd(): AnalyzeFn {
  return (argv) => {
    const args = argv.slice(1);
    const ci = args.findIndex((a) => /^-[A-Za-z]*c$/.test(a));
    if (ci >= 0 && ci + 1 < args.length) {
      return { pathAccesses: [], nested: [{ script: args[ci + 1] }] };
    }
    const { operands } = splitArgs(
      args,
      new Set(["-o", "--rcfile", "--init-file"]),
    );
    // No `-c` and no script file: an interactive / stdin-fed shell (e.g. `curl x | bash`)
    // executes code we can't see, so force an ask just like other opaque commands.
    if (operands.length === 0) return opaqueAsk();
    return { pathAccesses: [{ kind: "read", path: operands[0] }], nested: [] };
  };
}

/** Always-ask signal for commands that run code we can't statically analyze. */
export function opaqueAsk(extra: Partial<AnalyzeResult> = {}): AnalyzeResult {
  return { pathAccesses: [], nested: [], opaque: true, ...extra };
}

/**
 * Program-first tools (awk, jq): the first operand is the program (not a path).
 * `fromFileFlags` supply the program from a FILE (read) and suppress the inline program.
 * `valueFlags` consume their next token (not a path). `twoArgFileFlags` consume two tokens
 * where the second is a file read (e.g. jq --slurpfile NAME FILE).
 */
export function programFirstCmd(opts: {
  fromFileFlags?: string[];
  valueFlags?: string[];
  twoArgFileFlags?: string[];
  twoArgFlags?: string[];
  search?: { recursive: boolean };
}): AnalyzeFn {
  const fromFile = new Set(opts.fromFileFlags ?? []);
  const value = new Set(opts.valueFlags ?? []);
  const twoArgFile = new Set(opts.twoArgFileFlags ?? []);
  const twoArg = new Set(opts.twoArgFlags ?? []);
  return (argv) => {
    const args = argv.slice(1);
    const acc: PathAccess[] = [];
    const operands: string[] = [];
    let usedFromFile = false;
    let endOpts = false;
    for (let i = 0; i < args.length; i++) {
      const a = args[i];
      if (!endOpts && a === "--") {
        endOpts = true;
        continue;
      }
      if (!endOpts && a.startsWith("-") && a !== "-") {
        const eq = a.indexOf("=");
        const shortAttached =
          !a.startsWith("--") && a.length > 2 ? a.slice(0, 2) : undefined;
        if (fromFile.has(a)) {
          usedFromFile = true;
          if (i + 1 < args.length) acc.push({ kind: "read", path: args[++i] });
        } else if (eq > 0 && fromFile.has(a.slice(0, eq))) {
          usedFromFile = true;
          acc.push({ kind: "read", path: a.slice(eq + 1) });
        } else if (shortAttached && fromFile.has(shortAttached)) {
          // joined short form, e.g. `awk -fprog.awk`
          usedFromFile = true;
          acc.push({ kind: "read", path: a.slice(2) });
        } else if (twoArgFile.has(a)) {
          if (i + 1 < args.length) i++; // skip the name
          if (i + 1 < args.length) acc.push({ kind: "read", path: args[++i] });
        } else if (twoArg.has(a)) {
          if (i + 2 < args.length) i += 2;
          else i = args.length;
        } else if (value.has(a)) {
          if (i + 1 < args.length) i++;
        }
        continue;
      }
      operands.push(a);
    }
    let files = operands;
    if (!usedFromFile && files.length > 0) files = files.slice(1); // drop the inline program
    for (const f of files) if (f !== "-") acc.push({ kind: "read", path: f });
    return {
      pathAccesses: acc,
      nested: [],
      ...(opts.search ? { search: opts.search } : {}),
    };
  };
}

/**
 * Language interpreters: a script-file operand is a read; inline code (`-c`/`-e`/...) or a
 * REPL/stdin invocation can't be analyzed and forces an ask.
 */
export function interpreterCmd(opts: {
  inlineFlags: string[];
  valueFlags?: string[];
}): AnalyzeFn {
  const inline = new Set(opts.inlineFlags);
  const value = new Set(opts.valueFlags ?? []);
  // Inline code may be attached to the flag (`perl -e'code'`) or clustered (`python -ic`),
  // so match by the leading short-option too, not just the exact token.
  const isInline = (a: string): boolean =>
    inline.has(a) ||
    (!a.startsWith("--") && a.length > 2 && inline.has(a.slice(0, 2)));
  return (argv) => {
    const args = argv.slice(1);
    if (args.some(isInline)) return opaqueAsk();
    const operands = splitArgs(args, value).operands.filter((o) => o !== "-");
    if (operands.length === 0) return opaqueAsk(); // REPL / stdin program
    return { pathAccesses: [{ kind: "read", path: operands[0] }], nested: [] };
  };
}
