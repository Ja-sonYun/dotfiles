import { defineCommand, skipLeadingOptions } from "../helpers.ts";

// env [OPTION]... [NAME=VALUE]... [COMMAND]... — skip options, then assignments, then run the rest.
// `-S/--split-string STR` carries the command line to run, so re-parse it as a nested script.
export default defineCommand(["env"], (argv) => {
  const args = argv.slice(1);
  for (let k = 0; k < args.length; k++) {
    const a = args[k];
    if ((a === "-S" || a === "--split-string") && k + 1 < args.length) {
      return { pathAccesses: [], nested: [{ script: args[k + 1] }] };
    }
    if (a.startsWith("-S"))
      return { pathAccesses: [], nested: [{ script: a.slice(2) }] };
    if (a.startsWith("--split-string="))
      return {
        pathAccesses: [],
        nested: [{ script: a.slice("--split-string=".length) }],
      };
  }
  let i = skipLeadingOptions(args, new Set(["-u", "--unset", "-C", "--chdir"]));
  while (i < args.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(args[i])) i++;
  const rest = args.slice(i);
  return { pathAccesses: [], nested: rest.length ? [{ argv: rest }] : [] };
});
