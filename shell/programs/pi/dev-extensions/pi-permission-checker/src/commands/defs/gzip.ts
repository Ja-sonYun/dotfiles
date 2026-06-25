import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(
  ["gzip", "bzip2", "xz", "zstd", "compress", "lz4"],
  writeCmd(["-S", "--suffix", "-T", "--threads"]),
);
