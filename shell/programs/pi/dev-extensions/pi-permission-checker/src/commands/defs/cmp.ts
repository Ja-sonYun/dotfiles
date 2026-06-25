import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["cmp"],
  readCmd(["-i", "--ignore-initial", "-n"]),
);
