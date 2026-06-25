import { defineCommand, skipLeadingOptions } from "../helpers.ts";

// timeout [OPTION] DURATION COMMAND [ARG]... — skip options and the duration, run the rest.
export default defineCommand(["timeout"], (argv) => {
  const args = argv.slice(1);
  let i = skipLeadingOptions(
    args,
    new Set(["-s", "--signal", "-k", "--kill-after"]),
  );
  if (i < args.length) i++; // the duration argument
  const rest = args.slice(i);
  return { pathAccesses: [], nested: rest.length ? [{ argv: rest }] : [] };
});
