import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["stat"],
  readCmd(["-f", "-c", "--format", "--printf"]),
);
