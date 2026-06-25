import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["head"],
  readCmd(["-n", "-c", "--lines", "--bytes"]),
);
