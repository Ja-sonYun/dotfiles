import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["truncate"],
  writeCmd(["-s", "--size", "-r", "--reference"]),
);
