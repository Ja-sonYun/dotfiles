import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["gunzip", "bunzip2", "unxz", "unzstd", "unlz4"],
  writeCmd(["-S", "--suffix"]),
);
