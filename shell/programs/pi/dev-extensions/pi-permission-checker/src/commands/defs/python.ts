import { defineCommand, interpreterCmd } from "../helpers.ts";

export default defineCommand(
  ["python", "python3", "python2"],
  interpreterCmd({
    inlineFlags: ["-c", "-m"],
    valueFlags: ["-W", "-X", "--check-hash-based-pycs"],
  }),
);
