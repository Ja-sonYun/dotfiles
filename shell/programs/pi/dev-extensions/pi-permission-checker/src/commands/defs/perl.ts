import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["perl"],
  interpreterCmd({
    inlineFlags: ["-e", "-E"],
    valueFlags: ["-I", "-m", "-M", "-F"],
  }),
);
