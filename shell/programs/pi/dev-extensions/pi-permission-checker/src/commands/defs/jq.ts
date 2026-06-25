import { defineCommand, programFirstCmd } from "../helpers.ts";

// `jq 'filter' file...` — the filter is the first operand unless `-f`/`--from-file` reads it.
// `--slurpfile`/`--rawfile NAME FILE` read a data file; `--arg`/`--argjson NAME VALUE` are not paths.
export default defineCommand(
  ["jq"],
  programFirstCmd({
    fromFileFlags: ["-f", "--from-file"],
    valueFlags: ["-L", "--indent"],
    twoArgFileFlags: ["--slurpfile", "--rawfile"],
    twoArgFlags: ["--arg", "--argjson"],
  }),
);
