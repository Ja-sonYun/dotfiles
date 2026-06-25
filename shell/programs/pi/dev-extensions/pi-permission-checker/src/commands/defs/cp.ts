import { defineCommand, srcDestCmd } from "../helpers.ts";

export default defineCommand(
  ["cp"],
  srcDestCmd(["-t", "--target-directory", "-S", "--suffix"], {
    targetDir: true,
  }),
);
