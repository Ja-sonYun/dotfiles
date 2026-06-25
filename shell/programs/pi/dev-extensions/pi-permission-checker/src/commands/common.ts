// Shared helpers for command analyzers.

/** Strip any directory prefix from a command name (e.g. /usr/bin/sed -> sed). */
export function basename(cmd: string): string {
  const i = cmd.lastIndexOf("/");
  return i >= 0 ? cmd.slice(i + 1) : cmd;
}

export interface SplitResult {
  operands: string[];
  /** Flags and their consumed values, in order. */
  flags: string[];
}

/**
 * Split argument tokens (argv without argv[0]) into flags and operands.
 * Honors `--` (end of options) and consumes the next token for value-taking flags.
 * Long flags written as `--flag=value` are self-contained.
 */
export function splitArgs(
  args: string[],
  valueFlags: Set<string>,
): SplitResult {
  const operands: string[] = [];
  const flags: string[] = [];
  let endOpts = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!endOpts && a === "--") {
      endOpts = true;
      continue;
    }
    if (!endOpts && a.startsWith("-") && a !== "-") {
      flags.push(a);
      const takesValue = a.startsWith("--")
        ? !a.includes("=") && valueFlags.has(a)
        : valueFlags.has(a);
      if (takesValue && i + 1 < args.length) {
        i++;
        flags.push(args[i]);
      }
      continue;
    }
    operands.push(a);
  }
  return { operands, flags };
}

/**
 * Skip a leading run of option tokens (and values of known value-flags), returning
 * the index of the first non-option token. Used by command wrappers (sudo/env/...).
 */
export function skipLeadingOptions(
  args: string[],
  valueFlags: Set<string>,
): number {
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === "--") return i + 1;
    if (!a.startsWith("-") || a === "-") return i;
    if (valueFlags.has(a)) i += 2;
    else i += 1;
  }
  return i;
}
