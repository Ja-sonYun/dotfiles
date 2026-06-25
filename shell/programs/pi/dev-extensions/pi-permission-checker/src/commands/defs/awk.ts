import { defineCommand, programFirstCmd } from "../helpers.ts";

// `awk 'program' file...` — the program is the first operand (not a path) unless `-f progfile`
// is used (which reads the program file). Remaining operands are read files.
export default defineCommand(
  ["awk", "gawk", "mawk", "nawk"],
  programFirstCmd({
    fromFileFlags: ["-f", "--file"],
    valueFlags: ["-F", "--field-separator", "-v", "--assign"],
  }),
);
