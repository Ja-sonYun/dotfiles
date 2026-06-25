import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["php"],
  interpreterCmd({ inlineFlags: ["-r"], valueFlags: ["-d", "-c"] }),
);
