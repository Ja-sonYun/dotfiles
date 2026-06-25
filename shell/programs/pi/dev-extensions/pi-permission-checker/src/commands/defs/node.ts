import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["node", "nodejs"],
  interpreterCmd({
    inlineFlags: ["-e", "--eval", "-p", "--print"],
    valueFlags: ["-r", "--require", "--max-old-space-size"],
  }),
);
