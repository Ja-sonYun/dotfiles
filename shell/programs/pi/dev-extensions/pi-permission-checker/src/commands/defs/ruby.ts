import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["ruby"],
  interpreterCmd({
    inlineFlags: ["-e"],
    valueFlags: ["-r", "-I", "-C", "-F", "-K"],
  }),
);
