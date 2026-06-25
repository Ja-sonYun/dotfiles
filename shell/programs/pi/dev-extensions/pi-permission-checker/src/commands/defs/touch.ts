import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["touch"],
  writeCmd(["-d", "--date", "-r", "--reference", "-t"]),
);
