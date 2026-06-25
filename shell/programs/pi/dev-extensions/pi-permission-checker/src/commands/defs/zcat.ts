import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["zcat", "bzcat", "xzcat", "zstdcat", "lz4cat"],
  readCmd(),
);
