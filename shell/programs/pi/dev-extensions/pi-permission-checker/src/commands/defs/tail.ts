import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["tail"],
  readCmd(["-n", "-c", "--lines", "--bytes"]),
);
