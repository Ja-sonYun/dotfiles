import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["Rscript"],
  interpreterCmd({ inlineFlags: ["-e"], valueFlags: [] }),
);
