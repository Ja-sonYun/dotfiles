import { defineCommand, opaqueAsk, skipLeadingOptions } from "../helpers.ts";

// doas [-Lns] [-a style] [-C config] [-u user] command — skip options, then run the rest.
// `doas -s` opens a shell we can't analyze → always ask.
export default defineCommand(["doas"], (argv) => {
  const args = argv.slice(1);
  const i = skipLeadingOptions(args, new Set(["-a", "-C", "-u"]));
  const rest = args.slice(i);
  if (rest.length === 0) {
    return args.some((a) => a === "-s")
      ? opaqueAsk()
      : { pathAccesses: [], nested: [] };
  }
  return { pathAccesses: [], nested: [{ argv: rest }] };
});
