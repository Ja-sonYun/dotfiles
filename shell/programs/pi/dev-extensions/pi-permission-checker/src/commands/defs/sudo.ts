import { defineCommand, opaqueAsk, skipLeadingOptions } from "../helpers.ts";

const SUDO_VALUE = new Set([
  "-u",
  "--user",
  "-g",
  "--group",
  "-p",
  "--prompt",
  "-C",
  "--close-from",
  "-r",
  "--role",
  "-t",
  "--type",
  "-U",
  "--other-user",
  "-D",
  "--chdir",
  "-h",
  "--host",
  "-R",
  "--chroot",
  "-T",
  "--command-timeout",
]);

// sudo [opts] [VAR=value]... command — skip options and env assignments, then run the rest.
// `sudo -s`/`-i` with no command opens an (interactive) shell we can't analyze → always ask.
export default defineCommand(["sudo"], (argv) => {
  const args = argv.slice(1);
  let i = skipLeadingOptions(args, SUDO_VALUE);
  while (i < args.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(args[i])) i++;
  const rest = args.slice(i);
  if (rest.length === 0) {
    const shell = args.some(
      (a) => a === "-s" || a === "--shell" || a === "-i" || a === "--login",
    );
    return shell ? opaqueAsk() : { pathAccesses: [], nested: [] };
  }
  return { pathAccesses: [], nested: [{ argv: rest }] };
});
