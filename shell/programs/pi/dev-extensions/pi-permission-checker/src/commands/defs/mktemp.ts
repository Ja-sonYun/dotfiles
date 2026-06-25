import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["mktemp"],
  writeCmd(["--suffix", "-p", "--tmpdir"]),
);
