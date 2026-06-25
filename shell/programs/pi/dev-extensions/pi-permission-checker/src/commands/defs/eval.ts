import { defineCommand, opaqueAsk } from "../helpers.ts";

// eval re-parses its arguments as shell code. Surface the joined string as a nested script so
// deny/path rules still apply to what it would run, and keep it opaque (always ask) because the
// reconstructed text only approximates the original quoting.
export default defineCommand(["eval"], (argv) => {
  const script = argv.slice(1).join(" ");
  return { ...opaqueAsk(), nested: script.trim() ? [{ script }] : [] };
});
