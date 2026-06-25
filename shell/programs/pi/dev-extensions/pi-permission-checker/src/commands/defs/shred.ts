import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["shred"],
  writeCmd(["-n", "--iterations", "-s", "--size"]),
);
